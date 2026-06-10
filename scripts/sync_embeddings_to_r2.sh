#!/usr/bin/env bash
# Sync local embedding leaves to Cloudflare R2 (Phase 1 storage backend).
#
# rclone sync is idempotent: re-running picks up where a previous attempt
# left off, skips already-uploaded files (size+mtime match), and deletes
# orphaned R2 objects whose local source has disappeared. Safe to run
# repeatedly.
#
# Filters out macOS noise (.DS_Store, ._*, etc.) and pipeline marker
# files (.embed_complete) that don't belong in cloud storage.
#
# Prereq: rclone configured with a remote named `r2`. See
# cloud_storage_migration.md for setup.
#
# Usage:
#   ./scripts/sync_embeddings_to_r2.sh
#   ./scripts/sync_embeddings_to_r2.sh --dry-run     # preview only
set -euo pipefail

LOCAL_ROOT="output/TCAC_2.0/embeddings/config=SPECTER2_runpod"
REMOTE_ROOT="r2:tcac-2-0/embeddings/config=SPECTER2_runpod"

if [[ ! -d "${LOCAL_ROOT}" ]]; then
	echo "Local embedding root not found: ${LOCAL_ROOT}" >&2
	echo "Run from the repo root." >&2
	exit 1
fi

EXTRA_ARGS=("$@")

# rclone --exclude is taken as a glob pattern relative to the source root.
# These cover everything macOS or pipeline-side that shouldn't be in R2.
EXCLUDES=(
	# macOS Finder + Spotlight + Time Machine + APFS metadata
	--exclude '.DS_Store'
	--exclude '.DS_Store/**'
	--exclude '._*' # AppleDouble resource forks
	--exclude '.Spotlight-V100/**'
	--exclude '.Trashes/**'
	--exclude '.fseventsd/**'
	--exclude '.AppleDouble/**'
	--exclude '.LSOverride'
	--exclude '.VolumeIcon.icns'
	--exclude '.com.apple.timemachine.donotpresent'
	--exclude '.AppleDB/**'
	--exclude '.AppleDesktop/**'
	--exclude 'Network Trash Folder/**'
	--exclude 'Temporary Items/**'
	--exclude '.apdisk'
	# Pipeline markers (we re-stamp them locally on re-run, no need in R2)
	--exclude '.embed_complete'
	--exclude '.topics_complete'
	# rclone partial-state from a previous run
	--exclude '*.rclone-partial'
	# duckdb consolidation tmp dir
	--exclude '.parts.tmp/**'
)

exec rclone sync \
	--progress \
	--transfers 4 \
	--checkers 16 \
	--s3-upload-concurrency 4 \
	--s3-chunk-size 64M \
	--retries 10 \
	--low-level-retries 20 \
	--retries-sleep 5s \
	--fast-list \
	"${EXCLUDES[@]}" \
	"${EXTRA_ARGS[@]}" \
	"${LOCAL_ROOT}/" \
	"${REMOTE_ROOT}/"
