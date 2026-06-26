# TODO — Visualisations

Conceptual notes + open work for the report-side visualisation layer. The
data side (corpus, embeddings, scores, topics) is reasonably consolidated;
the viz side is not. This file is the place to think about what the
figures should *say* before deciding what to draw.

Companions:
- [TODO_NamedKeypaperSets.md](TODO_NamedKeypaperSets.md) — cross-set viz
  is the future work that drives most of the design tension here.
- [TODO_BERTopicStageCaching.md](TODO_BERTopicStageCaching.md) — context
  for why topic outputs are now cheap to rebuild (relevant when re-running
  after a viz-driven param retune).

## Principles we should commit to

Currently the figures are inconsistent in what they encode. Before adding
more, pick a small set of conventions and apply them everywhere:

1. **One scatter coordinate system** for everything spatial.
   All UMAP-style figures (`viz_umap_fig`, `viz_umap_clusters_fig`, future
   per-set views) should share the same 2D embedding. Right now
   `viz_umap_coords` fits a fresh UMAP per build; it should be a cached
   target keyed on its inputs so successive figures sit in the same
   space.

2. **Corpus = grey background, keypapers = coloured foreground.**
   Across every figure. Avoid using corpus colour to encode a variable
   the keypapers also use — that double-encoding has bitten us before.

3. **Score = transparency or contour, never marker colour.**
   Score is a continuous derived quantity; topic / set / variant is
   categorical. Reserve colour for the categorical layer so multiple
   figures stay comparable.

4. **Sample-based viz is honest, not a shortcut.**
   Every viz target captures a `sample_size` and a `seed` in its inputs
   (already done for `viz_umap_coords` via `viz.umap_sample_size`). The
   report should report what fraction of the corpus is shown, and the
   seed, in the caption.

5. **Cluster identity comes from BERTopic, not from re-clustering the
   viz UMAP.** The 2D UMAP is for *display* only. Polygons in
   `viz_umap_clusters_fig` enclose points that share a `topic_id` from
   the 5D HDBSCAN fit — they're a visual summary, not a derivation.

## Current state — what works, what doesn't

| Figure / table | Target | State | Notes |
|---|---|---|---|
| Score density | `viz_score_dist_fig` | **built** | frequency polygons on pre-binned `viz_score_dist_data` |
| Score ECDF | `viz_score_ecdf_fig` | **built** | sampled 50k/variant, seed=13 |
| Threshold | `viz_threshold_fig` | **built** | log10(0) drop applied |
| Variant agreement | `viz_agree_fig` | **built** | inverted-L 2D-tile heatmap; abstract variant now embedded so the figure is buildable |
| Top/bottom matches | `viz_top_bottom` | **built** | refactored to read corpus titles via arrow pushdown |
| Score summary table | `viz_score_summary_tbl` | **built** | reads slim `viz_scores_long` |
| Score quantiles table | `viz_score_quantiles_tbl` | **built** | same |
| UMAP scatter | `viz_umap_fig` | **built** | sampled corpus (1000 rows by default), keypapers always unsampled |
| UMAP topics overlay | `viz_topics_fig` | **built** | depends on `topics_tcac20_runpod` |
| Topics table | `tbl_topics` | **built** | reads `emb_tcac20_title` directly |
| Type breakdown | `viz_type_count_fig`, `viz_type_score_heatmap_fig`, `viz_type_score_box_fig` | **built** | filtered to types ≥ 0.5% |
| Per-keypaper score distribution | `viz_keypaper_score_dist_fig` | **built** | plotly with HTML anchor tick labels — click to OpenAlex |
| Keypaper self-similarity | `viz_keypaper_self_sim_fig` | **built** | 105×105 cosine heatmap, hierarchical order |
| Embedding L2-norm sanity | `viz_emb_norm_fig` | **built** | sampled 50k/leaf |
| Citation-vs-score | `viz_citation_score_fig` | **built** | 2D bin of (log citations, max sim) |
| Score vs publication year | `viz_score_year_fig` | **built** | tiles + mean/median lines per variant |
| Text length, language, truncation | various | **built** | reported from corpus parquet via duckdb pushdown |
| Density + polygons | `viz_umap_clusters_fig` | **not wired** | function exists in `R/build_visualisations.R`; needs tar_target + inputs `viz_umap_density`, `viz_umap_hulls`, `viz_umap_cluster_pts`. Don't wire until BERTopic fit is retuned — current 6-topic collapse would render as one giant polygon. |
| Topic-size histogram | `fig_topic_sizes` | **not wired** | retune diagnostic — see §2 below. |

## Big conceptual decisions to make

### 1. `viz_scores_long` — DONE

Replaced with the slim per-id max form (17M rows × `(id, variant, score)`)
computed via duckdb `GREATEST()`. All consumers refactored. The old
605M-row wide-pivot is gone. Documented here so future "what was the
problem" questions don't re-investigate.

Pre-binning the histogram (`viz_score_dist_data`) and sampled ECDF
(`viz_score_ecdf_data`) keep the fig targets tiny — `tar_read` is
instant.

### 2. How do we visualise cluster collapse vs success?

Diagnostic for `viz_umap_fig` retunes: a small per-topic count histogram is
enough to spot collapse (one bar dwarfs all others). Useful in the
report as a methodology check ("topic-size distribution shows X% of the
corpus in topic Y; HDBSCAN considers this a single cluster") — but only
once tuned and stable.

Worth a target: `fig_topic_sizes` (histogram of topic counts, log
y-axis). Should be small and cheap; useful both for retuning and for
the final report.

### 3. Cross-keypaper-set figures (see [TODO_NamedKeypaperSets.md](TODO_NamedKeypaperSets.md))

Once a second keypaper set lands, the report needs to answer
"how does the relevance landscape change?". Sketches:

- **Topic overlap heatmap**: rows = topics, cols = sets, cells =
  `n_keypapers` (or `is_relevant`). Eyeball which topics are universal
  vs set-specific.
- **Jaccard matrix between sets**: of "topics flagged relevant",
  pairwise Jaccard. Numeric one-figure summary.
- **Per-keypaper trajectory** (more ambitious): if a keypaper appears
  in N sets, plot its UMAP position across the corpus once, with N
  coloured rings indicating which sets include it. Probably overdesign
  for the static report.

Defer the build until ≥2 sets exist; capture the design here so the
choice is pre-made.

### 4. Variant-agreement viz: kept (decision (a))

All three variants are now embedded (title, abstract, title_abstract).
The variant-agreement figure (`viz_agree_fig`) is built as an
inverted-L 2D-tile heatmap of per-work max-sim between each variant
pair. Pre-binned data target (`viz_agree_data`, ~30k rows) — figure
loads instantly.

### 5. Interactive vs static

The current viz layer mixes `htmlwidgets` (DT, plotly) and `ggplot2`
PNGs in `output/figures/`. For the *paper* version, every figure
ultimately becomes a static raster — the interactive forms are for
exploration during writing. Make the split explicit:

- `fig_*` static targets render PNG/PDF for the manuscript.
- A parallel `interactive_*` set of targets renders the HTML widget
  versions for exploration.

Right now `tbl_topics` produces an HTML widget into
`output/figures/` and the report embeds it. That's fine for an HTML
report but won't survive a PDF render. Pick the deliverable form
before adding more figures.

## Wiring backlog (mechanical)

- [ ] Wire `viz_umap_density`, `viz_umap_hulls`, `viz_umap_cluster_pts`,
  `viz_umap_clusters_fig` as `tar_target()`s. Inputs already implemented
  in [R/build_visualisations.R](R/build_visualisations.R). Defer until
  BERTopic fit is retuned (the 6-topic collapse would render as one
  giant polygon).
- [ ] Add `fig_topic_sizes` (cheap, useful as a retune diagnostic).
- [ ] Rename `viz_score_summary_tbl` / `viz_score_quantiles_tbl` →
  `tbl_score_summary` / `tbl_score_quantiles` for prefix consistency
  with `tbl_topics`.
- [ ] Caption convention: every figure caption says (a) what's shown,
  (b) sample size + seed if applicable, (c) which keypaper set was used.

## Why this matters before drawing anything

The session that produced this document found:

- the first full-corpus BERTopic fit collapsed (6 topics, 99% in one)
- the viz path tried to load the full corpus and OOM'd in three places
- the fig_ / tbl_ / viz_ naming wasn't consistent
- the abstract variant was a hidden dependency of figures that didn't
  need it

Adding more figures without committing to principles (above) will keep
producing these surprises. The figures aren't the bottleneck — the
decisions about *what they should encode* are.

## Open questions

1. Single vs multi-keypaper-set: is the report's headline figure the
   `keypaper_tcac10` UMAP, or a multi-set view? Drives section ordering.
2. Polygon style: convex hull vs concaveman vs alpha shape? Concaveman
   is implemented; alpha shape would need `alphahull`. Visual
   trade-off, not performance.
3. Density: KDE (smooth) or 2D histogram (honest about local
   noise)? Current code does KDE.
4. Topic vocabulary in caption / hover / both? Long vocab strings
   overflow plot margins.
5. Do we want a "drill-down" interactive figure as the report's primary
   exploratory artefact, or as a supplement only?
