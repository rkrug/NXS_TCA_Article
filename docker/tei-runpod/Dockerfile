# Multi-stage Dockerfile: bakes the merged SPECTER2 model into a TEI image
# ready to drop into a RunPod pod (no first-boot model download, no volume
# mount required).
#
# Build:
#   docker buildx build --platform linux/amd64 \
#     -t ghcr.io/<you>/tei-specter2:proximity \
#     --build-arg ADAPTER=proximity \
#     -f docker/tei-runpod/Dockerfile .
#
#   docker push ghcr.io/<you>/tei-specter2:proximity
#
# RunPod pod template:
#   Container Image: ghcr.io/<you>/tei-specter2:proximity
#   Expose HTTP port: 8080
#   (no Container Start Command — entrypoint launches TEI)

# ----------------------------------------------------------------------------
# Global build args — must be declared BEFORE any FROM line so they can be
# interpolated into stage 2's image reference.
# ----------------------------------------------------------------------------
ARG TEI_TAG=89-1.5
ARG ADAPTER=proximity

# ----------------------------------------------------------------------------
# Stage 1 — merge the SPECTER2 adapter into the base encoder.
# Uses the existing project script so the on-pod model is identical to the
# laptop one. ADAPTER yields both proximity and adhoc_query images.
# ----------------------------------------------------------------------------
FROM python:3.11-slim AS merger

ARG ADAPTER
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

# adapters 0.2.x pins transformers ~= 4.40 and uses
# huggingface_hub.file_download.url_to_filename, which was removed in
# huggingface_hub >= 0.20. Pin hub back to keep the import working.
RUN pip install --no-cache-dir \
        "adapters>=0.2,<1" \
        "huggingface_hub<0.20" \
        "torch>=2.2,<3"

WORKDIR /work
COPY scripts/prepare_specter2_merged.py /work/prepare_specter2_merged.py

ENV OVC_SPECTER2_PATH=/merged
RUN python /work/prepare_specter2_merged.py --adapter "${ADAPTER}"

# Sanity check: the merged dir must contain a HF config.
RUN test -f /merged/config.json

# ----------------------------------------------------------------------------
# Stage 2 — TEI runtime with the merged model copied in.
# Pick the TEI tag matching your RunPod GPU family:
#   89-1.5  → Ada / Hopper / RTX 4090 / H100
#   86-1.5  → Ampere / A100 / A6000
#   80-1.5  → A100 (compute 8.0)
# Pass via --build-arg TEI_TAG=<tag>.
# ----------------------------------------------------------------------------
FROM ghcr.io/huggingface/text-embeddings-inference:${TEI_TAG} AS runtime

ARG ADAPTER
LABEL org.opencontainers.image.source=https://github.com/rkrug/TCAC-2.0 \
      org.opencontainers.image.description="TEI server with merged SPECTER2 ${ADAPTER} adapter, ready for RunPod."

# Merged model lives at /model inside the image.
COPY --from=merger /merged /model

# TEI server-side tuning for A100/H100 — overridable at runtime via -e.
ENV TEI_PORT=8080 \
    TEI_MAX_BATCH_TOKENS=131072 \
    TEI_MAX_CONCURRENT=2048 \
    TEI_MAX_CLIENT_BATCH=512 \
    TEI_SERVED_NAME=allenai/specter2_${ADAPTER}_merged

# curl is needed by the watchdog to poll TEI /metrics; the runtime base
# image ships without it. awk is in coreutils → already present.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Idle watchdog: stops the pod after IDLE_MIN minutes with no TEI requests.
# Needs runpodctl + RUNPOD_API_KEY env var (set in the pod template).
# ADD handles the download natively (curl now available too — both work).
ARG RUNPODCTL_VERSION=v1.14.4
ADD https://github.com/runpod/runpodctl/releases/download/${RUNPODCTL_VERSION}/runpodctl-linux-amd64 /usr/local/bin/runpodctl
RUN chmod +x /usr/local/bin/runpodctl

COPY docker/tei-runpod/tei_idle_watchdog.sh /usr/local/bin/tei_idle_watchdog.sh
RUN chmod +x /usr/local/bin/tei_idle_watchdog.sh

COPY docker/tei-runpod/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV IDLE_MIN=5

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
