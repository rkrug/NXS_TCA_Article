# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**TCAC 2.0** (Transformative Change Assessment Corpus 2.0) is an
R/Python data pipeline that builds and analyses a scientific literature
corpus from the OpenAlex academic database. It extends TCAC 1.0 by:

1. Searching OpenAlex with topic-specific search terms (transformative
   change AND nature), filtering by publication type.
2. Extracting full records from a local OpenAlex snapshot.
3. Computing SPECTER2 embeddings per work and pairwise cosine
   similarity against a curated keypaper set.
4. Clustering the corpus with BERTopic (UMAP + HDBSCAN, RunPod GPU)
   and projecting keypapers into the resulting topic space.

The OpenAlex snapshot used is `RELEASE 2026-01-15`. All metadata is
extracted from this local snapshot (not the live API) to ensure
consistency between TCAC 1.0 and TCAC 2.0.

## Pipeline Architecture

The pipeline is orchestrated with the
[`targets`](https://docs.ropensci.org/targets/) R package. Entry point
is `_targets.R`. Configuration lives in `input/config.yaml`.

### Pipeline stages (each block invalidates independently)

1. **Inputs** (`input/`) — search-term `.txt` files, keypapers `.rds`,
   work-type filter `.csv`, OpenAlex snapshot dir, TCAC 1.0 IDs parquet.
2. **Search-term assembly** — `tfc_st`, `nature_st`, `tca_st`
   (combined as `(nature) AND (transformative change)`).
3. **OpenAlex statistics** — `count_st` (hit counts per individual and
   combined search), `yearly_counts` (publication-year buckets for the
   universe + each search bucket).
4. **Corpus extraction** — `ids_tcac20` from OpenAlex matching the
   combined search + type filter; `corpus_tcac20` (and `corpus_tcac10`)
   from the local snapshot. `keypapers_in_corpus` flags which keypapers
   the search recovered.
5. **Comparison** — `corpus_comparison` (TCAC 1.0 vs 2.0:
   works-per-type, keypaper presence, added/removed/kept per year).
6. **Embeddings** — `embed_works()` produces 6 targets:
   `emb_{tcac20,keypapers}_{title,abstract,title_abstract}`. Backed by
   a self-hosted TEI server with SPECTER2; embeddings stored as parquet
   under `output/TCAC_2.0/embeddings/config=…/source=…/variant=…/`.
   Mirrored to Cloudflare R2 for the RunPod BERTopic dispatch (see
   `scripts/sync_embeddings_to_r2.sh`).
7. **Keypaper similarity** — `score_keypapers()` per variant, chunked
   per parquet file to avoid OOM. Output: `pairwise-cosine.parquet`
   under `output/TCAC_2.0/scores/`.
8. **Topic clustering** — Path B (`topics_tcac20_runpod`): cuml
   UMAP+HDBSCAN on the full corpus, executed on a RunPod GPU pod via
   SSH + R2 (see `docker/bertopic-runpod/` + `R/run_bertopic_runpod.R`).
   Path A (`topics_tcac20_local`) is a CPU subsample-fit fallback,
   currently disabled in config.
9. **Visualisation** — `viz_*_data` / `viz_*_fig` / `tbl_*` targets
   under `R/build_visualisations.R`. Score distributions, UMAP scatter,
   topic overlays, per-keypaper diagnostics. Most consumers read narrow
   slices via arrow pushdown rather than materialising the full corpus.
10. **Reports** — two Quarto reports rendered as `tar_quarto` targets:
    - `report_vectorisation` → `TCAC 2.0 Embedding Report.qmd`
      (corpus stats, embedding quality, keypaper coherence).
    - `report_corpus` → `TCAC 2.0 Corpus Report.qmd`
      (search terms, keypaper coverage, TCAC 1.0 vs 2.0 comparison).

### Key external packages

- **`openalexPro`** — internal package for OpenAlex API queries
  (`pro_query`, `pro_count`, `pro_request`).
- **`openalexSnapshot`** — internal package for snapshot lookup
  (`lookup_by_id`).
- **`openalexVectorComp`** — internal package for embedding /
  similarity orchestration.
- **`arrow`** — parquet I/O, hive-partitioned datasets.
- **`duckdb`** — used inside `score_keypapers()` for streaming
  computation and inside `get_yearly_counts()` for group-by-year.
- **`keyring`** — stores the OpenAlex Pro API key; retrieved via
  `keyring::key_get("API_openalex")`.
- **`targets`** / **`tarchetypes`** — pipeline orchestration + Quarto
  render targets.
- **`renv`** — package dependency management.

### Inputs (`input/`)

- `input/config.yaml` — all pipeline parameters (active embedding
  config, BERTopic configs, viz knobs).
- `input/search terms/tfc_TCAC_2.0.txt` — transformative change
  search term.
- `input/search terms/nature_TCAC_2.0.txt` — nature search term.
- `input/openalex_types.csv` — OpenAlex work types, with `Included`
  column controlling the type filter.
- `input/key papers/key_papers_TCAC_1.0.rds` — curated keypaper set
  (DOI list inherited from TCAC 1.0).
- `input/TCAC_1.0/ids.parquet` — TCAC 1.0 OpenAlex IDs, for the
  TCAC 1.0 corpus extraction used in the comparison.
- `input/snapshot/` — local OpenAlex snapshot (large; not in git).

### Outputs (`output/`)

- `output/TCAC_2.0/corpus/` — full TCAC 2.0 records extracted from
  the snapshot.
- `output/TCAC_1.0/corpus/` — same for TCAC 1.0.
- `output/keyworks/` — keypaper metadata (parquet/json/jsonl).
- `output/TCAC_2.0/embeddings/` — hive-partitioned by
  config / source / variant.
- `output/TCAC_2.0/scores/` — pairwise-cosine parquets per variant.
- `output/TCAC_2.0/topics/` — BERTopic outputs hive-partitioned
  config / bertopic-name / variant.
- `output/figures/` — static PNG figures (one per `viz_*_fig`).
- `output/tables/` — table HTML widgets (`tbl_*`).
- `output/search_strings/` — search-hit counts + yearly counts.

## Common Commands

```bash
# Run the full targets pipeline
make tar-make

# See which targets are out of date
make tar-outdated

# Visualize the pipeline as a network graph
make tar-visnetwork

# Force-rebuild everything
make tar-invalidate && make tar-make

# Remove all target outputs
make tar-clean

# renv: restore packages from lockfile
make renv-restore

# renv: snapshot current package state
make renv-snapshot
```

Single target interactively:

```r
targets::tar_make(names = "corpus_tcac20")
targets::tar_load(corpus_tcac20)
```

Render a report directly (bypass tar_quarto):

```r
quarto::quarto_render("TCAC 2.0 Corpus Report.qmd")
```

## Notes

- The OpenAlex API key must be set in the system keyring:
  `keyring::key_set("API_openalex")`. The pipeline copies it into
  `Sys.getenv("openalexPro.apikey")` at the top of `_targets.R`.
- `workers` parameter (default 8 in `input/config.yaml`) controls
  parallel API requests.
- `_targets/` and most of `output/` are gitignored. Tracked outputs:
  the rendered `*Report.html` files, the ID parquet under
  `output/TCAC_2.0_ids/` (when populated), and `output/keyworks/parquet/`.
- BERTopic Path B requires a running RunPod pod from
  `ghcr.io/rkrug/bertopic-runpod:v0.1.13`. See
  `docker/bertopic-runpod/README.md`.
- The embedding TEI server is also a RunPod pod (or local Metal); host
  defined under `embeddings.configs.<active>` in `input/config.yaml`.

## Standing TODOs

See `NEXT_STEPS.md` for current state, and these per-topic design notes:

- `TODO_Visualisations.md` — principles + backlog for the figure layer.
- `TODO_NamedKeypaperSets.md` — design for multiple coexisting
  keypaper sets.
- `TODO_BERTopicStageCaching.md` — stage-cache architecture (built).
- `TODO_DetachedDispatch.md` — survive Ctrl-C / sleep during pod runs.
- `TODO_FullCloudMigration.md` — deferred (Phase 2 cloud).
- `TODO_ShinyMigration.md` — deferred (interactive UI).
