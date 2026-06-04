#!/usr/bin/env bash
# Start a local TEI (text-embeddings-inference) server against a merged
# SPECTER2 model. Run scripts/prepare_specter2.sh first.
#
# Usage:
#   ./scripts/start_tei_specter2.sh                 # proximity (default)
#   ./scripts/start_tei_specter2.sh proximity
#   ./scripts/start_tei_specter2.sh adhoc_query
#
# Environment overrides:
#   OVC_SPECTER2_PATH          Path to merged model dir (overrides cache lookup)
#   OVC_TEI_PORT               Port for text-embeddings-router (default: 8080)
#   OVC_TEI_MAX_BATCH_TOKENS   Max tokens per batch              (default: 32768)
#   OVC_TEI_MAX_CONCURRENT     Max concurrent requests           (default: 512)

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

default_cache_dir() {
    case "$(uname -s)" in
    Darwin) echo "${HOME}/Library/Caches/org.R-project.R/R/openalexVectorComp/${SUBDIR}" ;;
    Linux)  echo "${XDG_CACHE_HOME:-${HOME}/.cache}/R/openalexVectorComp/${SUBDIR}" ;;
    *)      echo "${HOME}/.cache/R/openalexVectorComp/${SUBDIR}" ;;
    esac
}

MODEL_PATH="${OVC_SPECTER2_PATH:-$(default_cache_dir)}"
PORT="${OVC_TEI_PORT:-8080}"
MAX_BATCH_TOKENS="${OVC_TEI_MAX_BATCH_TOKENS:-32768}"
MAX_CONCURRENT="${OVC_TEI_MAX_CONCURRENT:-512}"
MAX_CLIENT_BATCH="${OVC_TEI_MAX_CLIENT_BATCH:-128}"

if [ ! -f "${MODEL_PATH}/config.json" ]; then
    echo "Merged SPECTER2 model not found at: ${MODEL_PATH}" >&2
    echo "Run: ./scripts/prepare_specter2.sh ${ADAPTER}" >&2
    exit 1
fi

if ! command -v text-embeddings-router >/dev/null 2>&1; then
    echo "text-embeddings-router not on PATH. Install via Homebrew: brew install text-embeddings-inference" >&2
    exit 1
fi

echo "Serving ${ADAPTER} model: ${MODEL_PATH}"
echo "  served-model-name:        ${SERVED_NAME}"
echo "  port:                     ${PORT}"
echo "  max-batch-tokens:         ${MAX_BATCH_TOKENS}"
echo "  max-client-batch-size:    ${MAX_CLIENT_BATCH}"
echo "  max-concurrent-requests:  ${MAX_CONCURRENT}"
echo "  pooling:                  cls   (SPECTER2 was trained with CLS-token pooling)"
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
