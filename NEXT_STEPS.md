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

- [ ] **Implement BERTopic stage caching**
  per [TODO_BERTopicStageCaching.md](TODO_BERTopicStageCaching.md).
  - [ ] Python: split `scripts/run_bertopic_gpu.py` into `umap-fit` /
    `hdbscan-fit` / `ctfidf` / `project-keypapers` subcommands.
  - [ ] Wire each to write/read intermediate state under
    `s3://tcac-2-0/intermediate/...`.
  - [ ] R-side: split `topics_tcac20_runpod` into
    `umap_fit_runpod` + `hdbscan_fit_runpod` + `topics_tcac20_runpod`.
  - [ ] Add scoped `bertopic_runpod_cfg_umap` /
    `bertopic_runpod_cfg_hdbscan` targets for hash-scoped invalidation.
  - [ ] R2 lifecycle rule: 30-day TTL on `intermediate/` prefix.

- [ ] **Decouple keypapers from BERTopic fit** (Option A in the TODO).
  Required for the keypaper-swap workflow to be cheap. Refactor the
  GPU script so BERTopic fits on corpus only; keypapers are projected
  after the fact via `umap_model.transform()` +
  `hdbscan.approximate_predict()`.

- [ ] **Add named `keypaper_sets:` config block**
  per the new section in
  [TODO_BERTopicStageCaching.md](TODO_BERTopicStageCaching.md).
  Supports `.rds`, `.json` (title+abstract), and `.csv` inputs.
  Each set writes to its own hive-partitioned output path so prior
  results survive.

- [ ] **Build the first new keypaper set**.
  Likely candidates: imagination, sustainability, transformation.
  Compile manually as JSON (title + abstract) for ~30-50 papers,
  drop under `input/key papers/`, add to
  `keypaper_sets.sets:` in config.yaml, run the cheap project +
  score pipeline.

- [ ] **Cross-set comparison viz**.
  Once ≥2 keypaper sets have results, add a comparison target
  (Jaccard overlap of relevant topic IDs, heatmap of n_keypapers per
  topic × set, etc.). Already sketched in
  [TODO_BERTopicStageCaching.md](TODO_BERTopicStageCaching.md).

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
