# TCAC 2.0 — TEI / SPECTER2 lifecycle scripts

This folder contains the operational scripts for the SPECTER2 embedding pipeline.

## One-time setup (per machine)

```bash
# 1. Install TEI (Metal-enabled on macOS via Homebrew)
brew install text-embeddings-inference

# 2. Install Python deps for the SPECTER2 model merger
pip install transformers adapters torch

# 3. Build both merged model directories (proximity + adhoc_query adapters)
./scripts/prepare_specter2.sh
#   -> .../specter2_proximity_merged/
#   -> .../specter2_adhoc_merged/

# 4. Install BERTopic + parquet deps into the project venv
#    (needed by scripts/run_bertopic.py, called from the topics_tcac20 target)
./.venv/bin/pip install bertopic pyarrow pyyaml
```

To build only one adapter:

```bash
./scripts/prepare_specter2.sh proximity
./scripts/prepare_specter2.sh adhoc_query
```

## Per-session — start the TEI server

The corpus embedding pipeline uses the **proximity** adapter (document-to-document similarity).

```bash
./scripts/start_tei_specter2.sh                # proximity (default), port 8080
./scripts/start_tei_specter2.sh adhoc_query    # query-time adapter
```

Tune via environment variables:

| Variable | Default | Effect |
|---|---|---|
| `OVC_TEI_PORT` | `8080` | TEI listen port — must match `port` in `config.yaml` |
| `OVC_TEI_MAX_BATCH_TOKENS` | `32768` | Server-side token budget per batch |
| `OVC_TEI_MAX_CONCURRENT` | `512` | Max concurrent HTTP requests |
| `OVC_SPECTER2_PATH` | per-user cache | Override merged model directory |

`--auto-truncate` is always on, so inputs over 512 tokens are right-truncated server-side.

## Verify the server

```bash
curl -s http://localhost:8080/health && echo
curl -s http://localhost:8080/embed \
  -H 'Content-Type: application/json' \
  -d '{"inputs":"Hello world"}' | jq 'length'
# expect: 768
```

## Then run the pipeline

```r
targets::tar_make()
```

## Switching between pilot and full corpus

`config.yaml` → `embedding.pilot_n: 1000` runs against the first 1000 corpus rows.
Set `pilot_n: null` to run against the full extract — the `pilot_corpus_tcac20`
target then short-circuits and the embed targets read directly from
`corpus_tcac20_db`.

## Running TEI on RunPod (remote GPU)

When the local Metal GPU is too slow, host TEI on a rented RunPod A100/H100.

1. **Build a pod image** with the merged SPECTER2 model baked in — or attach a
   persistent volume that already contains it at
   `/runpod-volume/specter2_proximity_merged/`.
2. **Pod entrypoint**: run `./scripts/start_tei_runpod.sh` on the pod. It
   defaults to A100/H100-scale tuning (`max-batch-tokens 131072`,
   `max-concurrent 2048`, `max-client-batch-size 512`). Expose port 8080 via
   RunPod's HTTP proxy.
3. **Save your auth token** (if you front TEI with an auth proxy) into the
   local keyring:
   ```r
   keyring::key_set("API_TEI")   # paste token at prompt
   ```
4. **Flip `config.yaml`**: copy the commented `SPECTER2_runpod:` template into
   the `embeddings:` block, fill in `host` (e.g.
   `<pod-id>-8080.proxy.runpod.net`), and set
   `embeddings.active: SPECTER2_runpod`. The new keys are `scheme: https` and
   `auth_token_keyring: API_TEI`; `build_tei_backend()` in `R/embed_works.R`
   picks them up.
5. **Verify**:
   ```bash
   curl -s -k -H "Authorization: Bearer $TOKEN" \
     https://<pod-id>-8080.proxy.runpod.net/health
   ```
   Then run a 1000-row pilot (`pilot_n: 1000`) and compare rows/s to the local
   baseline. Expect 3–10× speed-up — network RTT (~30 ms) eats into the raw
   GPU ratio, which is why `max_batch_size` is bumped from 64 to 256 in the
   template.
