# `docker/tei-runpod/` — TEI image with merged SPECTER2

A self-contained Docker image that runs TEI against a SPECTER2 adapter merged
into the image at build time. Drop into a RunPod pod template; no volume
mount, no first-boot download.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Multi-stage: stage 1 merges the SPECTER2 adapter; stage 2 is the TEI runtime with the merged model copied in. |
| `entrypoint.sh` | Pod-side launch command; reads env vars for tuning. |
| `.dockerignore` | Keeps the build context tiny (only the merge script + entrypoint). |

## Build (from repo root)

```bash
# Proximity adapter (corpus embedding side)
docker buildx build --platform linux/amd64 \
    -t ghcr.io/rkrug/tei-specter2:proximity \
    --build-arg ADAPTER=proximity \
    --build-arg TEI_TAG=89-1.5 \
    -f docker/tei-runpod/Dockerfile .

# Adhoc-query adapter (query-time)
docker buildx build --platform linux/amd64 \
    -t ghcr.io/rkrug/tei-specter2:adhoc_query \
    --build-arg ADAPTER=adhoc_query \
    --build-arg TEI_TAG=89-1.5 \
    -f docker/tei-runpod/Dockerfile .

docker push ghcr.io/rkrug/tei-specter2:proximity
docker push ghcr.io/rkrug/tei-specter2:adhoc_query
```

`--platform linux/amd64` matters on Apple Silicon — RunPod nodes are amd64.

### Picking `TEI_TAG`

Match TEI's CUDA build to the GPU family you'll rent:

| GPU | Suggested tag |
|---|---|
| A100, A6000, A40 (Ampere) | `86-1.5` |
| A100 (compute 8.0)         | `80-1.5` |
| RTX 4090, H100 (Hopper)    | `89-1.5` |

Wrong tag → the binary refuses to start on that GPU. List of tags:
[ghcr.io/huggingface/text-embeddings-inference](https://github.com/huggingface/text-embeddings-inference/pkgs/container/text-embeddings-inference).

## Use in RunPod

1. Push to a public-or-token-accessible registry (GHCR, Docker Hub).
2. RunPod → **GPU Pod** → "Edit Template".
   - Container Image: `ghcr.io/rkrug/tei-specter2:proximity`
   - Container Start Command: *(leave blank — entrypoint launches TEI)*
   - Expose HTTP port: `8080`
   - **Environment Variables** (for the idle-watchdog auto-stop):
     - `RUNPOD_API_KEY` = your RunPod API key (Settings → API Keys) — **required**
     - `IDLE_MIN` = `5` (optional override of the image default; see "Tuning" below)
     - `POLL_SEC` = `30` (optional override of the image default)
3. Launch pod. Health-check:
   ```bash
   HOST=<pod-id>-8080.proxy.runpod.net
   curl -s https://$HOST/health && echo
   curl -s https://$HOST/embed -H 'Content-Type: application/json' \
        -d '{"inputs":"hello"}' | jq 'length'   # → 768
   ```
4. Flip `config.yaml: active_embedding: SPECTER2_runpod`, set `host: $HOST`, run the pipeline (see [TD_RunPodSetup.md](../../TD_RunPodSetup.md)).

## Runtime tuning (without rebuilding)

Set in RunPod template **Environment Variables**:

| Var | Default | Notes |
|---|---|---|
| `TEI_PORT` | `8080` | Must match RunPod's exposed port. |
| `TEI_MAX_BATCH_TOKENS` | `131072` | Server token budget per batch. |
| `TEI_MAX_CONCURRENT` | `2048` | Concurrent in-flight requests. |
| `TEI_MAX_CLIENT_BATCH` | `512` | Per-HTTP-request texts; client batch size. |
| `TEI_SERVED_NAME` | `allenai/specter2_<adapter>_merged` | Surfaces in `/info`. |
| `IDLE_MIN` | `5` | Minutes of TEI inactivity before the idle watchdog stops the pod. **Tune to taste** — see below. |
| `POLL_SEC` | `30` | How often the watchdog samples TEI's request counter. Lower → faster shutdown after last request; higher → less log noise. |
| `RUNPOD_API_KEY` | *(unset)* | **Required** for the idle watchdog to be able to call `runpodctl stop pod`. Set in the pod template. |

## Idle auto-stop (pod-side watchdog)

`tei_idle_watchdog.sh` runs in the background alongside TEI on the pod. It
polls TEI's `/metrics` endpoint every `POLL_SEC` seconds and tracks the
cumulative request counter. After `IDLE_MIN` minutes with no new requests
it calls `runpodctl stop pod $RUNPOD_POD_ID` to pause billing. The volume
and image cache survive; restart from the RunPod UI when needed.

This protects against:
- Laptop crashes / sleeps mid-run leaving a pod running for hours.
- Forgetting to manually stop after a job finishes.
- Pipeline pauses overnight between targets.

### Tuning — both knobs are overridable per pod

The image default is `IDLE_MIN=5`, `POLL_SEC=30`. **Override either value
without rebuilding** by setting it in the pod template's Environment
Variables UI:

| Workflow | Suggested `IDLE_MIN` | Why |
|---|---|---|
| One big embed run, then days idle | `5` (default) | Stops fast after the run finishes; cold-restart cost is rare. |
| Iterating on prompts / scoring | `15`–`30` | Avoids restart latency between many small runs. |
| Live-demo / interactive use | `60` | Don't shut down while a user is mid-question. |

Set `IDLE_MIN=0` (or unset `RUNPOD_API_KEY`) to disable the watchdog
entirely.

## Why bake the model in (vs. mount a volume)

- Cold-start latency: image already has weights → TEI ready in seconds.
- Reproducibility: `docker pull <digest>` = exact model bytes; no drift.
- No `runpodctl send/receive` ceremony.

Trade-off: the image is ~500 MB heavier than the stock TEI image. Negligible
for repeated runs; rebuild only when you bump SPECTER2 or the base image.
