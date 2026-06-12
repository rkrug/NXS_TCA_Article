# TODO — Full Cloud Migration of the Pipeline

Future-work design for moving the *entire* TCAC 2.0 pipeline to the
cloud — compute, orchestration, storage, sharing. Not implemented.

> **Current decision (2026-06-11)**: full migration is **not on the
> roadmap**. The TCAC 2.0 corpus is fixed; only the keypaper set
> changes between assessments. For that workflow,
> [TODO_BERTopicStageCaching.md](TODO_BERTopicStageCaching.md) alone
> gives the savings we care about (keypaper swap: ~5 min / ~$0.05
> instead of ~3 h / ~$2). The contents of this doc remain valid as
> the "if the situation changes" plan — e.g., if multi-author
> collaboration or reviewer-side reproducibility becomes a goal —
> but Phase 3 work is deferred until such a trigger appears.

This is the synthesis of several pieces that are already partly or
fully designed elsewhere:

- [cloud_storage_migration.md](cloud_storage_migration.md) — Phase 1
  (embeddings → R2, done) and Phase 2 (full targets cloud-mode, future).
- [TODO_BERTopicStageCaching.md](TODO_BERTopicStageCaching.md) —
  cacheable BERTopic stages on R2.
- [TODO_ShinyMigration.md](TODO_ShinyMigration.md) — Shiny app
  deployment for sharing.
- [TD_RunPodSetup.md](TD_RunPodSetup.md) — current pod templates.

This doc is about what's *beyond* Phase 2: making the laptop optional.

## Current state vs full-cloud end state

| Layer | Today | Full-cloud target |
|---|---|---|
| Orchestrator (R session running `tar_make`) | Laptop | Cloud (cheap CPU VM or scheduled job) |
| OpenAlex snapshot extraction | Laptop reads `input/snapshot/` (28 GB) | Cloud reads snapshot from R2 / object storage |
| TEI embedding inference | Laptop or RunPod pod | RunPod pod |
| BERTopic compute | Laptop (Path A) or RunPod (Path B) | RunPod pod (Path B with stage caching) |
| Scoring / viz data targets | Laptop | Cloud CPU VM |
| Report render (Quarto) | Laptop | Cloud CPU VM, output to web bucket |
| `_targets/` state | `_targets/` on laptop disk (or external SSD) | R2 via cloud-mode targets |
| Embeddings (~50 GB) | Local + R2 (Phase 1) | R2 only |
| Corpus snapshot extract (~28 GB) | Local | R2 |
| Report HTML | Local | Public R2 bucket / CDN |
| Manual trigger | `tar_make()` at the terminal | Web UI / cron / API |

The laptop becomes "the editor and reviewer", not "the executor".

## Why bother — beyond Phase 2

Phase 2 (`tar_option_set(repository = "aws")`) makes the targets *state*
live in the cloud, but the orchestrator R process still runs on the
laptop. So:

- Long-running `tar_make` blocks the laptop.
- Laptop sleep / network drop kills mid-run targets.
- Collaborators can read targets state but can't *trigger* runs without
  having the repo cloned + R/targets/all deps set up.
- Paper reviewer can't reproduce except by setting up everything.

Phase 3 removes those frictions. The pipeline becomes service-shaped.

## Compute model — what runs where

### Orchestrator host

Light load (most of the time it's idle, dispatching pods). Options:

| Option | $/month | Pros | Cons |
|---|---|---|---|
| Always-on VM (Hetzner CX22) | ~€5 | Simple; can run cron + Shiny on same box | Idle compute most of the day |
| Cloud Function on demand | ~$0.10/run | Pay only for `tar_make` invocations | Cold start + R/renv setup overhead |
| GitHub Actions runner | $0 (within free tier for ~50 runs/mo) | Triggered by git push; integrated with PR workflow | 6-hour job time limit on free; 14 GB RAM ceiling |
| RunPod CPU pod (on-demand) | $0.04/h | Same provider as GPU pods; reuses Secrets | Manual start/stop unless wrapped |

**Recommendation**: Hetzner CX22 always-on. €5/month buys predictable
performance + a place to host the report + a place for Shiny (when
[TODO_ShinyMigration.md](TODO_ShinyMigration.md) lands). Same box can
run cron-driven re-renders when keypaper sets change.

### Heavy compute pods (TEI + BERTopic)

Unchanged from today. Triggered by orchestrator via SSH, results land
in R2.

### Snapshot extraction

The OpenAlex snapshot (`input/snapshot/`) is ~28 GB. Today it lives on
the laptop's external SSD and is queried via `openalexPro::lookup_by_id()`
for the corpus extract step.

In a cloud setup, options:

| Option | Storage cost | Query model |
|---|---|---|
| Snapshot in R2 as parquet | $0.42/mo (28 GB) | duckdb httpfs reads it directly |
| Snapshot in a managed Postgres / BigQuery | ~$5-50/mo | SQL queries |
| Skip — query OpenAlex API live | $0 | Slower, hits rate limits at corpus scale |

**Recommendation**: snapshot as parquet on R2. ~$0.42/mo storage,
duckdb-native reads, zero query infra. The
`get_corpus_from_snapshot()` function becomes a duckdb query against
R2 parquets instead of a local arrow scan.

## Storage budget — full migration

Cumulative across all migration phases:

| Bucket prefix | Size | $/month at R2 |
|---|---|---|
| `embeddings/` (Phase 1) | ~50 GB | $0.75 |
| `corpus/` (TCAC 2.0 + TCAC 1.0 snapshot extracts) | ~30 GB | $0.45 |
| `intermediate/` (BERTopic stage caches, after [TODO_BERTopicStageCaching.md](TODO_BERTopicStageCaching.md)) | ~3-20 GB | $0.05-$0.30 |
| `_targets/` (meta + objects, after Phase 2) | ~5 GB | $0.08 |
| `snapshot/` (OpenAlex snapshot as parquet) | ~28 GB | $0.42 |
| `scores/`, `topics/`, `viz_*/`, `fig_*/` | ~10 GB | $0.15 |
| `reports/` (rendered HTML + assets) | ~50 MB | $0.001 |
| **Total** | **~125-145 GB** | **~$2-2.20/month** |

Even doubling for safety margin: ~$5/month, which is roughly the
Hetzner CX22 cost. Total **~$10/month** for everything-in-cloud,
zero-egress, paper-quality reproducibility.

Compare to current local state: $0/month direct cost, but tied to
laptop availability + manual `tar_make` runs.

## Compute costs once-migrated

Per-iteration costs aren't fundamentally different from today —
embedding + BERTopic runs cost the same per dispatch. The difference:

| Workflow | Local-today | Full-cloud |
|---|---|---|
| Re-embed corpus (full) | ~22 h × laptop TEI = $0 + laptop unavailable | ~22 h × $0.79 RunPod L40S = $17 (one-off; cached) |
| Re-run BERTopic (full corpus, Path B) | ~2 h × $0.79 = $1.58 | ~2 h × $0.79 = $1.58 (unchanged) |
| Re-run BERTopic with cached UMAP (stage caching) | n/a today | ~30 min × $0.79 = $0.40 |
| Keypaper swap (no UMAP/HDBSCAN re-fit) | ~5 min × $0.79 + laptop scoring = $0.05 + 0 | ~5 min × $0.79 = $0.05 |
| Report re-render | ~30 s on laptop = $0 | ~30 s × $0.04 CPU = $0 (rounding) |

Monthly compute for "1 full BERTopic run + 5 re-tunes + 3 keypaper
swaps + nightly report re-render":

| Item | Cost |
|---|---|
| 1 full BERTopic run | $1.58 |
| 5 cached re-tunes | 5 × $0.40 = $2.00 |
| 3 keypaper swaps | 3 × $0.05 = $0.15 |
| 30 × nightly re-render | 30 × $0.001 = $0.03 |
| **Compute monthly** | **~$3.76** |

Plus storage (~$2.20) + orchestrator VM (~$5) = **~$11/month
all-in** for active research. Drops to ~$7/month idle (storage +
VM).

## Implications

### Reproducibility

Pin everything to immutable digests:

- Docker images pinned by SHA-256, not tag.
- R packages pinned by `renv.lock`.
- Python packages pinned by lock file in image.
- OpenAlex snapshot release ID recorded in cfg.
- BERTopic + cuml versions documented in [TD_BERTopic_Parameters.md](TD_BERTopic_Parameters.md).
- R2 bucket versioning enabled for `embeddings/` and `snapshot/`.

Paper supplement cites the bucket URL + image digests. Any reviewer
can `tar_make()` from a fresh clone and reproduce.

### Sharing model

After Phase 2 + Phase 3:

- Public R2 bucket (`tcac-2-0-public`) mirrors selected results
  (final topics, scores, report HTML).
- Read-only R2 token for reviewers who want raw `_targets/` access.
- Shiny app (after [TODO_ShinyMigration.md](TODO_ShinyMigration.md))
  hosted on the orchestrator VM gives interactive access.

### Security

- All write tokens (R2 R/W, RunPod API key) live in the orchestrator
  VM's environment, not in git.
- Read-only token shipped publicly for the paper has bucket scope
  only, no admin scope.
- Snapshot data isn't sensitive (it's public OpenAlex). Embeddings
  aren't sensitive (derivable from public abstracts). No GDPR
  concerns for the data itself.

### Vendor lock-in

Architecture stays provider-agnostic because everything uses standard
APIs (S3, SSH, Docker). Components:

- **R2** can be swapped for any S3-compatible store. Backblaze B2,
  Wasabi, even AWS S3 — change endpoint + creds, done.
- **RunPod** can be swapped for any GPU IaaS that takes a Docker
  image + SSH. Vast.ai, Lambda Labs, even self-hosted.
- **Hetzner** can be swapped for any cloud VM provider. AWS EC2, GCP
  Compute Engine, Linode.

Migration cost across providers: ~half a day, mostly cutover
testing. Avoids being captive to Cloudflare's commercial situation
or RunPod's pricing changes.

### Operations

- Orchestrator VM needs basic monitoring (uptime, disk usage). UptimeRobot
  free tier covers it.
- R2 lifecycle rules clean up `intermediate/` after 30 days; manual
  cleanup of orphan multipart uploads via `rclone backend cleanup` quarterly.
- Pod images bumped via CI (GitHub Actions) when `docker/*/Dockerfile`
  changes, with image digest captured back to the repo.

### What this does NOT solve

- **Laptop still needed for development**. The cloud setup runs
  reliably but doesn't help you write the next viz function.
- **Manual paper drafting**. The pipeline produces tables and figures;
  the actual paper writing is unchanged.
- **Snapshot updates**. OpenAlex releases a new snapshot monthly. The
  pipeline pin is to a specific release; updating means re-running the
  ID extraction + corpus subset. Cloud or local, same cost.

## Phased rollout

1. **Phase 1** (done): embeddings on R2; BERTopic pod reads from R2.
2. **Phase 2** (cloud_storage_migration.md): `_targets/` state on R2.
3. **Phase 2.5** ([TODO_BERTopicStageCaching.md](TODO_BERTopicStageCaching.md)):
   intermediate state on R2; UMAP/HDBSCAN re-use.
4. **Phase 3a** (this doc): snapshot mirror to R2; corpus extraction
   uses duckdb httpfs against the snapshot in R2.
5. **Phase 3b**: orchestrator on Hetzner CX22; cron-triggered runs;
   laptop becomes editor-only.
6. **Phase 3c** ([TODO_ShinyMigration.md](TODO_ShinyMigration.md)):
   Shiny app on the orchestrator VM; reviewers interact via URL.

Each phase is independently shippable; nothing forces a big-bang
migration.

## When to do this

This is paper-finalisation work, not active-research work. Triggers:

- Paper has been submitted; reviewer feedback loops mean re-running.
  the pipeline. Cloud setup makes this trivial.
- The corpus is being expanded with new keypaper sets and you want
  collaborators to re-trigger runs themselves.
- The local setup has become fragile (external SSD, symlinked
  `output/`, laptop sleep killing runs).

If the laptop setup is working and the paper is in active drafting:
**don't migrate**. The local pipeline is faster to iterate against
while you're still tuning parameters. Move to cloud once the
parameter choices are stable.

## Open questions for if/when this becomes real

1. **VM region**: Hetzner has EU + US options. EU-NBG matches the R2
   EU edge → minimal cross-region latency.
2. **CI/CD**: GitHub Actions or self-hosted runner on the VM? Latter
   avoids the 14 GB / 6 h GHA limits for the rare full embed re-run.
3. **Secrets management**: env file on the VM, encrypted at rest? Or
   pull from a secrets manager (Hetzner doesn't have a native one;
   external option = HashiCorp Cloud free tier).
4. **Monitoring depth**: just uptime, or proper logs + metrics? At
   scale of "1 user 1 paper", uptime is probably enough.
5. **Backup of `_targets/`**: R2 has 11 9s durability on its own. Add
   weekly snapshot to a different region? Probably overkill.
