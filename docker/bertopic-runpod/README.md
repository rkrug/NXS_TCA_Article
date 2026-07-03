# `docker/bertopic-runpod/` — BERTopic GPU image

A RunPod-deployable image that runs BERTopic with `cuml.UMAP` +
`cuml.HDBSCAN` on the GPU, so the full 5+M-row corpus fits in VRAM and
clusters in minutes-to-hours instead of days.

The image is **not** self-running like the TEI image — it boots into an
SSH-ready idle state. The local `R/run_bertopic_runpod.R` wrapper scp's
the embedding parquets in, ssh-triggers `/opt/run_bertopic_gpu.py`, and
scp's the result parquets back.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | RAPIDS base + BERTopic + sshd + runpodctl + idle watchdog. |
| `entrypoint.sh` | Brings up sshd, starts the watchdog, `tail -f /dev/null`. |
| `bertopic_idle_watchdog.sh` | Heartbeat-based auto-stop after `IDLE_MIN` min. |
| `.dockerignore` | Keeps the build context to a handful of needed files. |

## Requirements

### GPU — suggested: **L40S**

For a ~5.77 M-row corpus + ~141 keypapers:

| GPU | VRAM | $/hr (Community) | Verdict |
|---|---|---|---|
| **L40S** ✅ | 48 GB | ~$0.86 | **Suggested.** cuml UMAP needs ~18 GB (embeddings) + 5–8 GB workspace; HDBSCAN is light. Fits comfortably with margin. Same GPU class as the TEI pod, predictable behaviour. |
| A100 80GB | 80 GB | ~$1.60 | Safe headroom; pick if you'll run multiple ablations or scale the corpus. |
| H100 80GB | 80 GB | ~$2.99 | Overkill — cuml on a 100M-param embedding model doesn't benefit from H100 tensor cores. |
| L40 (non-S) | 48 GB | ~$0.71 | Same VRAM as L40S, ~30–50% slower compute. Cheaper if patience > speed. |
| A40 | 48 GB | ~$0.39 | Cheap, slow, works. |

Cuml auto-selects the right CUDA kernels at runtime, so the same image
runs on any of the above without rebuilding.

### CPU & RAM

| Resource | Minimum | Recommended |
|---|---|---|
| vCPUs | 8 | 16+ (faster parquet read) |
| System RAM | 80 GB | **120 GB+** |

BERTopic + pandas hold the full embedding dataframe in CPU memory before
pushing to GPU. 5.77 M × 768 float32 ≈ 17 GB, plus pandas/pyarrow
overhead and BERTopic's vectorizer can peak at ~50–70 GB. RunPod L40S
templates typically come with 100+ GB system RAM by default.

### Disk

| Mount | Size | Rationale |
|---|---|---|
| **Container disk** | 25 GB | Image (~7 GB) + Python heap + scratch + logs. |
| **Volume disk** at `/work` | **60 GB** | Uploaded embedding parquets (~32 GB: primary + fallback variants for corpus + keypapers) + outputs + heartbeat + scratch room. |

Volume disk survives pod stop/restart; container disk is ephemeral.

### Network

- **TCP/22** exposed via RunPod's TCP port mapping — required because
  rsync of ~32 GB over the HTTPS proxy is impractical.
- No HTTP ports needed.
- Expect ~50 min for the upload at typical RunPod ingress speeds
  (~10 MB/s); region matters more here than for the TEI workload.

### Region

Same logic as TEI: prefer **Any region** for capacity. Pin only if
you've measured a latency reason. EU regions have fewer L40S pods but
shorter RTT for an EU laptop; US regions have more capacity but slower
sustained throughput from EU.

### Cost projection (5.77 M run on L40S)

| Phase | Time | Cost |
|---|---|---|
| Pod boot + image pull | ~3 min | $0.04 |
| rsync upload (~32 GB) | ~50 min | $0.72 |
| cuml UMAP + HDBSCAN fit | ~30–60 min | $0.43–0.86 |
| Fallback transform | ~10–30 min | $0.14–0.43 |
| c-TF-IDF + parquet write | ~5 min | $0.07 |
| rsync download | ~2 min | $0.03 |
| Idle until watchdog stops | ~5 min | $0.07 |
| **Total** | **~2–2.5 h** | **~$1.50–2.20** |

### Pre-flight checklist

1. Image pushed to GHCR, **public** visibility (so RunPod can pull without credentials).
2. `~/.ssh/id_ed25519.pub` content copied to clipboard — goes into the template's `PUBLIC_KEY` env var.
3. `RUNPOD_API_KEY` saved as a **Secret** in RunPod settings.
4. Volume size **60 GB** in the template — easy to under-provision and run out of disk during upload.
5. `config.yaml: bertopic.configs.default_runpod.ssh_host` will be filled in **after** the pod is up (RunPod assigns the SSH host on boot).

## Build (from repo root)

```bash
docker buildx build --platform linux/amd64 \
    -t ghcr.io/rkrug/bertopic-runpod:v0.1.0 \
    -f docker/bertopic-runpod/Dockerfile .

docker push ghcr.io/rkrug/bertopic-runpod:v0.1.0
```

`--platform linux/amd64` matters on Apple Silicon — RunPod is amd64.

No per-GPU tag needed (unlike the TEI image): cuml auto-selects the right
CUDA kernels at runtime for L40, L40S, A100, H100, etc.

### Tagging strategy

**Don't use `:latest`** for the pod template's `Container Image` field —
RunPod's own docs warn against it (caching surprises + no rollback).

Use either of:

- **Semantic version** (`:v0.1.0`) — manual but human-readable. Bump on
  meaningful changes; pin the pod template to a specific version.
- **Immutable digest** (`@sha256:abc123…`) — strongest reproducibility
  guarantee. Get it after a push with:
  ```bash
  docker inspect --format='{{index .RepoDigests 0}}' \
      ghcr.io/rkrug/bertopic-runpod:v0.1.0
  ```
  Use the resulting `@sha256:…` string in the pod template for the paper.

Re-tagging an existing image is essentially free — only the manifest
gets pushed, not the GBs of layers:

```bash
docker tag  ghcr.io/rkrug/bertopic-runpod:v0.1.0 \
            ghcr.io/rkrug/bertopic-runpod:v0.2.0
docker push ghcr.io/rkrug/bertopic-runpod:v0.2.0
```

## Pod template

RunPod → **GPU Pod** → "Edit Template":

- **Container Image**: `ghcr.io/rkrug/bertopic-runpod:v0.1.0` (or the immutable `@sha256:…` digest — see "Tagging strategy")
- **Container Start Command**: *(leave blank — entrypoint handles it)*
- **Expose TCP Ports**: `22` (SSH transport)
- **Container Disk**: `20 GB` (logs + temp work)
- **Volume Disk**: `60 GB` mounted at `/work` (holds the embedding
  parquets you scp in — ~32 GB for primary + fallback + keypapers)
- **Environment Variables**:
  - `PUBLIC_KEY` = the contents of your `~/.ssh/id_ed25519.pub` (one
    line). The entrypoint injects this into `/root/.ssh/authorized_keys`
    at boot so sshd accepts your key. **Plain env var, not a Secret** —
    the public half is public by definition. Required for SSH access.
  - `RUNPOD_API_KEY` = your RunPod API key (use a **Secret** for this
    one) — required for the idle watchdog to call `runpodctl stop pod`.
  - `IDLE_MIN` = `5` (override of the image default; see "Tuning" below)
  - `POLL_SEC` = `30`

## Use from R

After the pod boots, copy its SSH connection string into
`config.yaml: bertopic.configs.default_runpod.ssh_host` (and `_port`,
`_user`, `_key_path` if non-default). Then:

```r
targets::tar_make(names = "topics_tcac20_runpod")
```

The wrapper handles the upload + run + download cycle.

## Idle auto-stop

`bertopic_idle_watchdog.sh` polls `/work/.heartbeat` every `POLL_SEC`
seconds. The heartbeat is touched:

- At boot, by the entrypoint
- At start + after each step, by `scripts/runpod/run_bertopic_gpu.py`
- (Optional) manually during interactive SSH: `touch /work/.heartbeat`

If `now - heartbeat_mtime ≥ IDLE_MIN`, the watchdog calls
`runpodctl stop pod $RUNPOD_POD_ID`. Pod stops, billing pauses, volume +
image cache survive — restart from the RunPod UI when next needed.

### Tuning

Override at pod-template level:

| Var | Default | Effect |
|---|---|---|
| `IDLE_MIN` | `5` | Minutes of no heartbeat → stop. |
| `POLL_SEC` | `30` | Watchdog check cadence. |
| `HEARTBEAT_PATH` | `/work/.heartbeat` | File whose mtime is "last activity". |
| `LOG_DIR` | `/work` | Where the entrypoint persists its log file. |

## Persistent logs

The entrypoint tees its own output (and the watchdog's, via inherited
fds) to `${LOG_DIR}/bertopic-current.log`. Goes to a volume-mounted path
so it survives pod stop/restart.

**On every boot**, the previous run's log is renamed:
`bertopic-current.log` → `bertopic-previous.log` (old previous is
overwritten). You always have one historical log, never more — bounded
space, no log-rotation daemon needed.

Reading after a crash:

```bash
ssh <pod> "tail -200 /work/bertopic-previous.log"
```

The GPU script's own logs (one per `tar_make` invocation of
`topics_tcac20_runpod`) are written separately by the R wrapper, also
under `/work/`. Naming: `run_bertopic_gpu-<UTC timestamp>.log`. These
persist indefinitely until manually cleared — they're small (few MB
each) so unbounded retention is fine.

### Volume sizing reminder

The 60 GB volume holds:
- ~32 GB embedding parquets (primary + fallback × corpus + keypaper)
- ~few hundred MB output parquets
- 2× ≤1 GB log files
- Heartbeat + scratch

Still comfortably within 60 GB.

Set `IDLE_MIN=0` or omit `RUNPOD_API_KEY` to effectively disable the
watchdog.

## Why bake everything into one image

- Cold-start latency: image already has BERTopic, cuml, the GPU script —
  ready seconds after the pod boots.
- Reproducibility: `docker pull <digest>` = exact code that produced the
  topics. Useful for the paper's methods section.
- No "first-boot pip install" wasting GPU time.

Trade-off: image is ~5–7 GB heavier than the stock RAPIDS image.
Negligible vs the cost of running the pod.

## Migration to openalexVectorComp

Once stable, this whole directory (Dockerfile, entrypoint, watchdog,
README) lifts to
`openalexVectorComp/inst/docker/bertopic-runpod/`. Same with
`scripts/runpod/run_bertopic_gpu.py` →
`openalexVectorComp/inst/scripts/run_bertopic_gpu.py`. No project-side
changes needed apart from updating the COPY paths in the Dockerfile.
