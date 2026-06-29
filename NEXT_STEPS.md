# Next Steps — TCAC 2.0

Living checklist of what's next. Updated as items land.

Last updated: 2026-06-29.

## 🚨 URGENT — first Path B BERTopic fit collapsed

The completed v0.1.13 full-corpus run produced **only 6 topics**, with
topic 3 absorbing 99% of the corpus:

```
topic 3: 4,564,627 primary + 1,161,334 fallback + 105 keypapers
         = 5,726,066 of 5,768,257 works (~99%)
nrow(topic_info) = 6
```

Vocabulary for topic 3 is generic corpus-wide (water, species, climate,
soil, economic, …) — diagnostic of a collapsed clustering, not a
meaningful topic. Fallback inherits the dominant cluster, so the
problem is in the **primary HDBSCAN fit**, not the fallback projection.

Likely root cause: UMAP+HDBSCAN params from `default_runpod` don't hold
up at 5.77 M scale. `hdbscan_min_cluster_size: 500` plus the current
UMAP settings probably collapsed the embedding into one dominant blob.

Next diagnostic step before retuning:

1. Inspect the UMAP 2D projection (`viz_umap_fig` / `viz_umap_*`) — does
   it show structure or one blob? That tells us whether UMAP or
   HDBSCAN is the culprit.
2. If UMAP looks fine → bump `hdbscan_min_cluster_size` down (200?
   100?) and/or `min_samples` down.
3. If UMAP collapsed → retune `umap_n_neighbors` (try 50-100) and
   `umap_min_dist` (try 0.1).

Retune does NOT require image rebuild — just a new bertopic config
entry under `bertopic.configs:` and a dispatch. v0.1.13 stage caching
won't help here (cfg-hash changes invalidate UMAP+HDBSCAN+c-TF-IDF
caches), so retune cost ≈ full pod run (~50 min).

## Short-term — finish current Phase 1 cycle

- [ ] **Retune the BERTopic fit** per the URGENT section above.

- [ ] **Find clustering parameters that yield useful topics as a
  base for other keypaper sets**. The retune above only gets us out
  of the collapse; the production target is parameter values that
  produce well-separated, interpretable topics so that *switching the
  keypaper set later* (per
  [TODO_NamedKeypaperSets.md](TODO_NamedKeypaperSets.md)) reuses the
  same UMAP+HDBSCAN fit and just re-projects the new keypapers. That
  means once we land on a good parameterisation we should:
  - Lock the bertopic config under a stable name (e.g.
    `prod_runpod_v1`) in `input/config.yaml`.
  - Capture the cfg-hash for the cached UMAP / HDBSCAN / c-TF-IDF
    stages on R2 — those become the shared base across keypaper sets.
  - Document the chosen parameter values + rationale in
    [TD_BERTopic_Parameters.md](TD_BERTopic_Parameters.md).
  Useful means roughly 200–500 well-separated topics, the topic-size
  histogram (`fig_topic_sizes`, to be wired) is reasonably flat in
  log-y, and the per-topic c-TF-IDF vocabulary reads as topical not
  generic.

- [ ] **Finalise visualisations** for the reports.
  - [ ] Wire `viz_umap_density` / `viz_umap_hulls` /
    `viz_umap_cluster_pts` / `viz_umap_clusters_fig` as `tar_target()`s
    in [_targets.R](_targets.R). Functions already in
    [R/build_visualisations.R](R/build_visualisations.R).
  - [ ] Tune `min_points`, `concavity` for the corpus-scale Path B
    output once the BERTopic fit is retuned.
  - [ ] Add the density+polygon figure to
    [TCAC 2.0 Embedding Report.qmd](TCAC 2.0 Embedding Report.qmd) with
    caption.

- [ ] **Finalise the reports**.
  - [ ] Re-render
    [TCAC 2.0 Embedding Report.qmd](TCAC 2.0 Embedding Report.qmd) with
    the retuned Path B topics.
  - [ ] Re-render
    [TCAC 2.0 Corpus Report.qmd](TCAC 2.0 Corpus Report.qmd) once
    `corpus_tcac10` + `corpus_comparison` finish.
  - [ ] Spot-check accessibility (alt text, contrast for the polygon
    layer).

- [ ] **Finalise documentation**.
  - [ ] Refresh image digests in
    [TD_BERTopic_Parameters.md](TD_BERTopic_Parameters.md) once a
    well-tuned image is verified.
  - [ ] Cross-link TD_ and TODO_ files from
    [CLAUDE.md](CLAUDE.md) and report appendices.

## Medium-term — keypaper-swap workflow

- [ ] **R-side target split (upgrade to "Option A from the original
  discussion")**: split `topics_tcac20_runpod` into
  `umap_fit_runpod` + `hdbscan_fit_runpod` + `topics_tcac20_runpod`
  with scoped `bertopic_runpod_cfg_umap` /
  `bertopic_runpod_cfg_hdbscan` cfg subsets. Lets `tar_outdated()`
  report per-stage. Compute savings are the same as v0.1.8; the gain
  is orchestration clarity. Deferred unless the workflow grows.
- [ ] **R2 lifecycle rule: 30-day TTL on `intermediate/` prefix**.
  ```bash
  rclone backend lifecycle r2:tcac-2-0 \
    set --rule 'prefix=intermediate/,days=30,action=delete'
  ```
- [ ] **Add named `keypapers:` config block**
  per [TODO_NamedKeypaperSets.md](TODO_NamedKeypaperSets.md).
  Canonical 4-column schema `(id, doi, title, abstract)` with
  `id` user-provided and unique. Outputs hive-partitioned under
  `keypaper_set=<name>/` so prior results coexist.
- [ ] **Build the first new keypaper set**.
  Likely candidates: imagination, sustainability, transformation.
  After v0.1.13 R2 stage caching, dispatch is ~7-10 min on a fresh pod.
- [ ] **Re-enable + fix the per-sub-term `assess_*` targets**
  ([R/assess_search_term.R](R/assess_search_term.R)). Currently
  commented out in [_targets.R](_targets.R) — the `tfc_st` formatting
  contains lines that OpenAlex rejects with HTTP 500 when AND-combined
  with `nature_st`. Sanitising the search-term file (or filtering
  malformed sub-terms inside the function) unblocks them.
- [ ] **Cross-set comparison viz** (later, when ≥2 keypaper sets):
  Jaccard overlap of relevant topic IDs, heatmap of n_keypapers per
  topic × set, per-keypaper distance to nearest topic centroid. Sketch
  in [TODO_NamedKeypaperSets.md](TODO_NamedKeypaperSets.md)
  §"Open questions deferred for later".

## Optional — implement if/when the pain materialises

- [ ] **Detached BERTopic dispatch** — make a pod run survive
  Ctrl-C in R, R/RStudio crashes, laptop sleep, or laptop ↔ pod
  network breakdown. See
  [TODO_DetachedDispatch.md](TODO_DetachedDispatch.md). Stage caching
  already mitigates most of the risk class (worst-case loss with
  Ctrl-C today is ~30-60 min, one stage's compute); this shrinks that
  to "zero loss". ~1 day of work, R wrapper only.

## Conceptual — what the figures should say

- [ ] **Visualisation principles + backlog**
  ([TODO_Visualisations.md](TODO_Visualisations.md)). Shared
  coordinate system, fig_/tbl_/viz_ convention, replacing
  `viz_scores_long`, when to wire density+polygon viz, cross-keypaper-
  set viz design, variant-agreement keep-or-drop, interactive vs
  static deliverables.

## Deferred — not on roadmap, kept for reference

- **Full cloud migration**
  ([TODO_FullCloudMigration.md](TODO_FullCloudMigration.md)).
  Not needed for the fixed-corpus + variable-keypapers workflow.
- **Shiny app** ([TODO_ShinyMigration.md](TODO_ShinyMigration.md)).
  Not needed for the static report deliverable.
- **Phase 2 of cloud storage**
  ([cloud_storage_migration.md](cloud_storage_migration.md) §"Phase 2").
  Full `_targets/` cloud-mode. Not blocking.

## Done — most recent first

- [x] **Corpus Report — folded comparison into Results**. Removed the
  standalone "Comparison with TCAC 1.0" section; works-per-type and
  keypaper-presence tables now appear once each under
  `## TCA Corpus properties`, with TCAC 1.0 and 2.0 columns side-by-side.
  Corpus-size table also shows both. The added/removed/kept yearly chart
  lives as a sub-section under "Publications over time".
- [x] **Corpus Report + TCAC 1.0 ↔ 2.0 comparison**
  (`TCAC 2.0 Corpus Report.qmd`, `corpus_comparison`,
  `keypapers_in_corpus`, `yearly_counts`).
- [x] **`get_count.R` bug fix** — `tca_*` queries now use the
  combined `tca_st` instead of `nature_st`.
- [x] **`config.yaml` moved into `input/`** (mirrors other inputs).
- [x] **`viz_embeddings` removed; `viz_scores_long` slimmed** to
  per-id max-sim (17M rows). All consumers refactored to arrow
  pushdown / duckdb GREATEST.
- [x] **`fig_*` / `tbl_*` / `viz_*` naming pass** + `build_viz_*`
  helpers to avoid target / function name collisions.
- [x] **`emb_tcac20_abstract` consolidation resumed** after disk-full
  crash via [scripts/consolidate_leaf.R](scripts/consolidate_leaf.R).
  All three corpus variants now have `.embed_complete` markers.
- [x] **`topics_tcac20` alias removed**. Viz layer references
  `topics_tcac20_runpod` directly (avoids targets' static-analysis
  double-dispatch).
- [x] **`viz_topics_table_data` refactored** to depend on
  `emb_tcac20_title` instead of `viz_embeddings`.
- [x] **v0.1.13 image** (fallback projection cached on R2).
- [x] **v0.1.12 image** (push c-TF-IDF aggregation into duckdb).
- [x] **v0.1.11 image** (text-less corpus read in stage_umap).
- [x] **v0.1.10 image** (del df_corpus before fit_transform).
- [x] **v0.1.9 image** (multipart upload + heartbeat self-match fix).
- [x] **v0.1.8 image** (stage caching + BERTopic-bypass).
- [x] **v0.1.7 image** (external bash heartbeat keeper, GIL-immune).
- [x] **v0.1.6 image** (PYTHONUNBUFFERED=1).
- [x] **v0.1.5 image** (CUDA 12.0 base + driver pre-flight).
- [x] **Phase 1 cloud storage** — embeddings on R2, pod reads via
  duckdb httpfs.

## Open questions to revisit

- After a successful Path B BERTopic run: are the params good?
  Particularly `hdbscan_min_cluster_size: 500` — gives ~200-500
  topics or do we need to retune?
- Image versioning: bump to v0.2.0 once the keypaper-swap refactor
  lands, signalling clusters no longer include keypapers in the fit.
