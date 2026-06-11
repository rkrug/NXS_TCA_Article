# bertopic-runpod — CHANGES

Image versions published as `ghcr.io/rkrug/bertopic-runpod:vX.Y.Z`.

Semantic versioning, loosely:
- **MAJOR** — incompatible Dockerfile base or breaking CLI change in the GPU script.
- **MINOR** — new feature in the image (new entrypoint behaviour, new bundled tool, etc.).
- **PATCH** — bug fixes, small tweaks, dependency bumps that don't change the surface.

## v0.1.4 — 2026-06-11

Survivability fixes prompted by the first Phase 1 dispatch:

- **`/opt/run_bertopic_gpu.py`**: spawn a daemon thread on script start
  that touches `/work/.heartbeat` every 30 seconds for the script's
  lifetime. Survives long blocking calls (duckdb R2 reads, cuml.UMAP
  fit, HDBSCAN) where the main thread can't manually heartbeat —
  previously the watchdog (IDLE_MIN=10 default) would kill the pod
  during the ~10 min R2 read of the primary corpus variant. The thread
  is daemon=True so it dies with the process, allowing the watchdog to
  cleanly idle-stop the pod ~10 min after script exit.
- **Dockerfile**: add `ln -sf /opt/conda/bin/python /usr/local/bin/python`
  so `python` resolves in non-interactive sshd-spawned shells. RAPIDS
  base puts python under `/opt/conda/bin/` which isn't on the default
  SSH PATH; without the symlink, `ssh ... 'python ...'` returns exit
  code 127. The R wrapper's runtime workaround
  (`[ -x /usr/local/bin/python ] || ln -sf ...`) is now redundant for
  v0.1.4+ pods but harmless to leave in place for v0.1.3 backwards
  compatibility.

Pod template requirements unchanged from v0.1.3 (`PUBLIC_KEY`,
`RUNPOD_API_KEY`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
`IDLE_MIN`).

## v0.1.3 — 2026-06-09

Phase 1 of the cloud-storage migration: embeddings now live in
Cloudflare R2, and the pod reads them directly via duckdb httpfs. No
more 32 GB rsync upload from the laptop at the start of each run.

- **`/opt/run_bertopic_gpu.py`**: accepts `s3://bucket/prefix/...` URIs
  for `--corpus-emb-dir` and `--reference-emb-dir`. duckdb httpfs is
  configured at startup from env vars (`R2_ACCESS_KEY_ID`,
  `R2_SECRET_ACCESS_KEY`) plus endpoint/bucket carried in the cfg yaml.
  Local-path inputs still work — the script switches on the `s3://`
  prefix at parse time.
- **Dockerfile**: add `rsync` to the apt install list. v0.1.2 was
  missing it; the orchestrator pre-installed it on the running pod as a
  workaround. Now baked in.
- **Dockerfile**: pre-install duckdb's `httpfs` extension at image
  build time so the first query doesn't hit the duckdb extension repo.
- **Required env vars on the pod template** (RunPod Secrets, encrypted
  at rest):
  - `R2_ACCESS_KEY_ID`
  - `R2_SECRET_ACCESS_KEY`
  All others as before (`PUBLIC_KEY`, `RUNPOD_API_KEY`, `IDLE_MIN`).

Existing local-only workflows (passing real filesystem paths) keep
working — this release is backward-compatible for the entry script.

## v0.1.2 — 2026-06-09

- **`/opt/run_bertopic_gpu.py`**: streams the fallback variant via
  duckdb anti-join in 50K-row chunks, mirroring the laptop-side
  `run_bertopic_local.py` refactor. The primary variant is still
  materialised once for cuml.UMAP.fit (necessary — UMAP can't be
  streamed), but afterwards the fit-time DataFrame is freed before
  the fallback transform begins. Result: a sustained peak of ~15 GB
  CPU RAM instead of ~18 GB and brief spikes from holding both
  primary and fallback DataFrames simultaneously. Safety margin on
  smaller pods, and code-path parity with Path A.
- **Dockerfile**: add `duckdb>=1.0,<2` to the pip install line.

## v0.1.1 — 2026-06-08

- **entrypoint.sh**: read `PUBLIC_KEY` env var and write it to
  `/root/.ssh/authorized_keys` at boot, so SSH access works on custom
  images without relying on RunPod's image-side injection. Pod template
  now just needs `PUBLIC_KEY=<your id_ed25519.pub content>`.
- **Dockerfile**: add `org.opencontainers.image.source` and
  `…image.description` LABELs so GHCR auto-links the package to the
  https://github.com/rkrug/TCAC-2.0 repo. Cost: trivial — labels are
  a tiny final layer.
- **entrypoint.sh**: persistent logs to `${LOG_DIR:=/work}` —
  `bertopic-current.log` rotated to `bertopic-previous.log` on every
  boot (keeps exactly one historical log; old previous is overwritten).
  Tee-pattern: `exec > >(tee -a "$LOG") 2>&1` so RunPod's Logs panel
  still works while the file accumulates.
- Updated README: point examples at `:v0.1.0`/`:v0.1.1`, add "Tagging
  strategy" subsection (don't use moving tags for templates), document
  `PUBLIC_KEY` template env var, add "Persistent logs" section.

## v0.1.0 — 2026-06-08

Initial release.

- Base: `rapidsai/base:24.10-cuda12.5-py3.11`.
- BERTopic 0.17.x, pyarrow, pyyaml.
- runpodctl v1.14.4 for the idle-watchdog's self-stop call.
- sshd for orchestrator transport (rsync + ssh-triggered runs).
- Heartbeat-based idle watchdog (`/work/.heartbeat`, default `IDLE_MIN=5`).
- `/opt/run_bertopic_gpu.py` baked in (cuml UMAP + cuml HDBSCAN +
  c-TF-IDF).
