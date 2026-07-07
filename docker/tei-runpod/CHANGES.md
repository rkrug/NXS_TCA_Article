# tei-runpod — CHANGES

Image versions published as
`ghcr.io/rkrug/tei-specter2:<adapter>-vX.Y.Z`, one per SPECTER2 adapter
(`proximity` for document embedding, `adhoc_query` for query-time).

Semantic versioning, loosely:
- **MAJOR** — incompatible TEI base, model format change, or breaking
  pod-template contract.
- **MINOR** — new feature in the image (new tunable, new bundled tool,
  new watchdog signal).
- **PATCH** — bug fixes, dependency bumps, small entrypoint tweaks.

## v0.1.3 — 2026-07-07

Tag bump only — resolve a collision on the `proximity-v0.1.2` tag. The sibling
repo published a `runpodctl config`-based watchdog under that same tag on
2026-07-03; this repo's v0.1.2 source instead uses the REST-API watchdog (see
below) but was never pushed. v0.1.3 claims a distinct tag so the source here
and the registry image agree. No functional change vs this repo's v0.1.2
source: still the REST-API idle watchdog, which needs only RUNPOD_API_KEY (from
the `{{ RUNPOD_SECRET_runpod_api_key }}` pod-template env, resolved by RunPod at
pod launch).

## v0.1.2 — 2026-07-06

- **tei_idle_watchdog.sh**: self-stop now calls the RunPod REST API
  (`POST https://rest.runpod.io/v1/pods/<id>/stop` with
  `Authorization: Bearer $RUNPOD_API_KEY`) instead of `runpodctl stop pod`.
  The `runpodctl` path required a `runpodctl config` file the pod doesn't
  have and failed with "Runpod config file not found" / HTTP 400, so idle
  pods never actually stopped. The REST call needs only `RUNPOD_API_KEY`
  (already in the pod-template env) and matches
  `scripts/runpod/stop_pods.sh`. Watchdog-only patch.

## v0.1.1 — 2026-06-08

- **Dockerfile**: fix the `org.opencontainers.image.source` label —
  was a `<you>` placeholder, now points at
  https://github.com/rkrug/TCAC-2.0. Makes GHCR auto-link the
  package to the repo. Trivial layer.
- **entrypoint.sh**: persistent logs to `${LOG_DIR:=/workspace}` —
  `tei-current.log` rotated to `tei-previous.log` on every boot. Lets
  you read TEI's last words after a crash via the volume (RunPod's web
  Logs panel resets on restart, but the file doesn't). New env var
  `LOG_DIR` overridable from the pod template.

## v0.1.0 — 2026-06-08

Initial published release; covers the work that produced TCAC 2.0
embeddings.

- Multi-stage Dockerfile:
  - Stage 1 (`python:3.11-slim`): merges the SPECTER2 adapter into the
    base encoder via `scripts/prepare_specter2_merged.py`. Pins
    `huggingface_hub<0.20` so adapters 0.2.x can import
    `url_to_filename`.
  - Stage 2 (`ghcr.io/huggingface/text-embeddings-inference:<TEI_TAG>`):
    copies the merged model in at `/model`. CUDA tag selected via
    `--build-arg TEI_TAG=…` (e.g. `89-1.5` for Ada/Hopper L40S).
- Idle watchdog (`tei_idle_watchdog.sh`) auto-stops the pod after
  `IDLE_MIN` minutes of no new TEI requests; defaults to 5 min, override
  per pod via env var.
- `runpodctl` v1.14.4 baked in for the watchdog's self-stop call.
- Entrypoint binds TEI on `0.0.0.0:8080` (HTTP) with sensible defaults
  (`max-batch-tokens 131072`, `max-concurrent-requests 2048`,
  `max-client-batch-size 512`, `pooling cls`, `--auto-truncate`); all
  overridable via env vars.
- TEI 1.5 dropped `--served-model-name`; we don't pass it anymore.
