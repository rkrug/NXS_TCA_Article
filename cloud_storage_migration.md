# Cloud-Storage Migration Plan — TCAC 2.0 → Cloudflare R2

Planning doc. Nothing implemented; this captures the architecture, the
two-phase rollout, the rationale behind each decision, and the
verification steps. Companion to `TD_RunPodSetup.md`, `TD_BERTopic.md`,
and `TD_Vectorisation.md`.

---

## Context

The current pipeline holds every artefact locally:

- `output/TCAC_2.0/embeddings/`  ≈ **50 GB** (3 corpus variants × 4.6 M
  rows × 768 floats + 3 keypaper variants)
- `output/TCAC_2.0/topics/`       ≈ **few hundred MB** per BERTopic run
- `output/TCAC_2.0/corpus/`       ≈ **28 GB** (the snapshot extract)
- `_targets/objects/`             ≈ few GB (qs2-serialised viz objects,
  scoring matrices, etc.)
- `_targets/meta/`                ≈ few MB (DAG manifest)

Three concrete pains this causes today:

1. **Every Path B BERTopic run rsyncs 32 GB to the RunPod pod** — ~50 min
   of the 2 h wall-time is laptop ↔ pod uplink. Iterating on
   `hdbscan_min_cluster_size` means paying that upload tax every time.
2. **No shareable artefacts**. Anyone replicating the analysis needs
   either physical access to the laptop or a 50 GB transfer. Reviewers
   of the paper can't reproduce without on-request data.
3. **Single point of failure**. If the laptop's disk dies before the
   paper ships, the entire embedding step (~$15 + ~22 h of compute) has
   to be redone.

A cloud-stored architecture solves all three:

```
laptop                Cloudflare R2 bucket          RunPod pod
──────                ────────────────────          ──────────
 tar_make()
   ▼ dispatches BERTopic / scoring / viz jobs
   ▼ reads & writes targets metadata + outputs    ◄──►  pod-side worker
                                                          reads embeddings
                                                          writes topic results
   ◄────── pulls only what it needs locally for inspection / viz
```

R2 acts as the **single source of truth**. The laptop is one client; the
pod is another. Collaborators are a third.

---

## Why R2 specifically

Evaluated four options against this workload's access pattern (frequent
reads from cloud workers, occasional writes, near-zero egress to the
laptop or to public viewers):

| Provider | Storage | Egress | 32 GB / read | 32 GB / month idle | Verdict |
|---|---|---|---|---|---|
| **Cloudflare R2** | $0.015/GB/mo | **$0** | $0 | $0.48 | ✅ Winner |
| AWS S3 (Standard) | $0.023/GB/mo | $0.09/GB | ~$3 | $0.74 | Egress kills it |
| Backblaze B2 | $0.006/GB/mo | $0.01/GB | $0.32 | $0.19 | Cheapest at rest but every read costs |
| Google Cloud Storage (Standard) | $0.020/GB/mo | $0.12/GB | ~$4 | $0.64 | Worst egress |

Why R2 dominates for us:

- **Zero egress.** The Path B pod reads ~32 GB embeddings every run. With
  R2 that's $0; with S3 it'd be ~$3 per run — small but mounts up over
  iteration cycles.
- **S3-compatible API.** All existing libraries (`aws-cli`, `boto3`,
  `rclone`, `duckdb`'s `httpfs`, R's `paws`) work unmodified. R2 is a
  drop-in for code that targets S3.
- **Public buckets exist as an option.** When the paper ships, a single
  config flip makes the bucket publicly readable — reviewers can fetch
  artefacts without credentials.
- **10 GB free egress per month** + low storage rate means steady-state
  cost is cents while the analysis is active.

The only realistic downside: R2 doesn't have AWS's storage classes
(Glacier etc.), so we can't tier old data aggressively. Not relevant for
~50 GB.

---

## Target architecture

### Bucket layout

One bucket, hive-partitioned mirroring local layout so existing R/Python
code reads with minimal changes:

```
s3://tcac-2-0/
├── corpus/                                # snapshot extract (~28 GB)
├── embeddings/
│   └── config=SPECTER2_runpod/
│       ├── source=corpus/   variant={title,abstract,title_abstract}/
│       └── source=keypaper/ variant={title,abstract,title_abstract}/
├── scores/      (after Phase 2)
├── topics/      (after Phase 2)
└── _targets/    (after Phase 2)
    ├── meta/                              # DAG manifest
    └── objects/                           # qs2-serialised viz / scoring data
```

### Where each piece lives, per phase

| Artefact | Today | After Phase 1 | After Phase 2 |
|---|---|---|---|
| Snapshot corpus extract | Local | Local | R2 (optional — large upload, defer until paper-time) |
| Embeddings (50 GB) | Local | **R2 + local backup** | R2 only |
| Scores (9 GB) | Local | Local | R2 |
| BERTopic topic parquets | Local | Local | R2 |
| viz_* qs2 objects | `_targets/objects/` | `_targets/objects/` | R2 |
| `_targets/meta/` | Local | Local | R2 |
| Reports / figures (HTML, PNG) | Local | Local | Local (built fresh each render) |

Phase 1 puts **only embeddings** in R2 — and even there, keeps a local
copy as a safety net. Targets has no idea R2 exists. Phase 2 hands
everything over to targets' cloud-mode and removes the local copy
duplicates.

---

## Phase 1 — embeddings in R2 (the iteration-speed win)

**What it touches**: just embeddings + the BERTopic pod's reading
behaviour. Targets remains completely unaware. The whole rest of the
pipeline runs unchanged.

**Goal**: eliminate the 50-min Path B upload tax.

### Work

1. Sign up for Cloudflare R2; create bucket `tcac-2-0`.
2. Generate an API token with read/write scope; store in the macOS
   keyring as `R2_ACCESS_KEY` and `R2_SECRET_KEY`.
3. `rclone copy` the existing
   `output/TCAC_2.0/embeddings/config=SPECTER2_runpod/` to
   `r2:tcac-2-0/embeddings/config=SPECTER2_runpod/`. One-time, ~50 min
   over your normal uplink. **Local copy stays put** — safety net.
4. Update `scripts/runpod/run_bertopic_gpu.py` to read embeddings via duckdb's
   `httpfs` extension instead of from a local path:

   ```python
   con.execute(f"""
     INSTALL httpfs; LOAD httpfs;
     SET s3_region='auto';
     SET s3_endpoint='<account>.r2.cloudflarestorage.com';
     SET s3_access_key_id='${R2_ACCESS_KEY}';
     SET s3_secret_access_key='${R2_SECRET_KEY}';

     SELECT * FROM read_parquet('s3://tcac-2-0/embeddings/.../variant=title_abstract/*.parquet')
   """)
   ```
5. `R/run_bertopic_runpod.R`: drop the rsync upload step entirely. The
   wrapper now passes only a small per-run cfg yaml + the run name to
   the pod via ssh; the pod reads embeddings from R2.
6. Bump the bertopic-runpod image to `:v0.2.0`. Adds R2 credentials as
   pod-template env vars (Secrets) — `R2_ACCESS_KEY`, `R2_SECRET_KEY`,
   `R2_ENDPOINT`, `R2_BUCKET`. Pod's `/opt/run_bertopic_gpu.py` reads
   them at runtime.

### What targets sees

Nothing changes. `emb_*` targets continue to point at local file paths.
The `topics_tcac20_runpod` target's function source code changes (the
wrapper is different), so:

- `topics_tcac20_runpod` re-evaluates on next `tar_make`.
- The cfg-hash skip-guard in `run_bertopic_runpod()` fires if the cfg
  hasn't changed → returns the existing leaf path. **No pod run.**
- Downstream viz targets re-evaluate but their input paths are
  unchanged → output qs2 objects identical → skip-guards fire all the
  way through.

Net wall-time of "tar_make after Phase 1 lands": **a few minutes**,
mostly re-hashing. No real recompute.

### Effort

~half day. ~80 lines of script changes. No R-side targets refactor.
No `_targets/` reshape.

### Wins

- Path B run time: 2 h → ~1 h (no upload phase, faster compute start).
- Iteration cost: $2/run → ~$1/run.
- Pod template's volume disk shrinks from 60 GB → 20 GB.
- Embeddings backed up in cloud — laptop disk failure becomes
  non-catastrophic.

### What you can stop with after Phase 1

If your only goal is faster Path B iteration, you can stop here. The
sharing/reproducibility benefits of Phase 2 don't come for free; they
need additional work.

---

## Phase 2 — full targets cloud-mode (sharing + reproducibility)

**What it touches**: `_targets/meta/`, `_targets/objects/`, and the
`format = "file"` outputs of scoring + topic targets. Phase 1's
embedding cloud copy now becomes the *primary* (local copy goes away).

**Goal**: make the entire DAG state shareable. A collaborator with R2
read credentials can clone the repo and `tar_make()` to reproduce
every analysis without re-computing anything.

### Work

1. **Use targets' migration helpers, NOT `tar_destroy()`.** The official
   pattern is to upload existing local objects to the cloud backend
   before flipping the storage option, so `tar_outdated()` sees nothing
   outdated post-migration.

   ```r
   # NOT this:
   targets::tar_destroy()
   targets::tar_make()  # would re-embed, re-score, re-everything

   # Use the cloud-migration helpers instead:
   targets::tar_meta_upload()        # ship meta to R2
   targets::tar_objects_upload()     # ship objects to R2
   # Then flip the config flag.
   ```

2. Add the cloud-mode setting to `_targets.R`:

   ```r
   tar_option_set(
     repository = "aws",
     resources  = list(aws = list(
       bucket   = "tcac-2-0",
       prefix   = "_targets",
       region   = "auto",
       endpoint = "<account>.r2.cloudflarestorage.com"
     ))
   )
   ```

3. Refactor the few targets that use `format = "file"` to write
   directly to R2 paths (e.g.
   `s3://tcac-2-0/scores/config=...`/...).
4. Drop the local backup of embeddings (was kept as safety in Phase 1).
5. Optional: also move `output/TCAC_2.0/corpus/` to R2 (one-time
   ~28 GB upload). Lets a collaborator skip the snapshot-extract step
   entirely.
6. Update `README.md` and the TD docs to show the "clone repo + set R2
   creds + `tar_make()`" flow for collaborators.

### What targets sees

Everything. After migration:

- `tar_outdated()` → empty (all artefacts present in R2, hashes match
  recorded meta).
- `tar_read(viz_topics_tbl)` → fetches from R2 transparently.
- Re-runs only the things you actually invalidate (a config change, a
  function source change, etc.).

### Effort

~half day, on top of Phase 1. R2 plumbing is already validated, so this
is mostly:

- One `tar_option_set` block.
- Run targets' migration helpers (~30 min upload time).
- Verify everything reads from cloud.

### Wins

- Hand a collaborator `R2_ACCESS_KEY_RO + R2_SECRET_KEY_RO` (read-only)
  → they get the entire DAG state, can pick up exactly where you left
  off without re-computing.
- Multi-machine workflow: dispatch long-running scoring on a cheap
  RunPod CPU pod while you keep working on the laptop. Both write to
  the same `_targets/`.
- Local disk needs drop to ~few GB (just the report renders).
- Paper supplement: cite the bucket URL + image digests, reviewers can
  `tar_make()` and reproduce.

---

## Why two phases, not one

Phase 2 alone would technically work — `tar_option_set(repository = "aws")`
plus targets' migration helpers would relocate everything. But three
reasons to do Phase 1 first:

1. **Phase 1 validates the foundation cheaply.** Setting up R2 bucket,
   generating credentials, getting one script to read from cloud — all
   of these break in small ways the first time. Way easier to debug
   "pod can't authenticate to R2" before you also have "targets
   metadata is now in cloud" stacked on top.

2. **Phase 1 gives immediate iteration-speed payoff.** If you do
   Phase 2 alone, you've spent half a day for *only* the sharing
   benefit. Phase 1 gives the Path B speed-up in the same half-day
   investment.

3. **Phase 1 has a trivial backout.** Revert one script + one wrapper
   if R2 turns out to be a bad fit. Phase 2's backout is harder
   because targets' DAG state is involved.

You could also do Phase 1 *only* and skip Phase 2 — that's the
"iteration-speed without sharing" trade. Recommended unless and until
you actually need the sharing/reproducibility benefits.

---

## Auth + credentials

R2 issues S3-compatible **access key + secret key** pairs scoped to a
bucket (and optionally a path prefix within it). Clean key topology:

- **One R/W key for the laptop**, stored in macOS keyring as
  `R2_ACCESS_KEY` / `R2_SECRET_KEY`.
- **One R/W key for the BERTopic pod**, stored as RunPod Secrets
  referenced in the pod template's env-var section.
- **One read-only key for collaborators** at paper-submission time.
  Different keypair so the laptop's R/W key never leaves your machine.

Storage:

- Laptop: macOS keyring entries.
- Pod templates: RunPod **Secrets** (not plain env vars).
- Image: never bakes secrets in; reads from env at runtime.

Rotation: R2 keys revoke + reissue without touching code. New key in
keyring/Secret → next run picks it up.

---

## Sharing model — for the paper

Three viable options:

| Model | Setup | Reader friction |
|---|---|---|
| **Public read-only bucket** | One config flip: bucket → Public. Public URL like `https://pub-xxx.r2.dev/tcac-2-0/...`. | Zero. wget, curl, browser, aws s3 cp --no-sign-request. |
| **Read-only API key + DOI metadata** | Generate a read-only key; publish in paper supplement. | Low — paste credentials into rclone/aws-cli. |
| **On-request via Zenodo/OSF mirror** | Snapshot the bucket → Zenodo for a DOI. | Higher — wait for approval, but gets a DOI for citation. |

For TCAC 2.0 specifically:

- **Methods section**: cite both the R2 bucket and the SHA-pinned
  docker images (`ghcr.io/rkrug/tei-specter2:proximity-v0.1.1@sha256:...`).
- **Reproducibility appendix**: provide read-only R2 credentials + a
  one-line `rclone sync` command + the `tar_make()` recipe.
- **Long-term archival**: mirror to Zenodo at submission (free,
  academic, gives a DOI, persists beyond Cloudflare's commercial
  lifetime).

R2's free egress tier (10 GB/month) covers occasional reviewer access;
if a paper goes viral and downloads exceed that, R2 charges only at
storage rate (~$0.50/month).

---

## Cost projection

Steady-state during active analysis (~3 months):

| Item | Amount | Monthly |
|---|---|---|
| R2 storage (~50 GB) | $0.015/GB × 50 | $0.75 |
| R2 Class A operations (writes) | trivial — embed/topic runs are batched | ~$0.05 |
| R2 Class B operations (reads) | thousands per BERTopic run | ~$0.10 |
| Egress to laptop / pods | $0 | $0.00 |
| Egress to public viewers (if public bucket) | first 10 GB free, then $0 | $0.00 |
| **Total** | | **~$1 / month** |

One-time setup:

- Initial upload of embeddings to R2: ~50 min done once.
- ~1 hour of R/Python coding for Phase 1.
- ~3 hours for Phase 2 (if you do it).

Cost savings:

- Path B BERTopic per-iteration: $2 → ~$1. Over 10 iterations: $10
  saved.
- One disk-failure recovery saved: ~$15 + 22 h embed compute.

---

## Invalidation considerations

What re-runs vs what's cached after each phase:

### Phase 1 — targets-level invalidation, zero compute

- `topics_tcac20_runpod` invalidated (wrapper function source changed).
- Cfg-hash skip-guard sees same cfg + valid leaf on disk → returns
  immediately. **No pod run.**
- Viz topic targets re-evaluate; output qs2 hashes identical; cascade
  skip-guards.
- `report_embeddings` re-renders (~30 sec).
- **Total: a few minutes of re-evaluation, zero recompute.**

### Phase 2 — only if done via migration helpers

The **correct** migration path:

```r
# Before flipping tar_option_set:
targets::tar_meta_upload()      # ship existing meta to R2
targets::tar_objects_upload()   # ship existing objects to R2
# Then edit _targets.R to add tar_option_set(repository = "aws", ...)
# Then tar_outdated() should show nothing outdated.
```

After this, **nothing recomputes** — targets sees the artefacts in the
cloud backend match the meta. Total migration: ~2 h upload time,
zero compute.

The **wrong** path: `tar_destroy()` then `tar_make()`. That re-runs
everything including the 22-hour embed. Don't.

### Functions without internal skip-guards

`get_tcac20_ids()`, `get_corpus_from_snapshot()`, `get_key_works()`
have no internal skip-guards. They're protected only by targets'
file-tracking. If `_targets/meta/` is lost, these re-run from scratch
(corpus extraction = ~30 min, OpenAlex API costs ~$2). Adding internal
skip-guards is a separate ~30 lines of work per function; not part of
this plan but worth flagging for belt-and-braces resilience.

After Phase 2, `_targets/meta/` is in R2 → far less likely to be lost
accidentally.

---

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| R2 outage during a Path B run | Pods retry; the R wrapper has rsync-style retries; R2 historical uptime is ~99.95%. Worst case: pod idles for an hour, watchdog stops it, re-run later. |
| Credential leak (committed accidentally) | Rotate keys. Don't bake into image. Use `.gitignore` rules + pre-commit hook to refuse pushing `R2_*` env files. |
| arrow's S3 filesystem slower than local for sequential reads | Verify in Phase 2 testing. If it does regress, cache hot artefacts locally — the embed leaves don't change often. |
| Cloudflare deprecates R2 free tier mid-project | Port to S3 or B2. Architecture is provider-agnostic because everything uses the S3 API. ~1 day of port effort. |
| `tar_destroy()` accidentally invoked after Phase 2 | Cloud objects remain in R2; meta gets re-uploaded from R2 backup. Add `tar_destroy()` to project lint rules or pre-commit warnings. |

---

## Critical files affected per phase

### Phase 1

- **New**: `R/r2_helpers.R` — thin wrappers for keyring + endpoint
  config. ~30 lines.
- **Modified**: `scripts/runpod/run_bertopic_gpu.py` — read embeddings via
  duckdb httpfs.
- **Modified**: `R/run_bertopic_runpod.R` — drop rsync upload; pass
  small cfg yaml + small result download only.
- **Modified**: `docker/bertopic-runpod/Dockerfile` — duckdb httpfs
  extension preinstalled (already pulls duckdb in v0.1.2).
- **Modified**: `docker/bertopic-runpod/CHANGES.md` — v0.2.0 entry.
- **Modified**: `config.yaml` — new `r2:` block with bucket name,
  endpoint, keyring entry names.

### Phase 2

- **Modified**: `_targets.R` — `tar_option_set(repository = "aws", ...)`.
- **Modified**: `R/score_keypapers.R` — read embeddings from R2 (the
  Phase 1 local copy is now gone).
- **Modified**: `R/build_visualisations.R` — same.
- **Optional**: `R/get_corpus_from_snapshot.R` wrapper to write corpus
  extract to R2 directly.

---

## Verification per phase

### Phase 1 verification

1. **Credentials work**: `rclone ls r2:tcac-2-0/` from laptop lists
   the embeddings.
2. **Pod can read**: SSH into pod, run a duckdb one-liner against R2:

   ```bash
   python3 -c "import duckdb; con = duckdb.connect(); con.execute('LOAD httpfs'); con.execute(\"SET s3_endpoint='...'; SET s3_access_key_id='...'; SET s3_secret_access_key='...'\"); print(con.execute(\"SELECT COUNT(*) FROM read_parquet('s3://tcac-2-0/embeddings/.../variant=title_abstract/*.parquet')\").df())"
   ```

3. **End-to-end Path B**: `tar_make(names = "topics_tcac20_runpod")`.
   Total wall time should drop to ~1 h. No 50-min upload phase.
4. **Result equivalence**: topic counts and the top-N relevant topics
   match a control run from local-storage Path B (same seed → bit
   identical).

### Phase 2 verification

1. **Migration ran clean**: `targets::tar_outdated()` returns empty
   list immediately after `tar_meta_upload` + `tar_objects_upload` +
   `tar_option_set` flip.
2. **`tar_read(viz_topics_tbl)`** returns the expected DT widget from
   the cloud-stored object.
3. **Fresh-clone test**: clone the repo on a different machine, set R2
   credentials, `tar_make()`. Everything reports up-to-date, nothing
   recomputes. (Or, if it does recompute something, that's a bug to
   investigate.)
4. **Cloud bucket contents**: `rclone tree r2:tcac-2-0/` shows
   `_targets/meta/`, `_targets/objects/`, plus the artefact subtrees.

---

## Open questions to resolve before implementation

1. **R2 bucket region**. R2 buckets are global by default but have a
   primary region for write performance. Pick `WEUR` if your laptop is
   in Europe, `auto` otherwise.
2. **Versioning**. R2 supports object versioning. Worth turning on for
   the embeddings leaf so accidental overwrites can be rolled back?
3. **Lifecycle rules**. Automatically delete `_targets/objects/`
   intermediates after 90 days, or keep forever for paper
   reproducibility?
4. **Multiple buckets vs single with prefixes**. Single bucket
   `tcac-2-0` with top-level prefixes (current sketch), or separate
   `tcac-2-0-embeddings`, `tcac-2-0-topics`, etc.? Single is simpler;
   separate makes read-only sharing of subsets easier.
5. **Collaboration model**. Are paper co-authors expected to write to
   R2 (i.e. dispatch their own BERTopic runs) or just read?

---

## Recommendation summary

- **Phase 1 first**, when you decide to iterate Path B ≥2 more times
  AND want a cloud backup of embeddings. Half a day, immediate
  benefit, low risk.
- **Phase 2 later**, when prepping the paper for submission. Half a day
  on top of Phase 1. Gives sharable DAG state + collaborator
  reproducibility.
- **You can stop at Phase 1** and skip Phase 2 entirely if sharing
  isn't on your roadmap; you keep the iteration-speed benefit
  indefinitely.
- **R2 is the right provider** for this workload because of zero
  egress. Treat the migration as provider-agnostic so it remains
  portable if R2's commercial situation changes.
- **The architecture composes with everything already in place**:
  per-variant emb targets, BERTopic dual-path, cfg-hash skip-guard,
  idle-watchdog, persistent logs. No back-tracking required.

**Don't migrate without a trigger.** Phase 1's payoff materialises when
you've decided you'll re-run BERTopic ≥3 more times. If TCAC 2.0 is
one-shot from here, only Phase 2 makes sense — for the sharing benefit
at paper submission time. Sequence the call to that trigger.
