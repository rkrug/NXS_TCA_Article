# RunPod-side BERTopic image: cuml (RAPIDS) + BERTopic + sshd + idle watchdog.
#
# Designed to host one-shot BERTopic GPU runs orchestrated from the local
# R wrapper R/run_bertopic_runpod.R via SSH. The wrapper scp's the
# embedding parquets in, invokes the GPU script, scp's the result parquets
# back.
#
# Build (from repo root):
#   docker buildx build --platform linux/amd64 \
#       -t ghcr.io/<you>/bertopic-runpod:latest \
#       -f docker/bertopic-runpod/Dockerfile .
#   docker push ghcr.io/<you>/bertopic-runpod:latest
#
# RunPod template:
#   Container Image: ghcr.io/<you>/bertopic-runpod:latest
#   Expose TCP Ports: 22         (SSH — for the orchestrator)
#   Env Vars:
#     RUNPOD_API_KEY = <Secret>  (idle watchdog needs this to stop the pod)
#     IDLE_MIN       = 5
#   Public SSH key set via the RunPod template "Authorized Keys" field.

# RAPIDS base image bundles Python + cuml + cudf for the supported CUDA
# versions. cuml's UMAP and HDBSCAN GPU implementations are the whole point
# of Path B. Pin the tag to keep cuml/cuda combo reproducible.
#
# CUDA 12.0 (not 12.5): RunPod's 550-series host drivers (most common as
# of 2026-06) ship with a cuSPARSE regression that fails cuml.UMAP.fit
# initialisation when the runtime is 12.5. CUDA 12.0 requires driver
# >= 525 — covered by essentially every RunPod node. RAPIDS 24.10 ships
# tags for 11.8 / 12.0 / 12.5 only; 12.4 doesn't exist. We lose no
# cuml/bertopic functionality at 12.0.
FROM rapidsai/base:24.10-cuda12.0-py3.11

# rapidsai/base runs as a non-root user by default; we need root for apt,
# sshd, and to keep the runtime simple (RunPod's SSH access is root-based).
USER root

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    DEBIAN_FRONTEND=noninteractive

# ---- system deps -----------------------------------------------------------
# curl + ca-certificates: idle watchdog uses curl to talk to the RunPod API
# openssh-server: SSH transport so the orchestrator can ssh in (cfg push +
#   result download)
# rsync: result-parquet download from /work/out back to laptop. Phase 1
#   no longer rsyncs embeddings up — pod reads them from R2 directly via
#   duckdb httpfs — but the small result download still uses rsync.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openssh-server \
        curl \
        ca-certificates \
        rsync \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/run/sshd /root/.ssh /work \
    && chmod 700 /root/.ssh

# ---- python deps -----------------------------------------------------------
# v0.1.8 refactored away from BERTopic's monolithic fit_transform to direct
# cuml + sklearn orchestration with R2 stage caching. The remaining deps:
#   pyarrow / duckdb : parquet I/O + R2 anti-join streaming
#   pyyaml           : per-run cfg file
#   boto3            : R2 client for pickle + meta.json artefacts (parquet
#                      uses pyarrow's R2 path via the bucket name in URLs)
#   cloudpickle      : cuml model serialisation; stdlib pickle chokes on
#                      cuml's C-extension internals
#   scikit-learn     : CountVectorizer + TfidfTransformer for c-TF-IDF
#                      (already pulled by bertopic but pinned explicitly here
#                      because v0.1.8 doesn't import bertopic at all)
#
# bertopic stays installed for two reasons: (1) backwards compat with anyone
# who copies the older monolithic gpu script onto the pod, (2) it pulls
# umap-learn + hdbscan-learn which are harmless backups even though we
# always use cuml at runtime.
RUN pip install --no-cache-dir \
        "bertopic>=0.16,<1" \
        "pyarrow" \
        "pyyaml" \
        "duckdb>=1.0,<2" \
        "boto3" \
        "cloudpickle" \
        "scikit-learn"

# Pre-install duckdb's httpfs extension so the pod doesn't fetch it at
# first use. Phase 1 reads embeddings from Cloudflare R2 via httpfs, so
# this needs to be available even if the pod ends up on a network where
# duckdb's extension repo is throttled.
RUN python3 -c "import duckdb; con = duckdb.connect(); con.execute('INSTALL httpfs'); con.execute('LOAD httpfs')"

# Make `python` resolve in non-interactive sshd-spawned shells. RAPIDS
# base puts the python binary under /opt/conda/bin which isn't on the
# default SSH PATH. Without this, ssh ... 'python ...' returns 127.
RUN ln -sf /opt/conda/bin/python /usr/local/bin/python

# ---- runpodctl (for idle-watchdog self-stop) ------------------------------
ARG RUNPODCTL_VERSION=v1.14.4
ADD https://github.com/runpod/runpodctl/releases/download/${RUNPODCTL_VERSION}/runpodctl-linux-amd64 /usr/local/bin/runpodctl
RUN chmod +x /usr/local/bin/runpodctl

# ---- scripts + idle watchdog ----------------------------------------------
COPY scripts/run_bertopic_gpu.py            /opt/run_bertopic_gpu.py
COPY docker/bertopic-runpod/entrypoint.sh   /entrypoint.sh
COPY docker/bertopic-runpod/bertopic_idle_watchdog.sh \
                                            /usr/local/bin/bertopic_idle_watchdog.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/bertopic_idle_watchdog.sh /opt/run_bertopic_gpu.py

# Heartbeat file — the GPU script touches it at start + per step; SSH
# sessions touch it too via PAM. Watchdog stops the pod if mtime > IDLE_MIN.
RUN mkdir -p /work && touch /work/.heartbeat

# ---- defaults --------------------------------------------------------------
# PYTHONUNBUFFERED=1: flush stdout/stderr per-line instead of block-buffering
# the 4 KB SSH pipe. Without this, [info]/[step] log lines from
# /opt/run_bertopic_gpu.py stall in the buffer for minutes before the
# orchestrator (R session) sees them, making in-flight progress
# invisible. cuml and BERTopic library messages are also covered.
ENV IDLE_MIN=5 \
    POLL_SEC=30 \
    PYTHONUNBUFFERED=1

EXPOSE 22

# OCI labels — link the GHCR package to the TCAC 2.0 repo on github.com.
LABEL org.opencontainers.image.source=https://github.com/rkrug/TCAC-2.0 \
      org.opencontainers.image.description="BERTopic GPU image (cuml + bertopic) for RunPod, with sshd + idle-watchdog. Built for TCAC 2.0."

ENTRYPOINT ["/entrypoint.sh"]
