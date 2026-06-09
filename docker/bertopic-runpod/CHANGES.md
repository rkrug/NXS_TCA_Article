# bertopic-runpod — CHANGES

Image versions published as `ghcr.io/rkrug/bertopic-runpod:vX.Y.Z`.

Semantic versioning, loosely:
- **MAJOR** — incompatible Dockerfile base or breaking CLI change in the GPU script.
- **MINOR** — new feature in the image (new entrypoint behaviour, new bundled tool, etc.).
- **PATCH** — bug fixes, small tweaks, dependency bumps that don't change the surface.

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
