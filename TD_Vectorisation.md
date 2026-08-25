---
title: "TD — Vectorisation (TEI embeddings)"
format:
  html:
    toc: true
    embed-resources: true
---

Companion to [TD_RunPodSetup.md](TD_RunPodSetup.md), which covers running the
TEI server itself. This file covers the embedding model and text handling.

> **Scope note.** This began as a handoff summary for **TCAC 2.0**, a ~6M-work
> OpenAlex corpus embedded end-to-end with SPECTER2. That is no longer what
> this pipeline does. After the prune, the only embedding target left is
> `emb_keypapers_title_abstract` — the ~28 TCA/Nexus concept **definitions**
> in `input/TCA and Nexus Definitions-1.xlsx`. The full-corpus embedding and
> scoring layers were removed. The corpus statistics that used to sit here
> described that 6M-work corpus and no longer apply; see git history for them.

## Context

Embeddings are produced by `R/embed_works.R`, which POSTs text to a
[TEI](https://github.com/huggingface/text-embeddings-inference) server and
writes float parquet under
`output/NXS_TCA_corpus/embeddings/config=<name>/source=keypaper/variant=<v>/`.
The model-side helpers live in the R package **`openalexVectorComp`**.

The active model name is also the `config=` hive-partition value, so several
models coexist on disk instead of overwriting one another.

## Embedding model

Configured under `embeddings.configs.<name>` in `input/config.yaml`; the
active one is `embeddings.active`.

| | **`bge_large_runpod`** (active) | `SPECTER2_runpod` |
|---|---|---|
| Model | `BAAI/bge-large-en-v1.5` | `allenai/specter2_base` + `proximity` adapter |
| Dimensions | 1024 | 768 |
| Max tokens | 512 | 512 |
| Title/abstract join | raw concat, `sep_token: ""` | `title [SEP] abstract` |
| Pooling | cls | cls |

The separator matters: SPECTER2 was trained with an explicit `[SEP]` between
title and abstract, whereas BGE is a single-text model with no such
convention, so its `sep_token` is empty and the two fields are concatenated
directly. `title_cap_combined: 200` caps the title in the combined variant for
both.

SPECTER2 remains domain-appropriate (trained on the scientific citation
graph); BGE is the current default. Switching is a one-line `active:` change
plus a host — outputs land in separate `config=` partitions.

---

## Embedding Sets — Three Planned — Three Planned

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
