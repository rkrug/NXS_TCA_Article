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
