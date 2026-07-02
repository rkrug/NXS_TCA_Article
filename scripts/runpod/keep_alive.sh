#!/usr/bin/env bash
# Reset the idle-watchdog counter on every host configured for the active
# `nli` profile in config.yaml, by sending a trivial /classify request. The
# watchdog (docker/nli-runpod/nli_idle_watchdog.sh) resets its idle timer
# whenever the server's cumulative request count changes — /health and
# /metrics don't count, only /classify does.
#
# Useful for keeping provisioned pods alive between real scoring runs, or
# while testing, without letting IDLE_MIN auto-stop them.
#
# Usage:
#   scripts/runpod/keep_alive.sh                    # ping every active host once
#   scripts/runpod/keep_alive.sh --loop 240          # repeat every 240s until Ctrl-C
#   scripts/runpod/keep_alive.sh -c other_config.yaml
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: keep_alive.sh [-c <config.yaml>] [--loop <seconds>]

  -c <config.yaml>  Path to config (default: input/config.yaml, relative to repo root).
  --loop <seconds>  Repeat indefinitely, sleeping <seconds> between passes. Omit for a single pass.
  -h                Show this help.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/input/config.yaml"
LOOP_SECONDS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) CONFIG_FILE="$2"; shift 2 ;;
    --loop) LOOP_SECONDS="$2"; shift 2 ;;
    -h) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage; exit 1 ;;
  esac
done

for bin in curl Rscript; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: required command '${bin}' not found on PATH" >&2
    exit 1
  fi
done

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "error: config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

# Resolve the active nli profile's base URL(s) exactly as nli_hosts() /
# nli_classify_url() do in R/build_nli_scores_parquet.R — host may be a
# scalar or a YAML list; port: null means scheme://host with no :port.
get_base_urls() {
  CONFIG_FILE="${CONFIG_FILE}" Rscript -e '
    cfg_path <- Sys.getenv("CONFIG_FILE")
    nli <- yaml::read_yaml(cfg_path)[["nli"]]
    active <- nli[["active"]]
    cfg <- nli[["configs"]][[active]]
    if (is.null(cfg)) stop("no config found for nli.active = ", active)

    host <- unlist(cfg[["host"]], use.names = FALSE)
    host <- host[nzchar(host)]
    if (!length(host)) stop("nli.configs.", active, ".host resolved to zero hostnames")

    scheme <- cfg[["scheme"]]
    if (is.null(scheme) || !nzchar(scheme)) scheme <- "https"
    port <- cfg[["port"]]

    for (h in host) {
      if (is.null(port) || (is.character(port) && !nzchar(port))) {
        cat(sprintf("%s://%s\n", scheme, h))
      } else {
        cat(sprintf("%s://%s:%s\n", scheme, h, port))
      }
    }
  '
}

ping_once() {
  local urls
  urls="$(get_base_urls)"

  local n=0
  local ok=0
  while IFS= read -r base_url; do
    [[ -z "${base_url}" ]] && continue
    n=$((n + 1))
    http_code="$(
      curl -sS --max-time 30 -o /dev/null -w '%{http_code}' \
        -X POST "${base_url}/classify" \
        -H "Content-Type: application/json" \
        -d '{
          "sequences": ["keepalive"],
          "candidate_labels": ["supports", "refutes", "is not relevant to"],
          "hypothesis_template": "This paper {} the following claim: keepalive.",
          "batch_size": 1
        }' 2>/dev/null || echo "000"
    )"
    if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
      echo "  [$(date '+%H:%M:%S')] ${base_url} OK" >&2
      ok=$((ok + 1))
    else
      echo "  [$(date '+%H:%M:%S')] ${base_url} FAILED (HTTP ${http_code})" >&2
    fi
  done <<< "${urls}"

  echo "pinged ${ok}/${n} host(s)" >&2
}

if [[ -n "${LOOP_SECONDS}" ]]; then
  echo "Looping every ${LOOP_SECONDS}s. Ctrl-C to stop." >&2
  while true; do
    ping_once
    sleep "${LOOP_SECONDS}"
  done
else
  ping_once
fi
