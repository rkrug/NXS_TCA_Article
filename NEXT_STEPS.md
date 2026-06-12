# Next Steps — TCAC 2.0

Living checklist of what's next. Updated as items land.

Last updated: 2026-06-11.

## Short-term — finish current Phase 1 cycle

- [ ] **Wait for first Path B BERTopic run to complete.**
  Currently running on the v0.1.5 pod (CUDA 12.0 base, driver
  pre-flight in wrapper). Expected wall time ~1.5-2 h. Result lands
  as `output/TCAC_2.0/topics/config=SPECTER2_runpod/bertopic=default_runpod/variant=title_abstract/`.

- [ ] **Embed the `abstract` variant of the corpus.**
  Compute on the RunPod TEI pod (fast, infra already there), but
  result stays local — **do not sync to R2**. Path B BERTopic uses
  only `title` + `title_abstract`, so the abstract variant has no
  consumer in the cloud; it's only needed for the report's
  variant-agreement figures + `viz_embeddings` target which run on
  the laptop. Run `tar_make(names = "emb_tcac20_abstract")` once the
  BERTopic dispatch is no longer competing for the pod.
  - [ ] After embed: update
    [scripts/sync_embeddings_to_r2.sh](scripts/sync_embeddings_to_r2.sh)
    to exclude `**/variant=abstract/**` so it never accidentally gets
    pushed to R2.

- [ ] **Finalise visualisations** for the report.
  - [ ] Wire `viz_umap_density` / `viz_umap_hulls` /
    `viz_umap_cluster_pts` / `fig_umap_clusters` as `tar_target()`s in
    [_targets.R](_targets.R). Functions already in
    [R/build_visualisations.R](R/build_visualisations.R).
  - [ ] Tune `min_points`, `concavity` for the corpus-scale Path B
    output (Path A overclustered; Path B should self-clean).
  - [ ] Decide on click-to-drill-down UX final form (highlight colour,
    point sample size, hover text).
  - [ ] Add the figure to [TCAC 2.0 Vectorisation.qmd](TCAC 2.0 Vectorisation.qmd)
    with caption.

- [ ] **Finalise the report**.
  - [ ] Re-render
    [TCAC 2.0 Vectorisation.qmd](TCAC 2.0 Vectorisation.qmd) with the
    Path B topics. Confirm `viz_score_quantiles_tbl`, `fig_score_dist`,
    `fig_threshold`, `fig_umap`, `fig_topics`, `fig_topics_tbl` all
    render cleanly with the new data.
  - [ ] Re-render
    [TCAC 2.0 Building.qmd](TCAC 2.0 Building.qmd) including the new
    pipeline + sequence diagrams.
  - [ ] Spot-check accessibility (alt text, contrast for the polygon
    layer).

- [ ] **Finalise documentation**.
  - [ ] Cross-link TD_ and TODO_ files from
    [CLAUDE.md](CLAUDE.md) and the report appendices.
  - [ ] Update [README.md](README.md) (if/when one exists) with the
    Phase 1 R2 workflow + how to reproduce.
  - [ ] Refresh image digests in
    [TD_BERTopic_Parameters.md](TD_BERTopic_Parameters.md) once
    `bertopic-runpod:v0.1.5` is verified working.

## Medium-term — keypaper-swap workflow

- [x] **Implement BERTopic stage caching (Option B from earlier
  discussion — Python-internal staging, R targets unchanged)**.
  Done in v0.1.8 image / `scripts/run_bertopic_gpu.py` refactor.
  Six explicit stages with cascade cfg-hash keying, R2-backed.
  Keypapers decoupled from BERTopic fit (Option A from the TODO).
  Memory-friendly c-TF-IDF on per-topic concatenated docs (sidesteps
  the Representation-step OOM that killed three earlier runs).
- [ ] **R-side target split (upgrade to "Option A from the original
  discussion")**: split `topics_tcac20_runpod` into
  `umap_fit_runpod` + `hdbscan_fit_runpod` + `topics_tcac20_runpod`
  with scoped `bertopic_runpod_cfg_umap` /
  `bertopic_runpod_cfg_hdbscan` cfg subsets. Lets `tar_outdated()`
  report per-stage rather than treating the whole pipeline as one
  blob. Compute savings are the same as v0.1.8; the gain is
  orchestration clarity. Deferred unless the workflow grows.
- [ ] **R2 lifecycle rule: 30-day TTL on `intermediate/` prefix**.
  Run once via rclone:
  ```bash
  rclone backend lifecycle r2:tcac-2-0 \
    set --rule 'prefix=intermediate/,days=30,action=delete'
  ```

- [ ] **Add named `keypapers:` config block**
  per [TODO_NamedKeypaperSets.md](TODO_NamedKeypaperSets.md).
  Canonical 4-column schema `(id, doi, title, abstract)` with
  `id` user-provided and unique; optional DOI for cross-reference;
  `title`/`abstract` from user OR fetched from OpenAlex when only
  DOI provided. Supports `.rds`, `.csv`, `.json` inputs. Each set's
  outputs hive-partitioned under `keypaper_set=<name>/` so prior
  results coexist.

- [ ] **Build the first new keypaper set**.
  Likely candidates: imagination, sustainability, transformation.
  Compile manually as CSV with the 4-column schema for ~30-50
  papers, drop under `input/key papers/`, add to
  `keypapers.sets:` in config.yaml, dispatch — should be ~7-10 min
  on a fresh pod thanks to v0.1.13 R2 stage caching.

- [ ] **Cross-set comparison viz** (later).
  Once ≥2 keypaper sets have results: Jaccard overlap of relevant
  topic IDs, heatmap of n_keypapers per topic × set, per-keypaper
  distance to nearest topic centroid. Sketched in
  [TODO_NamedKeypaperSets.md](TODO_NamedKeypaperSets.md) §"Open
  questions deferred for later".

## Optional — implement if/when the pain materialises

- [ ] **Detached BERTopic dispatch** — make a pod run survive
  Ctrl-C in R, R/RStudio crashes, laptop sleep, or laptop ↔ pod
  network breakdown. See [TODO_DetachedDispatch.md](TODO_DetachedDispatch.md)
  for the full design. Stage caching already mitigates ~most of the
  same risk class (worst-case loss with Ctrl-C today is ~30-60 min,
  one stage's compute); this would shrink that to "zero loss".
  ~1 day of work, no image rebuild required (R wrapper only).
  Trigger criteria documented in the TODO.

## Deferred — not on roadmap, kept for reference

- **Full cloud migration**
  ([TODO_FullCloudMigration.md](TODO_FullCloudMigration.md)).
  Not needed for the fixed-corpus + variable-keypapers workflow.
  Revisit only if multi-author collaboration or reviewer-side
  reproducibility becomes a goal.
- **Shiny app**
  ([TODO_ShinyMigration.md](TODO_ShinyMigration.md)).
  Not needed for the static report deliverable. Revisit if
  reviewers want live click-through analysis.
- **Phase 2 of cloud storage**
  ([cloud_storage_migration.md](cloud_storage_migration.md) §"Phase 2").
  Full `_targets/` cloud-mode. Not blocking anything.

## Done — most recent first

- [x] **v0.1.8 image** (stage caching + BERTopic-bypass) — pending build.
- [x] **v0.1.7 image** (external bash heartbeat keeper, GIL-immune) — `a46a261`.
- [x] **v0.1.6 image** (PYTHONUNBUFFERED=1 for real-time log flushing) — `dba7af2`.
- [x] **v0.1.5 image** (CUDA 12.0 base + driver pre-flight) — `499a488`.
- [x] **TODO_ rename + stage caching design** — `27bc7ee`.
- [x] **Density+polygon viz helpers** — `7d2b16d`.
- [x] **TD_ShinyMigration.md** — `51d9901`.
- [x] **v0.1.4 image** (heartbeat thread + python symlink in image) —
  `2b97e43`.
- [x] **`output/` symlink workaround** — `ebbd4bc`.
- [x] **Phase 1 cloud storage + multi-file embeddings + fig_ rename + docs**
  — `2174c89`. Embeddings now in R2, pod reads directly via duckdb
  httpfs.

## Open questions to revisit

- After the first successful Path B BERTopic run: are the parameters
  good? Particularly `hdbscan_min_cluster_size: 500` — does the
  result give the expected ~200-500 topics, or do we need to retune?
- ~~Should the `abstract`-only embedding variant ever go on R2?~~
  **Resolved 2026-06-11**: no. Path B doesn't consume it, only the
  laptop-side variant-agreement figures do. Embedding compute on
  pod, result stays local.
- Image versioning: bump to v0.2.0 once the keypaper-swap refactor
  lands, signalling a meaningful behavioural change in the topic
  outputs (clusters no longer include keypapers in the fit).
