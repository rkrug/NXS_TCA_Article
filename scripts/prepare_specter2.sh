#!/usr/bin/env bash
# Prepare merged SPECTER2 models for both adapters (proximity, adhoc_query).
#
# One-time setup per machine. Creates a project-local .venv on first run,
# installs the Python deps into it, then runs the merger once per adapter.
# The result is two separate model directories under the per-user cache:
#   ~/Library/Caches/org.R-project.R/R/openalexVectorComp/specter2_proximity_merged
#   ~/Library/Caches/org.R-project.R/R/openalexVectorComp/specter2_adhoc_merged
#
# Usage:
#   ./scripts/prepare_specter2.sh                  # both adapters (default)
#   ./scripts/prepare_specter2.sh proximity        # only proximity
#   ./scripts/prepare_specter2.sh adhoc_query      # only adhoc_query
#
# The .venv lives at <repo-root>/.venv and is only needed at merge time.
# Delete it after the merge is complete if you want the disk space back.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_DIR="${REPO_ROOT}/.venv"
REQUIREMENTS=(transformers adapters torch)

if [ ! -d "${VENV_DIR}" ]; then
    echo "==> Creating venv at ${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
fi

# shellcheck source=/dev/null
source "${VENV_DIR}/bin/activate"

# Install Python deps if missing (idempotent — pip is a no-op if up to date)
if ! python -c "import transformers, adapters, torch" 2>/dev/null; then
    echo "==> Installing Python deps into venv: ${REQUIREMENTS[*]}"
    pip install --quiet --upgrade pip
    pip install --quiet "${REQUIREMENTS[@]}"
fi

if [ "$#" -eq 0 ]; then
    adapters=(proximity adhoc_query)
else
    adapters=("$@")
fi

for a in "${adapters[@]}"; do
    echo "==> Preparing SPECTER2 ${a}"
    python "${SCRIPT_DIR}/prepare_specter2_merged.py" --adapter "${a}"
done

echo "==> Done. Start TEI with: ./scripts/start_tei_specter2.sh [proximity|adhoc_query]"
echo "    (You can 'rm -rf ${VENV_DIR}' to reclaim disk space; only needed for re-merges.)"
