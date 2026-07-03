#!/usr/bin/env bash
# Start TEI inside a RunPod container against a merged SPECTER2 model.
# Run THIS SCRIPT ON THE POD (not on your laptop).
#
# Differences from start_tei_specter2.sh:
#   * Defaults tuned for A100/H100 (max-batch-tokens 131072, concurrent 2048,
#     max-client-batch-size 512) instead of Apple-Metal scale.
#   * Model is expected at a pod-volume path, not the macOS R cache.
#   * Listens on $PORT (default 8080); use RunPod's "Expose HTTP port" to
#     publish it as https://<pod-id>-8080.proxy.runpod.net (route plain HTTP
#     on the pod, TLS terminates at the proxy).
#
# Usage:
#   ./scripts/start_tei_runpod.sh                # proximity (default)
#   ./scripts/start_tei_runpod.sh adhoc_query
#
# Environment overrides:
#   OVC_SPECTER2_PATH          Path to merged model dir (default: /runpod-volume/specter2_<adapter>_merged)
#   OVC_TEI_PORT               Port for text-embeddings-router      (default: 8080)
#   OVC_TEI_MAX_BATCH_TOKENS   Max tokens per batch                  (default: 131072)
#   OVC_TEI_MAX_CONCURRENT     Max concurrent requests               (default: 2048)
#   OVC_TEI_MAX_CLIENT_BATCH   Max client batch size                 (default: 512)

set -euo pipefail

ADAPTER="${1:-proximity}"

case "${ADAPTER}" in
    proximity)   SUBDIR="specter2_proximity_merged"; SERVED_NAME="allenai/specter2_proximity_merged" ;;
    adhoc_query) SUBDIR="specter2_adhoc_merged";     SERVED_NAME="allenai/specter2_adhoc_merged" ;;
    *)
        echo "Unknown adapter: ${ADAPTER} (expected: proximity | adhoc_query)" >&2
        exit 1
        ;;
esac

MODEL_PATH="${OVC_SPECTER2_PATH:-/runpod-volume/${SUBDIR}}"
PORT="${OVC_TEI_PORT:-8080}"
MAX_BATCH_TOKENS="${OVC_TEI_MAX_BATCH_TOKENS:-131072}"
MAX_CONCURRENT="${OVC_TEI_MAX_CONCURRENT:-2048}"
MAX_CLIENT_BATCH="${OVC_TEI_MAX_CLIENT_BATCH:-512}"

if [ ! -f "${MODEL_PATH}/config.json" ]; then
    echo "Merged SPECTER2 model not found at: ${MODEL_PATH}" >&2
    echo "Mount it via a RunPod volume, or bake it into the pod image." >&2
    exit 1
fi

if ! command -v text-embeddings-router >/dev/null 2>&1; then
    echo "text-embeddings-router not on PATH. Use the official ghcr.io/huggingface/text-embeddings-inference image." >&2
    exit 1
fi

echo "Serving ${ADAPTER} model: ${MODEL_PATH}"
echo "  served-model-name:        ${SERVED_NAME}"
echo "  port:                     ${PORT}"
echo "  max-batch-tokens:         ${MAX_BATCH_TOKENS}"
echo "  max-client-batch-size:    ${MAX_CLIENT_BATCH}"
echo "  max-concurrent-requests:  ${MAX_CONCURRENT}"
echo "  pooling:                  cls"
echo "  auto-truncate:            on"

exec text-embeddings-router \
    --model-id "${MODEL_PATH}" \
    --served-model-name "${SERVED_NAME}" \
    --port "${PORT}" \
    --max-batch-tokens "${MAX_BATCH_TOKENS}" \
    --max-client-batch-size "${MAX_CLIENT_BATCH}" \
    --max-concurrent-requests "${MAX_CONCURRENT}" \
    --pooling cls \
    --auto-truncate
