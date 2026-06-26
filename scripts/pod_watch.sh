#!/usr/bin/env bash
# Watch the BERTopic pod's process + GPU state every N seconds.
#
# Reads SSH host/port/user/key from input/config.yaml's
# bertopic.configs.default_runpod section, so you don't have to retype
# the connection details every time the pod is redeployed.
#
# What the loop reports:
#   - elapsed CPU time and resource usage of the python script process
#   - current GPU utilization and memory usage
#
# Phase interpretation:
#   R2 read     : CPU 60-80%, GPU mem 1 MiB
#   UMAP fit    : GPU 60-100%, GPU mem climbing to 20-30 GB
#   HDBSCAN     : GPU 50-100%, peak GPU mem
#   c-TF-IDF    : CPU climbs, GPU drops
#   Writes      : brief disk activity, then process gone
#
# Usage:
#   ./scripts/pod_watch.sh           # poll every 5 seconds (default)
#   ./scripts/pod_watch.sh 10        # poll every 10 seconds
#
# Output is shown on stdout AND tee'd to a timestamped local log file
# under output/pod_logs/. Logs survive even if the pod is evicted or
# SSH disconnects — useful for postmortem when the persistent pod-side
# log is lost with the volume.
set -euo pipefail

if [[ ! -f input/config.yaml ]]; then
    echo "Run from the repo root (input/config.yaml not found here)." >&2
    exit 1
fi

eval "$(Rscript -e '
cfg <- yaml::read_yaml("input/config.yaml")$bertopic$configs$default_runpod
cat(sprintf("SSH_HOST=%s\nSSH_PORT=%s\nSSH_USER=%s\nSSH_KEY=%s\n",
            shQuote(cfg$ssh_host), shQuote(cfg$ssh_port),
            shQuote(cfg$ssh_user), shQuote(path.expand(cfg$ssh_key_path))))
')"

INTERVAL="${1:-5}"

# Set up local logging. output/ is gitignored; pod_logs/ collects one
# file per watch session so multiple runs don't trample each other.
LOG_DIR="output/pod_logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/pod_watch_$(date +%Y-%m-%d_%H%M%S).log"

echo "→ watching ${SSH_USER}@${SSH_HOST}:${SSH_PORT} every ${INTERVAL}s (Ctrl-C to exit)"
echo "→ logging to ${LOG_FILE}"

# tee captures stdout to the log while still showing in the terminal.
# The leading metadata block records pod identity + start time so a
# later postmortem can correlate to the right pod.
{
    echo "# pod_watch.sh session"
    echo "# started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# pod:     ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
    echo "# interval: ${INTERVAL}s"
    echo "#"

    ssh -i "${SSH_KEY}" -p "${SSH_PORT}" \
        -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=60 \
        "${SSH_USER}@${SSH_HOST}" \
        "
        # Read the pod's cgroup memory limit once. RunPod uses cgroups v2
        # (memory.max under /sys/fs/cgroup/). ps's pmem reads the host's
        # total (~1 TB on shared hosts) so it underreports the pod-level
        # pressure. We use the cgroup limit to compute pod_mem% which
        # matches the RunPod dashboard.
        #
        # cgroup files report BYTES. ps reports rss in KB. We normalise
        # to KB everywhere for the awk arithmetic.
        POD_RAM_BYTES=
        if [ -f /sys/fs/cgroup/memory.max ]; then
            POD_RAM_BYTES=\$(cat /sys/fs/cgroup/memory.max)
        elif [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
            POD_RAM_BYTES=\$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
        fi
        if [ \"\$POD_RAM_BYTES\" = max ] || [ -z \"\$POD_RAM_BYTES\" ]; then
            # cgroup says unlimited; fall back to /proc/meminfo MemTotal
            # (already in KB).
            POD_RAM_KB=\$(awk '/MemTotal/{print \$2}' /proc/meminfo)
        else
            POD_RAM_KB=\$((POD_RAM_BYTES / 1024))
        fi
        echo \"# pod RAM limit: \$((POD_RAM_KB / 1024 / 1024)) GB\"
        echo

        while sleep ${INTERVAL}; do
            echo '--- '\$(date +%T)' ---'
            # Match the python process specifically. Plain pgrep -f also
            # matches:
            #   * the wrapper's bash shell that exec'd python
            #   * the entrypoint's heartbeat-keeper bash loop (v0.1.7+),
            #     whose argv literally contains '/opt/run_bertopic_gpu.py'
            # Both look like 0%/0 GB processes and mask the real numbers.
            # Filter ps -eo so command starts with 'python' and contains
            # the script path.
            pid=\$(ps -eo pid,comm,args --no-headers | \
                   awk '\$2 ~ /^python/ && /\\/opt\\/run_bertopic_gpu\\.py/ {print \$1; exit}')
            if [ -n \"\$pid\" ]; then
                # ps prints vsz / rss in KB. awk converts to GB and also
                # computes pod_mem% = rss_bytes / cgroup_limit_bytes.
                ps -o etime,pcpu,vsz,rss --pid \$pid --no-headers | \
                    awk -v pod_ram=\$POD_RAM_KB '{
                        pod_pct = (\$4 * 100.0) / pod_ram
                        printf \"  etime=%-8s cpu=%5.1f%%  pod_mem=%5.1f%%  vsz=%6.1fGB  rss=%6.1fGB\\n\", \
                               \$1, \$2, pod_pct, \$3/1024/1024, \$4/1024/1024
                    }'
            else
                echo 'no python /opt/run_bertopic_gpu.py process running'
            fi
            nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader
        done"

    echo "#"
    echo "# ended: $(date '+%Y-%m-%d %H:%M:%S')"
} | tee "${LOG_FILE}"
