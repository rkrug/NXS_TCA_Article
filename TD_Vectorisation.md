# openalexVectorComp — Session Summary
*Prepared for handoff to Claude Code*

---

## Context

Working on **TCAC 2.0**, a corpus of ~6M scientific works stored as Arrow/Parquet files. Goal is to generate embeddings for semantic search and bibliometric similarity analysis using **SPECTER2** served via **TEI (Text Embeddings Inference)**.

The embeddings are part of the R package **`openalexVectorComp`**, which manages model setup, TEI server lifecycle, and embedding generation.

---

## Embedding Model: SPECTER2

- **Model**: `allenai/specter2_base` + `proximity` adapter
- **Dimensions**: 768 (float16 recommended for storage)
- **Max tokens**: 512
- **Input format**: `title [SEP] abstract` (SPECTER2 tokenizer sep token)
- **Adapter choice**:
  - `proximity` — for batch embedding of corpus (document-to-document similarity)
  - `adhoc_query` — for embedding user queries at search time
- **Key property**: Citations used only during training, not at inference. At inference time, only title + abstract are needed.

### Why not GTE-Large (OpenAlex's model)?
- GTE-Large is what OpenAlex uses (via Databricks `databricks-gte-large-en`)
- 1024 dimensions, ~340M params — ~3× larger and slower than SPECTER2
- SPECTER2 is domain-appropriate (trained on scientific citation graph)
- SPECTER2 is already integrated into `openalexVectorComp`

---

## Corpus Statistics (TCAC 2.0)

- **Total records**: ~6M
- **No abstract** (NA or 0 tokens): ~20%
- **Abstract token distribution** (estimated at 4.5 chars/token):
  - 80th percentile: ~515 tokens
  - 90th percentile: ~724 tokens
  - 95th percentile: ~975 tokens
  - 99th percentile: ~2,222 tokens
- **Truncation impact**: ~20% of abstracts exceed 512 tokens — TEI handles truncation automatically, cutting from the end of the abstract (ideal, since key content is front-loaded)
- **Title length**: peaks at 80–100 chars, essentially all under 200 chars — no truncation concern

---

## Embedding Sets — Three Planned

| Set | Input | Coverage | Notes |
|---|---|---|---|
| `emb_title` | `title` (cap ~500 chars) | 100% | Fallback for all records |
| `emb_title_abstract` | `title [SEP] abstract` (cap ~2300 chars) | ~80% | Primary semantic embedding |
| `emb_abstract` | `abstract` (cap ~2300 chars) | ~80% | Disentangles title vs abstract signal |

### Rationale for three sets
- `emb_title` covers records without abstracts and enables title-only similarity
- `emb_title_abstract` is the primary embedding, aligned with SPECTER2 training format
- `emb_abstract` enables analysis of how much titles reflect abstract content
- Derived metrics possible: `sim(emb_title, emb_abstract)` as title informativeness proxy

### Storage estimate (float16)
- 5M × 768 × 2 bytes ≈ **7.5 GB per set** → **~22.5 GB total**

---

## Input Preparation (R)

TEI handles truncation automatically — no preprocessing needed beyond:

```r
# title+abstract input
paste(title, abstract, sep = tokenizer_sep_token)  # "[SEP]" for SPECTER2

# title only
title  # raw, TEI truncates at 512 tokens

# abstract only  
abstract  # raw, TEI truncates at 512 tokens
```

Character caps before sending (defensive, avoids sending huge payloads):
- Title: 500 chars
- Abstract: 2300 chars (~512 tokens × 4.5 chars/token)

---

## TEI Server Setup

### Scripts in `inst/scripts/`

**`prepare_specter2_merged.py`** — one-time setup per machine:
- Loads `allenai/specter2_base` + `allenai/specter2` proximity adapter
- Merges adapter weights into base model (makes it TEI-compatible)
- Saves merged model to per-user cache:
  - macOS: `~/Library/Caches/org.R-project.R/R/openalexVectorComp/specter2_proximity_merged`
  - Linux: `~/.cache/R/openalexVectorComp/specter2_proximity_merged`
- Override with `OVC_SPECTER2_PATH` env var

```bash
pip install transformers adapters torch
python prepare_specter2_merged.py
```

**`start_tei_specter2.sh`** — starts TEI server:

```bash
#!/usr/bin/env bash
# Environment overrides:
#   OVC_SPECTER2_PATH          Path to merged model dir
#   OVC_TEI_PORT               Port (default: 8080)
#   OVC_TEI_MAX_BATCH_TOKENS   Max tokens per batch (default: 32768)
#   OVC_TEI_MAX_CONCURRENT     Max concurrent requests (default: 512)

exec text-embeddings-router \
  --model-id "${MODEL_PATH}" \
  --port "${PORT}" \
  --max-batch-tokens "${MAX_BATCH_TOKENS}" \
  --max-concurrent-requests "${MAX_CONCURRENT}"
```

### TEI installation (macOS Apple Silicon)

Use Homebrew — it builds with Metal support (`-F metal`) automatically:

```bash
brew install text-embeddings-inference
```

Do **not** use `cargo install` — the crates.io version lacks Metal support.

After installing via Homebrew:
```bash
cargo uninstall text-embeddings-router  # remove old cargo version
which text-embeddings-router            # verify: /opt/homebrew/bin/...
```

### Verify server

```bash
curl http://localhost:8080/health

curl http://localhost:8080/embed \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"inputs": "Test title [SEP] Test abstract"}'
# Returns 768-dimensional JSON array
```

---

## Hardware

| Machine | Backend | Est. throughput | Est. time for 15M embeddings |
|---|---|---|---|
| MacBook Pro M4 Max 36GB | Metal (MPS) via TEI | ~1,500–2,000 docs/sec | ~2–3 hrs |
| GPU compute instance (CUDA) | CUDA via TEI | ~5,000–8,000 docs/sec | ~30–45 min |

- MacBook suitable for development and small-batch testing
- GPU compute instance for full production run
- TEI serves identically on both — same API, same client code

---

## Next Steps for Claude Code

1. **R client for TEI** — implement `httr2`-based function in `openalexVectorComp` to:
   - Accept a character vector of texts
   - POST to `http://localhost:{OVC_TEI_PORT}/embed`
   - Return a numeric matrix (n × 768)

2. **Batch embedding pipeline** — function to:
   - Read from Arrow/Parquet corpus
   - Prepare the three input text variants
   - Send in batches to TEI
   - Write embeddings + OpenAlex ID back to Parquet
   - Checkpoint every N records

3. **`adhoc_query` adapter** — a second merged model for query-time embedding:
   - Run `prepare_specter2_merged.py` with adapter `adhoc_query`
   - Separate server or switchable model path

4. **Similarity metrics** — once all three embedding sets exist:
   - `sim(emb_title, emb_abstract)` — title informativeness
   - `sim(emb_title, emb_title_abstract)` — abstract contribution
   - `sim(emb_title_abstract, emb_abstract)` — title shift
