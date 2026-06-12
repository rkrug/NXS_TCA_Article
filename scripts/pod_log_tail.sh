#!/usr/bin/env bash
# Tail the BERTopic pod's persistent log (entrypoint + idle-watchdog output).
#
# Reads SSH host/port/user/key from config.yaml's
# bertopic.configs.default_runpod section, so you don't have to retype
# the connection details every time the pod is redeployed.
#
# Note: this log captures entrypoint.sh boot messages and the idle
# watchdog's heartbeat output, NOT the Python script's BERTopic
# progress. For "is the workload making progress?", use
# scripts/pod_watch.sh instead.
#
# Usage:
#   ./scripts/pod_log_tail.sh          # tail current run's log
#   ./scripts/pod_log_tail.sh previous # tail the rotated log from the prior boot
set -euo pipefail

if [[ ! -f config.yaml ]]; then
    echo "Run from the repo root (config.yaml not found here)." >&2
    exit 1
fi

# Pull SSH details out of config.yaml via Rscript — keeps a single
# source of truth and survives ssh_host/port churn between pod
# redeployments.
eval "$(Rscript -e '
cfg <- yaml::read_yaml("config.yaml")$bertopic$configs$default_runpod
cat(sprintf("SSH_HOST=%s\nSSH_PORT=%s\nSSH_USER=%s\nSSH_KEY=%s\n",
            shQuote(cfg$ssh_host), shQuote(cfg$ssh_port),
            shQuote(cfg$ssh_user), shQuote(path.expand(cfg$ssh_key_path))))
')"

WHICH="${1:-current}"
case "${WHICH}" in
    current)  LOG="/work/bertopic-current.log"  ;;
    previous) LOG="/work/bertopic-previous.log" ;;
    *) echo "Unknown log selector '${WHICH}' (expected 'current' or 'previous')." >&2; exit 2 ;;
esac

LOG_DIR="output/pod_logs"
mkdir -p "${LOG_DIR}"
LOCAL_LOG="${LOG_DIR}/pod_log_${WHICH}_$(date +%Y-%m-%d_%H%M%S).log"

echo "→ tailing ${LOG} on ${SSH_USER}@${SSH_HOST}:${SSH_PORT} (Ctrl-C to exit)"
echo "→ logging to ${LOCAL_LOG}"

{
    echo "# pod_log_tail.sh session"
    echo "# started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# pod:     ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
    echo "# remote log: ${LOG}"
    echo "#"

    ssh -i "${SSH_KEY}" -p "${SSH_PORT}" \
        -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=60 \
        "${SSH_USER}@${SSH_HOST}" "tail -f ${LOG}"

    echo "#"
    echo "# ended: $(date '+%Y-%m-%d %H:%M:%S')"
} | tee "${LOCAL_LOG}"
