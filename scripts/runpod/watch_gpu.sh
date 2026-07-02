#!/usr/bin/env bash
# Live per-host NLI throughput dashboard for the active `nli` profile's pool.
#
# The NLI server does not expose a GPU-utilization percentage — it exposes a
# cumulative "sequences classified" counter at /metrics (nli_request_count).
# This script polls that counter on every host and reports the DELTA per
# interval as pairs/sec, which is the directly useful proxy for "is this GPU
# busy": a host doing real work shows a positive rate; an idle/starved host
# shows 0.0. Polling /metrics (a GET) does NOT reset the idle watchdog — only
# /classify does — so this is safe to run alongside scoring and keep_alive.sh.
#
# Usage:
#   scripts/runpod/watch_gpu.sh                 # refresh every 5s until Ctrl-C
#   scripts/runpod/watch_gpu.sh -n 10           # every 10s
#   scripts/runpod/watch_gpu.sh -c other.yaml   # different config
#   scripts/runpod/watch_gpu.sh --once          # single snapshot, no loop
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: watch_gpu.sh [-c <config.yaml>] [-n <seconds>] [--once]
                    [--ready <dir>] [--scores <dir>] [--no-eta] [--eta-every <s>]

  -c <config.yaml>  Path to config (default: input/config.yaml, relative to repo root).
  -n <seconds>      Refresh interval (default: 5).
  --once            Print one snapshot and exit (rates need >=2 passes, so the
                    first pass shows totals only).
  --ready <dir>     nli_ready dataset for the target row count
                    (default: output/nli_ready_evidence).
  --scores <dir>    scored-output dataset for the done row count
                    (default: output/nli_scores_evidence).
  --no-eta          Disable the progress/ETA footer (skip all disk reads).
  --eta-every <s>   Re-count scored rows on disk at most every <s> seconds
                    (default: 60). Between counts, ETA uses the live rate.
  -h                Show this help.

The ETA footer reports scored/target rows and remaining time = (target - scored)
/ current aggregate rate. "target" = rows in --ready with approx_tokens <=
max_length (the ones actually sent to the model); "scored" = rows written to
--scores. Point --ready/--scores at the sentence-approach dirs (output/nli_ready,
output/nli_scores) when watching that run instead.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/input/config.yaml"
INTERVAL=5
ONCE=0
READY_DIR="${REPO_ROOT}/output/nli_ready_evidence"
SCORES_DIR="${REPO_ROOT}/output/nli_scores_evidence"
ETA=1
ETA_EVERY=60
NOCOLOR="${NOCOLOR:-0}"
BAR_PEAK=25   # seqs/sec that fills a per-host throughput bar (~one L4 at peak)

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) CONFIG_FILE="$2"; shift 2 ;;
    -n) INTERVAL="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --ready) READY_DIR="$2"; shift 2 ;;
    --scores) SCORES_DIR="$2"; shift 2 ;;
    --no-eta) ETA=0; shift ;;
    --eta-every) ETA_EVERY="$2"; shift 2 ;;
    --no-color) NOCOLOR=1; shift ;;
    -h) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage; exit 1 ;;
  esac
done

for bin in curl Rscript awk; do
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
# nli_classify_url() do in R (host may be a scalar or a YAML list; port: null
# means scheme://host with no :port). Same logic as keep_alive.sh.
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

# Load host URLs once (bash 3.2-compatible: no mapfile / associative arrays).
URLS=()
while IFS= read -r u; do
  [[ -n "${u}" ]] && URLS+=("${u}")
done <<< "$(get_base_urls)"
N=${#URLS[@]}
if [[ "${N}" -eq 0 ]]; then
  echo "error: no hosts resolved from ${CONFIG_FILE}" >&2
  exit 1
fi

# Target = rows in READY_DIR with approx_tokens <= max_length (the rows that
# actually get sent to the model). Computed once; reads one column, so it's the
# heavier of the two counts — fine at startup.
get_target_total() {
  CONFIG_FILE="${CONFIG_FILE}" READY_DIR="${READY_DIR}" Rscript -e '
    cfg_path <- Sys.getenv("CONFIG_FILE"); root <- Sys.getenv("READY_DIR")
    if (!dir.exists(root)) { cat(0); quit() }
    nli <- yaml::read_yaml(cfg_path)[["nli"]]
    ml <- nli[["configs"]][[nli[["active"]]]][["max_length"]]
    ml <- if (is.null(ml)) 512L else as.integer(ml)
    suppressMessages({library(arrow); library(dplyr)})
    n <- tryCatch(
      open_dataset(root) |> filter(approx_tokens <= ml) |> nrow(),
      error = function(e) 0
    )
    cat(as.integer(n))
  ' 2>/dev/null
}

# Done = rows already written to SCORES_DIR. Reads only Parquet footers, so it
# is cheap enough to re-run on the ETA_EVERY cadence.
count_done_rows() {
  SCORES_DIR="${SCORES_DIR}" Rscript -e '
    root <- Sys.getenv("SCORES_DIR")
    if (!dir.exists(root)) { cat(0); quit() }
    suppressMessages(library(arrow))
    n <- tryCatch(nrow(open_dataset(root)), error = function(e) 0)
    cat(as.integer(n))
  ' 2>/dev/null
}

fmt_hms() { # seconds -> "Hh MMm" / "MMm SSs"
  local s="$1"
  awk -v s="$s" 'BEGIN{
    if (s < 0 || s == "") { print "n/a"; exit }
    h = int(s/3600); m = int((s%3600)/60); sec = int(s%60);
    if (h > 0) printf "%dh %02dm", h, m; else printf "%dm %02ds", m, sec;
  }'
}

TARGET_TOTAL=0
if [[ "${ETA}" -eq 1 ]]; then
  echo "computing target row count from ${READY_DIR} ..." >&2
  TARGET_TOTAL="$(get_target_total || echo 0)"
  [[ -z "${TARGET_TOTAL}" ]] && TARGET_TOTAL=0
fi
DONE_ROWS=0
DONE_T=""   # epoch of last disk count

# Cumulative-average rate baseline: total sequences classified across the pool
# and the epoch at the FIRST full pass. ETA uses (now_sum - BASE_SUM) /
# (now - BASE_T) rather than the last-interval rate, so it converges and stops
# swinging with the per-chunk (256-step) counter quantization.
BASE_SUM=""
BASE_T=""

# Short label = the leading pod id before "-8080.proxy...".
label_of() {
  local url="$1"
  local hostpart="${url#*://}"
  hostpart="${hostpart%%/*}"      # strip path
  hostpart="${hostpart%%.*}"      # strip .proxy.runpod.net
  echo "${hostpart%-*}"           # strip the -8080 port suffix -> bare pod id
}

# ── Colours (disabled if not a TTY, --no-color, or under --once) ─────────────
if [[ "${ONCE}" -eq 0 && -t 1 && "${NOCOLOR}" -eq 0 ]]; then
  C0=$'\033[0m'; CB=$'\033[1m'; CDIM=$'\033[2m'
  CG=$'\033[32m'; CY=$'\033[33m'; CR=$'\033[31m'; CC=$'\033[36m'; CGREY=$'\033[90m'
else
  C0=""; CB=""; CDIM=""; CG=""; CY=""; CR=""; CC=""; CGREY=""
fi
# Cursor control for flicker-free in-place refresh (TTY, looping mode only):
# home the cursor, erase each line to its end (EOL), erase below the block (EOS).
if [[ "${ONCE}" -eq 0 && -t 1 ]]; then
  CUP=$'\033[H'; EOL=$'\033[K'; EOS=$'\033[J'
else
  CUP=""; EOL=""; EOS=""
fi

# Unicode block bar: value/max filled over `width` cells.
make_bar() {
  awk -v v="$1" -v m="$2" -v w="$3" 'BEGIN{
    f = (m > 0) ? int(w * v / m + 0.5) : 0;
    if (f > w) f = w; if (f < 0) f = 0;
    for (i = 0; i < f; i++) printf "\342\226\210";   # full block █
    for (i = f; i < w; i++) printf "\342\226\221";   # light shade ░
  }'
}

# Integer with thousands separators (portable; no locale dependency).
commafy() {
  awk -v n="$1" 'BEGIN{
    s = sprintf("%d", n); neg = (substr(s,1,1) == "-"); if (neg) s = substr(s,2);
    out = ""; c = 0;
    for (i = length(s); i >= 1; i--) { out = substr(s,i,1) out; if (++c % 3 == 0 && i > 1) out = "," out }
    print (neg ? "-" out : out);
  }'
}

# Fetch nli_request_count for a base URL; echoes the integer, or "" on failure.
fetch_count() {
  local base="$1"
  curl -sS --max-time 15 "${base}/metrics" 2>/dev/null \
    | awk '/^nli_request_count/ {print $2; exit}'
}

# Parallel indexed arrays for previous counts; single previous timestamp.
PREV=()
for ((i = 0; i < N; i++)); do PREV[i]=""; done
PREV_T=""

pass() {
  local now total_rate active
  now="$(date +%s)"
  local elapsed=0
  if [[ -n "${PREV_T}" ]]; then elapsed=$((now - PREV_T)); fi

  printf '%s' "${CUP}"
  printf '%s NLI POOL %s%s· %s hosts · %s %s(refresh %ss)%s%s\n' \
    "${CB}${CC}" "${C0}" "${CDIM}" "${N}" "$(date '+%H:%M:%S')" "${CGREY}" "${INTERVAL}" "${C0}" "${EOL}"
  printf '%s%s%s\n' "${CGREY}" "  host              seqs/s   throughput             state" "${C0}${EOL}"

  total_rate=0
  active=0
  local i base cnt prev rate state lbl sum_now=0 bar scol sdisp ratedisp
  for ((i = 0; i < N; i++)); do
    base="${URLS[i]}"
    lbl="$(label_of "${base}")"
    cnt="$(fetch_count "${base}")"
    if [[ -z "${cnt}" ]]; then
      bar="$(make_bar 0 "${BAR_PEAK}" 18)"
      printf '  %s%-16s%s %7s   %s%s%s   %sDOWN%s%s\n' \
        "${CC}" "${lbl}" "${C0}" "-" "${CR}" "${bar}" "${C0}" "${CR}${CB}" "${C0}" "${EOL}"
      PREV[i]=""
      continue
    fi
    sum_now=$((sum_now + cnt))
    prev="${PREV[i]}"
    rate=""
    state="idle"
    if [[ -n "${prev}" && "${elapsed}" -gt 0 ]]; then
      rate="$(awk -v d="$((cnt - prev))" -v e="${elapsed}" 'BEGIN{printf "%.1f", (e>0)?d/e:0}')"
      if awk -v r="${rate}" 'BEGIN{exit !(r>0)}'; then
        state="BUSY"; active=$((active + 1))
      fi
      total_rate="$(awk -v t="${total_rate}" -v r="${rate}" 'BEGIN{printf "%.1f", t+r}')"
      ratedisp="${rate}"
      bar="$(make_bar "${rate}" "${BAR_PEAK}" 18)"
    else
      ratedisp="—"
      bar="$(make_bar 0 "${BAR_PEAK}" 18)"
    fi
    if [[ "${state}" == "BUSY" ]]; then
      scol="${CG}"; sdisp="BUSY"
    else
      scol="${CGREY}"; sdisp="idle"
    fi
    printf '  %s%-16s%s %7s   %s%s%s   %s%-4s%s%s\n' \
      "${CC}" "${lbl}" "${C0}" "${ratedisp}" "${scol}" "${bar}" "${C0}" \
      "${scol}" "${sdisp}" "${C0}" "${EOL}"
    PREV[i]="${cnt}"
  done

  if [[ -n "${PREV_T}" && "${elapsed}" -gt 0 ]]; then
    printf '  %spool%s %s%s%s seqs/s%s · %s%s/%s%s busy%s\n' \
      "${CGREY}" "${C0}" "${CB}" "${total_rate}" "${C0}" "" \
      "${CB}" "${active}" "${N}" "${C0}" "${EOL}"
  else
    printf '  %s(rates appear after the next pass)%s%s\n' "${CDIM}" "${C0}" "${EOL}"
  fi

  # Progress + ETA footer. Re-count done rows on disk at most every ETA_EVERY
  # seconds; between counts, reuse the cached value.
  if [[ "${ETA}" -eq 1 && "${TARGET_TOTAL}" -gt 0 ]]; then
    if [[ -z "${DONE_T}" || $((now - DONE_T)) -ge "${ETA_EVERY}" ]]; then
      DONE_ROWS="$(count_done_rows || echo "${DONE_ROWS}")"
      [[ -z "${DONE_ROWS}" ]] && DONE_ROWS=0
      DONE_T="${now}"
    fi

    # Cumulative-average rate since the watcher's first pass — smooth, unlike
    # the per-interval aggregate above (which swings with 256-step counter
    # quantization). Seed the baseline on the first pass.
    local cum_rate="" cum_elapsed=0
    if [[ -z "${BASE_SUM}" ]]; then
      BASE_SUM="${sum_now}"; BASE_T="${now}"
    else
      cum_elapsed=$((now - BASE_T))
      if [[ "${cum_elapsed}" -gt 0 ]]; then
        cum_rate="$(awk -v d="$((sum_now - BASE_SUM))" -v e="${cum_elapsed}" 'BEGIN{printf "%.1f", d/e}')"
      fi
    fi

    local pct remaining eta rate_note pbar
    pct="$(awk -v d="${DONE_ROWS}" -v t="${TARGET_TOTAL}" 'BEGIN{printf "%.1f", (t>0)?100*d/t:0}')"
    remaining=$((TARGET_TOTAL - DONE_ROWS))
    [[ "${remaining}" -lt 0 ]] && remaining=0
    if [[ -n "${cum_rate}" ]] && awk -v r="${cum_rate}" 'BEGIN{exit !(r>0)}'; then
      eta="$(fmt_hms "$(awk -v rem="${remaining}" -v r="${cum_rate}" 'BEGIN{printf "%d", rem/r}')")"
      rate_note="$(printf 'avg %s seqs/s over %ss' "${cum_rate}" "${cum_elapsed}")"
    else
      eta="warming up"; rate_note="collecting baseline"
    fi
    pbar="$(make_bar "${pct}" 100 30)"
    printf '%s\n' "${EOL}"
    printf '  %sSCORED%s %s%s%s %s%s%%%s%s\n' \
      "${CGREY}" "${C0}" "${CG}" "${pbar}" "${C0}" "${CB}" "${pct}" "${C0}" "${EOL}"
    printf '  %s%s / %s rows · ETA %s%s%s · %s%s\n' \
      "${CDIM}" "$(commafy "${DONE_ROWS}")" "$(commafy "${TARGET_TOTAL}")" \
      "${C0}${CB}" "${eta}" "${C0}${CDIM}" "${rate_note}${C0}" "${EOL}"
  fi
  printf '%s' "${EOS}"
  PREV_T="${now}"
}

if [[ "${ONCE}" -eq 1 ]]; then
  pass
  exit 0
fi

# Full clear once; subsequent passes home the cursor and overwrite in place.
# Hide the cursor while looping; restore it (and show cursor) on exit.
if [[ -t 1 ]]; then
  printf '\033[2J\033[H\033[?25l'
  trap 'printf "\033[?25h\n"; exit 0' INT TERM
fi
while true; do
  pass
  sleep "${INTERVAL}"
done
