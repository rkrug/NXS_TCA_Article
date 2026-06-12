# bertopic-runpod — CHANGES

Image versions published as `ghcr.io/rkrug/bertopic-runpod:vX.Y.Z`.

Semantic versioning, loosely:
- **MAJOR** — incompatible Dockerfile base or breaking CLI change in the GPU script.
- **MINOR** — new feature in the image (new entrypoint behaviour, new bundled tool, etc.).
- **PATCH** — bug fixes, small tweaks, dependency bumps that don't change the surface.

## v0.1.12 — pending build

Memory fix in stage_ctfidf — push per-topic aggregation into duckdb.

After v0.1.11 dispatched and successfully wrote UMAP + HDBSCAN
caches to R2, the c-TF-IDF stage OOM'd while building docs_per_topic.
The previous implementation in pandas materialised:

- df_text (corpus text): ~50 GB
- merged df with topic_id column: ~50 GB
- df["doc"] concatenated title+abstract column: +10 GB
- groupby/apply intermediates: ~20-30 GB

Plus the ~25 GB of cuml UMAP + HDBSCAN models already on the host →
~115 GB total. On a 117 GB pod that triggered the kernel OOM-killer.

scripts/run_bertopic_gpu.py stage_ctfidf:
- Replace pandas-side join + groupby + apply with a single duckdb
  SQL query that does join + group_concat in C++ with bounded
  internal memory (~few GB).
- Topics_corpus DataFrame registered as a duckdb view; query reads
  corpus parquet directly from R2 (no pre-materialisation), joins
  on id, filters topic_id >= 0, group_concat's title+abstract per
  topic.
- Output: ~500 rows of {topic_id, doc}, total ~10 GB.
- New peak in stage_ctfidf ~35-40 GB (cuml models + duckdb buffers +
  final docs_per_topic + Python overhead) vs ~115 GB before.

No Dockerfile changes; pure Python script refactor.

## v0.1.11 — pending build

Skip corpus text columns in the UMAP read.

After v0.1.10 shipped with the `del df_corpus` fix, the first
v0.1.10 dispatch still OOM'd at ~13 min on a 117 GB A100 PCIe pod
during the duckdb fetchdf() conversion of the corpus DataFrame —
peak ~115 GB BEFORE UMAP fit had even started. v0.1.10's del
df_corpus only frees memory AFTER the read completes, so it doesn't
help when the read itself is the OOM cause.

Root cause: `_read_full_variant_with_text` loads
`title_clean + abstract_clean + V1..V768` for all 4.6M rows. The
text columns alone are ~50-70 GB; embeddings are only ~14 GB. Stage
1 (UMAP fit) and Stage 4 (keypaper projection) never use the text
columns — those are only needed in Stage 3 (c-TF-IDF), which
already re-reads them separately via `_read_text_only`.

- **`/opt/run_bertopic_gpu.py`** new helper `_read_embeddings_only`
  reads id + V<int> columns only, skipping the bulky text. Cuts the
  corpus DataFrame size from ~50-70 GB to ~14 GB.
- `stage_umap` and `stage_project_keypapers` switch to the new
  text-less reader.
- `_read_full_variant_with_text` is kept for backwards-compat but no
  longer called from the script.

Combined with v0.1.10's del df_corpus before fit_transform, peak
host RAM in stage_umap drops from ~115 GB (v0.1.10) to ~30-40 GB
(v0.1.11). Any pod with ≥60 GB host RAM is now safe.

No Dockerfile or entrypoint changes; pure Python script edits.

## v0.1.10 — 2026-06-12 (built + pushed, ran but OOM'd at the read step)

Memory-pressure fix #1 in stage_umap.

- **`/opt/run_bertopic_gpu.py`** `stage_umap`: extract `ids` + numpy
  matrix `X` from df_corpus, then `del df_corpus; gc.collect()` BEFORE
  calling fit_transform. Designed to free ~70 GB of text + embeddings
  before cuml.UMAP's host-side k-NN scratch allocations.

In production this turned out to be necessary but not sufficient —
the corpus read itself peaked at ~115 GB before the del statement
could run. v0.1.11 follows up with the second piece (skip text
columns entirely in stage_umap's reader).

No Dockerfile or entrypoint changes; pure Python script edit.

## v0.1.9 — pending build

Two reliability fixes folded into one image rebuild.

### A. Large-object multipart upload to R2

The first v0.1.8 dispatch completed cuml.UMAP fit on the full 4.6M
corpus (2091 s = 35 min), then failed when uploading the model
pickle (~1-3 GB) to R2 with `ssl.SSLEOFError: EOF occurred in
violation of protocol`. Root cause: `client.put_object` issues a
single HTTP PUT; R2's TLS endpoint drops large monolithic uploads
mid-stream. Cloudflare's own R2 docs recommend multipart upload for
anything > 5 MB.

- **`/opt/run_bertopic_gpu.py`** `_r2_put_bytes`: switch from
  `client.put_object` to `client.upload_fileobj` with explicit
  `TransferConfig(multipart_threshold=8 MB, multipart_chunksize=64 MB,
  max_concurrency=8)`. boto3 chunks the upload into 64 MB parts,
  uploads them in parallel (8 concurrent), and retries individual
  parts on transient failure. Total upload time for a 2 GB model
  goes from "single PUT that randomly fails" to ~20-40 s reliable.

No Dockerfile changes; boto3 already includes the multipart code.

### B. External heartbeat keeper self-match bug (regression in v0.1.7)

The bash heartbeat keeper added in v0.1.7 had the same self-matching
bug we already fixed in pod_watch.sh: `pgrep -f '/opt/run_bertopic_gpu.py'`
matches the keeper's own bash subshell (its argv literally contains
the script path). So the loop touched /work/.heartbeat forever even
after python died, defeating the watchdog.

In a recent run this manifested as the watchdog log showing "0 min
idle" minutes after the python process crashed — pod stayed alive
billing $1.69/h with no work to do until manually terminated.

- **docker/bertopic-runpod/entrypoint.sh**: anchor the pgrep regex
  with `^python.*/opt/run_bertopic_gpu\.py` so it matches only
  processes whose command line STARTS with "python". Bash subshells
  whose command lines start with "bash" no longer match. Now the
  watchdog correctly idle-stops the pod within IDLE_MIN minutes of a
  python exit (clean or crash).

## v0.1.8 — 2026-06-12 (built + pushed)

Major refactor: BERTopic stage caching on R2.

Three production failures pointed to the same root cause — BERTopic's
monolithic `fit_transform` holds the full corpus in memory through its
Representation step, OOM'ing on a 116 GB pod at the 4.6M-row corpus.
This refactor replaces BERTopic entirely with direct cuml + sklearn
orchestration and adds R2-backed stage caching.

- **`/opt/run_bertopic_gpu.py`**: rewritten as six explicit stages:
  1. cuml.UMAP fit on corpus primary variant only
     (keypapers decoupled — Option A from TODO_BERTopicStageCaching.md)
  2. cuml.HDBSCAN fit on UMAP coords
  3. c-TF-IDF on per-topic CONCATENATED corpus docs
     (~500 topic-documents fed to sklearn.CountVectorizer instead of
      4.6M individual docs — cuts peak Representation-step RAM by ~3x)
  4. Keypaper projection via umap_model.transform() +
     hdbscan.approximate_predict()
  5. Fallback variant projection (no-abstract corpus works), same
     mechanism, streamed via duckdb anti-join
  6. Final output composition (topic_info / topics / topic_words)

  Each fit-stage writes intermediate state to
  `s3://<bucket>/intermediate/config=<X>/umap_cfg=<hash>/hdbscan_cfg=<hash>/ctfidf_cfg=<hash>/`
  with cascade cfg-hash keying. Re-running with unchanged upstream
  params loads from cache; changing `hdbscan_*` reuses UMAP cache;
  changing `vectorizer_*` reuses UMAP+HDBSCAN; keypaper swap touches
  none of the cache.

- **Dockerfile**: added pip deps `boto3` (R2 client), `cloudpickle`
  (cuml model serialisation — stdlib pickle chokes on cuml's
  C-extensions), and explicit `scikit-learn` (was pulled transitively
  by bertopic; pinned explicitly since v0.1.8 doesn't import bertopic
  at all).

- **bertopic**: still installed in the image for backwards-compat
  with anyone copying an older monolithic script onto a v0.1.8 pod;
  the v0.1.8 script doesn't import it.

Pod template env vars unchanged:
- `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` (Secrets — now also used
  for cache reads/writes, not only embedding reads)
- `RUNPOD_API_KEY`, `PUBLIC_KEY`, `IDLE_MIN` as before.

Expected R2 cache footprint at TCAC scale (~$0.30/month even for 20+
parameter iterations):

| Stage | Size |
|---|---|
| UMAP model + coords | ~2-2.5 GB |
| HDBSCAN model + topic assignments | ~600-900 MB |
| c-TF-IDF outputs | ~50 MB |

## v0.1.7 — 2026-06-11 (built + pushed)

Robust idle-watchdog handling for long GIL-holding library calls.

The first successful Phase 1 dispatch on an A100 SXM 80GB ran cleanly
through R2 read + matrix extraction + GPU upload, then got killed by
the idle watchdog ~14 min into the cuml.UMAP.fit kernel. Root cause:
cuml's Python wrapper holds the GIL through the k-NN graph build
phase (~10-15 min), starving the in-Python heartbeat thread added in
v0.1.4. Heartbeat went stale, watchdog fired, pod stopped — but the
GPU workload was healthy throughout.

- **entrypoint.sh**: add an external bash heartbeat keeper that
  touches /work/.heartbeat every 30 s WHILE a
  /opt/run_bertopic_gpu.py process is alive. Lives outside Python,
  no GIL contention. The Python-side thread is kept as belt-and-
  braces for the R2 read phase. When the GPU script exits the
  external keeper stops touching the file and the watchdog can
  correctly stop the pod.

With this change `IDLE_MIN` can stay at sensible defaults (5-10 min)
— previously users had to bump it to 60-90 min to survive cuml fits,
which delayed legitimate idle-stop after a script crash.

## v0.1.6 — 2026-06-11 (built + pushed)

Operational ergonomics improvements gathered from the first Phase 1
dispatches.

- **Dockerfile**: add `ENV PYTHONUNBUFFERED=1`. The GPU script's
  `print()` lines (`[info] ...`, `[step] ...`, `[done] ...`) and
  library messages from cuml / BERTopic were getting stuck in the
  4 KB SSH pipe buffer for minutes at a time, so the orchestrator
  R session looked stalled while real work was happening. With
  unbuffered stdout/stderr, every log line flushes immediately and
  the R console shows the script's progress in real time.

Future-work tickets queued here for the next rebuild (not yet
applied):

- Subsample-fit option for cuml.UMAP at full corpus scale (Path B
  hangs on L40S at 4.6M rows; A100 is the workaround). See
  [TODO_BERTopicStageCaching.md](../../TODO_BERTopicStageCaching.md).

## v0.1.5 — 2026-06-11

Driver-compatibility fix prompted by the first Phase 1 dispatch hitting
a cuSPARSE init regression in NVIDIA driver 550.x running CUDA 12.5.

- **Dockerfile**: drop base image from `rapidsai/base:24.10-cuda12.5-py3.11`
  to `rapidsai/base:24.10-cuda12.0-py3.11`. The 12.0 runtime works
  reliably with driver >= 525 — covers essentially every RunPod node;
  12.5 requires >= 555 which is uncommon. RAPIDS 24.10 ships tags for
  11.8 / 12.0 / 12.5 only (no 12.4). cuml/bertopic functionality is
  identical at 12.0.

Companion change in `R/run_bertopic_runpod.R`: the pre-flight driver
check now requires driver >= 525 (was 555 for v0.1.4). Older drivers
abort dispatch in seconds rather than 5 min into cuml.UMAP.fit.

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
