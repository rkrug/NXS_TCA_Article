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
   All UMAP-style figures (`fig_umap`, `fig_umap_clusters`, future
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
| Score density | `fig_score_dist` | OOM-prone | needs `viz_scores_long` (5.77M × 105 → 600M-row long form) |
| Threshold | `fig_threshold` | OOM-prone | same dependency |
| Variant agreement | `fig_agree` | OOM-prone | same; also needs all three variants embedded |
| Top/bottom matches | `viz_top_bottom` | OOM-prone | same |
| Score summary table | `viz_score_summary_tbl` | OOM-prone | same |
| Score quantiles table | `viz_score_quantiles_tbl` | OOM-prone | same |
| UMAP scatter | `fig_umap` | **unblocked** | now reads scores via pushdown for the sampled ids only |
| UMAP topics overlay | `fig_topics` | **unblocked** | same |
| Topics table | `tbl_topics` | **unblocked** | reads `emb_tcac20_title` directly |
| Density + polygons | `viz_umap_clusters_fig` | **not wired** | function exists in `R/build_visualisations.R`; needs tar_target + inputs `viz_umap_density`, `viz_umap_hulls`, `viz_umap_cluster_pts`. Don't wire until BERTopic fit is fixed (current 6-topic collapse would render as one giant polygon). |
| Variant-agreement figures | several | deferred | abstract-only variant not embedded yet; not on R2 either ([NEXT_STEPS.md](NEXT_STEPS.md)). |

## Big conceptual decisions to make

### 1. What is `viz_scores_long`, replaced with what?

The current `viz_scores_long` materialises the wide score parquet into a
600M-row tibble. Every distribution / summary consumer depends on it.
At full-corpus scale that's the structural cause of most viz OOMs.

Options:

- **Slim long form**: per (id, variant) the *max* over keypapers — 17M
  rows × 3 vars ≈ 50 MB. Fine for percentile / quantile summaries; loses
  the per-keypaper detail.
- **Pre-aggregated summary cache**: store quantile breaks +
  histogram bins per variant, never materialise the rows. Distribution
  figures read the cache; sampling figures sample on demand from the
  parquet via arrow pushdown.
- **Sample uniformly**: 100k rows per variant for the density plots,
  full data for quantiles via arrow `summarise`. Works at all scales,
  visually indistinguishable from full.

Recommended path: combination of pre-aggregated summary cache (for
tables and density curves) + targeted pushdown reads (for per-id joins
like the one `viz_umap_data` now does). Drop `viz_scores_long` once
both are in place.

### 2. How do we visualise cluster collapse vs success?

Diagnostic for `fig_umap` retunes: a small per-topic count histogram is
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

### 4. Variant-agreement viz: keep or drop?

Originally three embedding variants (title, abstract, title_abstract).
The current production path only consumes title and title_abstract;
abstract is deferred (no priority, stays local). Variant-agreement
figures were a sanity check on the embedding step — at full corpus
scale they're expensive to build (require all three variants on disk
+ a long pivot).

Decision needed: either (a) commit to embedding the abstract variant
eventually so these figures exist for the methodology section, or (b)
drop them entirely and replace with a smaller "pilot variant agreement"
on the 1000-row pilot subset. The latter is honest and cheap.

### 5. Interactive vs static

The current viz layer mixes `htmlwidgets` (DT, plotly) and `ggplot2`
PNGs in `output/figures/`. For the *paper* version, every figure
ultimately becomes a static raster — the interactive forms are for
exploration during writing. Make the split explicit:

- `fig_*` static targets render PNG/PDF for the manuscript.
- A parallel `interactive_*` set of targets renders the HTML widget
  versions for exploration.

Right now `fig_topics_table` produces an HTML widget into
`output/figures/` and the report embeds it. That's fine for an HTML
report but won't survive a PDF render. Pick the deliverable form
before adding more figures.

## Wiring backlog (mechanical, do once decisions above are made)

- [ ] Wire `viz_umap_density`, `viz_umap_hulls`, `viz_umap_cluster_pts`,
  `viz_umap_clusters_fig` as `tar_target()`s. Inputs already implemented
  in [R/build_visualisations.R](R/build_visualisations.R) (lines 720+).
- [ ] Add `fig_topic_sizes` (cheap, useful as a retune diagnostic).
- [ ] Replace `viz_scores_long` with the slim alternative (see §1).
- [ ] Decide on `viz_score_summary_tbl` / `viz_score_quantiles_tbl`
  rename → `tbl_score_summary` / `tbl_score_quantiles` for fig_/tbl_
  consistency (already done for `tbl_topics`).
- [ ] Move table outputs to `output/tables/` (done for `tbl_topics`,
  outstanding for the other inline-knitr tables — those don't write
  files, so only matters if they grow into widget exports).
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
