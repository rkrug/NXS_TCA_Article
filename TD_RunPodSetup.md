# TD: Setting up TEI on RunPod for SPECTER2 embeddings

Companion to [TD_Vectorisation.md](TD_Vectorisation.md). Use this when the
local Metal GPU is too slow and you want to host TEI on a rented RunPod GPU.

The R-side support is already in place:

- `R/embed_works.R::build_tei_backend()` reads `scheme` + `auth_token_keyring`
  from the active embedding config.
- `config.yaml` ships with a commented `SPECTER2_runpod:` template under
  `embeddings:`.
- `scripts/start_tei_runpod.sh` runs on the pod with A100/H100-scale defaults.

What's left is the pod-side setup. This doc is that checklist.

---

## 1. RunPod account + API key

- Sign up at [runpod.io](https://runpod.io), add credit.
- **Settings → API Keys** → create one. Save it in your local keyring if you
  plan to use `runpodctl`:

  ```r
  keyring::key_set("API_RUNPOD")
  ```

## 2. Pick the pod template

- Browse → **GPU Pod** (not Serverless — cold-start latency hurts embedding
  throughput).
- **GPU**: A100 80GB is the sweet spot (~$1.20/hr). H100 if you need it faster.
- **Template**: search "**Text Embeddings Inference**" — the official
  `ghcr.io/huggingface/text-embeddings-inference` template, CUDA variant.
  Pick the matching tag for the GPU family (e.g. `89-1.5` for Ada/Hopper,
  `86-1.5` for Ampere/A100).
- **Storage**: attach a **Network Volume** (~10 GB is plenty for SPECTER2).
  The merged model will live here and survive pod restarts.

## 3. Get the merged model onto the volume

Two options. **A is faster the first time, B is more reproducible.**

### A. Upload from your laptop (~500 MB)

1. Launch the pod once with a placeholder command (`sleep infinity`).
2. Open the pod's web terminal.
3. From your laptop:

   ```bash
   ls ~/Library/Caches/org.R-project.R/R/openalexVectorComp/specter2_proximity_merged/
   runpodctl send ~/Library/Caches/org.R-project.R/R/openalexVectorComp/specter2_proximity_merged
   ```

4. In the pod terminal, change into the network volume (usually `/workspace`
   or `/runpod-volume`) and receive:

   ```bash
   cd /runpod-volume
   runpodctl receive <code-from-laptop>
   ```

5. Stop the placeholder pod. The model now persists on the volume.

### B. Merge on the pod

The pod has a GPU + Python — run the upstream merge directly:

```bash
pip install transformers adapters torch
python scripts/prepare_specter2_merged.py   # adapt path; saves to /runpod-volume/specter2_proximity_merged/
```

Slower first time (downloads SPECTER2 base from HF), but reproducible and
keeps the laptop out of the loop.

## 4. Launch the real pod

**Container start command**: replace the template default with either

- a copy of `scripts/start_tei_runpod.sh` baked into a custom image, or
- the equivalent inline:

  ```
  text-embeddings-router \
    --model-id /runpod-volume/specter2_proximity_merged \
    --served-model-name allenai/specter2_proximity_merged \
    --port 8080 \
    --max-batch-tokens 131072 \
    --max-client-batch-size 512 \
    --max-concurrent-requests 2048 \
    --pooling cls \
    --auto-truncate
  ```

**Expose HTTP ports**: 8080. RunPod issues a URL like
`https://<pod-id>-8080.proxy.runpod.net` with TLS terminating at the proxy.

## 5. Auth (recommended)

The RunPod public proxy is open by default — anyone with the URL can hit your
TEI. To prevent that:

- Add a tiny **nginx or Caddy** sidecar in the pod that checks
  `Authorization: Bearer <secret>` before forwarding to `localhost:8080`.
- Or use RunPod's **private networking** + a wireguard tunnel from your laptop.
- Or skip auth if you're OK with the pod running briefly and being torn down.

Save the token locally:

```r
keyring::key_set("API_TEI")   # paste the secret at the prompt
```

## 6. Point the pipeline at the pod

Edit [config.yaml](config.yaml):

1. Uncomment the `SPECTER2_runpod:` block under `embeddings:`.
2. Set `host: <pod-id>-8080.proxy.runpod.net`.
3. Flip the top-level `active_embedding: SPECTER2_runpod`.

`scheme: https` and `auth_token_keyring: API_TEI` are already in the template
— `build_tei_backend()` picks them up and sets `OVC_API_TOKEN` for the
package's request layer.

## 7. Smoke test

```bash
TOKEN=$(R -e 'cat(keyring::key_get("API_TEI"))' 2>/dev/null)
HOST=<pod-id>-8080.proxy.runpod.net

curl -s -H "Authorization: Bearer $TOKEN" https://$HOST/health && echo
curl -s -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' \
     -d '{"inputs":"Hello world"}' \
     https://$HOST/embed | jq 'length'
# expect: 768
```

## 8. Pilot the pipeline

Set `pilot_n: 1000` in the active config block, then:

```r
targets::tar_make(names = tidyselect::starts_with("emb_"))
```

Watch the shard-watcher output (`rows/s`, ETA). Compare to your local
baseline. If the speed-up is worth the cost, flip back to `pilot_n: null` for
the full run.

## 9. Tear down

When done, **stop the pod** (you keep the volume at ~free cost) or terminate
entirely. Don't leave it running idle — A100 is ~$1/hr even when not
embedding.

---

## Things to watch for

### Latency dominates if `max_batch_size` is too small

The config template bumps `max_batch_size` from 64 (local) → 256 (RunPod). On
a public proxy, RTT is ~30 ms per request; small batches make this dominate
GPU work. Watch the first few shards' `rows/s`: if pod GPU util is **<80%**
during a shard, raise `max_batch_size` to 512.

### Pod dashboard sometimes labels the exposed port as HTTP

The RunPod proxy auto-terminates TLS regardless — your config uses
`scheme: https` for the public URL. If you ever hit the pod over private
wireguard instead, switch to `scheme: http` and `port: 8080`.

### Verify the model id

`backend_info()` will show `model_id` from TEI's `--served-model-name`. The
`config=<X>` partition is keyed on `active_embedding`, **not** on `model_id` —
so corpus + keypaper embeddings under `SPECTER2_runpod` end up in their own
config dir, separate from your local `SPECTER2/` data. Intentional: you can
sanity-check the two side by side.

### Optional: bake the model into a custom image

For repeated RunPod runs, use [docker/tei-runpod/](docker/tei-runpod/) — a
multi-stage Dockerfile that merges the SPECTER2 adapter at build time and
copies the result into a TEI runtime image. Build, push to GHCR or Docker
Hub, then point the RunPod template at it. Eliminates step 3 from future
pod boots and removes the network-volume dependency.

See [docker/tei-runpod/README.md](docker/tei-runpod/README.md) for build
commands and CUDA-tag selection.
