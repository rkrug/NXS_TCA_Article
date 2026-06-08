#!/usr/bin/env bash
# Self-stop the RunPod pod when TEI has been idle for IDLE_MIN minutes.
#
# Watches TEI's Prometheus metrics endpoint for the cumulative request
# counter. If it stops moving for IDLE_MIN consecutive minutes, calls
# `runpodctl stop pod $RUNPOD_POD_ID` to pause billing. The pod can be
# restarted from the RunPod UI (or via API) — the network volume + image
# cache survive.
#
# Required env (set by the pod template):
#   RUNPOD_POD_ID    Automatically set by RunPod.
#   RUNPOD_API_KEY   Add via the pod template "Environment Variables" UI.
#
# Optional env:
#   IDLE_MIN         Idle minutes before stop (default: 15).
#   POLL_SEC         Polling cadence in seconds (default: 60).
#   METRICS_URL      TEI prometheus endpoint (default: http://localhost:8080/metrics).
set -euo pipefail

IDLE_MIN="${IDLE_MIN:-5}"
POLL_SEC="${POLL_SEC:-30}"
METRICS_URL="${METRICS_URL:-http://localhost:8080/metrics}"

if [ -z "${RUNPOD_POD_ID:-}" ]; then
	echo "[idle-watchdog] RUNPOD_POD_ID not set — not on a RunPod pod, exiting" >&2
	exit 0
fi
if [ -z "${RUNPOD_API_KEY:-}" ]; then
	echo "[idle-watchdog] RUNPOD_API_KEY not set — runpodctl stop will fail. Add it to the pod template env." >&2
fi

last_count=-1
idle_seconds=0
echo "[idle-watchdog] watching ${METRICS_URL}; will stop pod ${RUNPOD_POD_ID} after ${IDLE_MIN} idle minutes"

while true; do
	# Sum all te_request_count_* counter samples reported by TEI. Robust to
	# version differences (counters were renamed across TEI releases).
	count=$(curl -fsS "${METRICS_URL}" 2>/dev/null |
		awk '/^te_request_count/ && !/_bucket|_sum/ {sum += $NF} END {print sum+0}' ||
		echo "-1")

	if [ "${count}" = "-1" ]; then
		echo "[idle-watchdog] metrics unreachable — TEI may still be warming up"
	elif [ "${count}" = "${last_count}" ]; then
		idle_seconds=$((idle_seconds + POLL_SEC))
		echo "[idle-watchdog] no new requests; idle for $((idle_seconds / 60)) min (count=${count})"
	else
		if [ "${idle_seconds}" -gt 0 ]; then
			echo "[idle-watchdog] activity resumed (${last_count} → ${count})"
		fi
		idle_seconds=0
		last_count="${count}"
	fi

	if [ "${idle_seconds}" -ge "$((IDLE_MIN * 60))" ]; then
		echo "[idle-watchdog] idle threshold reached, stopping pod ${RUNPOD_POD_ID}"
		runpodctl stop pod "${RUNPOD_POD_ID}"
		exit 0
	fi

	sleep "${POLL_SEC}"
done
