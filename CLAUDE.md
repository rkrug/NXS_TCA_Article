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

> **Fork note (`Reimagening_TFC`).** This repo is a keypaper-swap fork of
> the upstream `TCAC 2.0` repo (`/Volumes/GitHub/TCAC 2.0/`). Its purpose
> is to re-run the keypaper-dependent stages against a *different keypaper
> set* while **reusing the upstream corpus and corpus embeddings unchanged**.
> To that end the corpus + corpus-embeddings are treated as **static inputs**,
> not pipeline outputs:
> - `input/corpus/` and `input/embeddings/config=SPECTER2_runpod/source=corpus/`
>   are **APFS clones of the upstream artefacts, frozen read-only**. The
>   targets `corpus_tcac20` and `emb_tcac20_{title,abstract,title_abstract}`
>   are plain `format="file"` targets pointing at those paths — they never
>   recompute. `ids_tcac20`, `pilot_corpus_tcac20`, and the corpus call to
>   `get_corpus_from_snapshot()` were removed. (`embed_works()` /
>   `get_corpus_from_snapshot()` still carry read-only guards as a backstop.)
> - `input/embeddings/config=SPECTER2_runpod/source=keypaper/` is **writable**
>   and stays **live**: `emb_keypapers_*` still run `embed_works(out_dir=
>   "input/embeddings")`, so a changed keypaper set is re-embedded. Corpus and
>   keypaper embeddings share one config dir, which `score_keypapers()`
>   requires. `output/TCAC_2.0/{scores,topics}/` are writable (regenerated).
> - The R2 bucket is **`reimagine-tfc`** — a dedicated full copy (Cloudflare
>   Super Slurper) of upstream's `tcac-2-0` bucket, including both
>   `embeddings/` and the `intermediate/` BERTopic stage cache. Same account
>   /endpoint as upstream, different bucket, so there is no shared-prefix
>   collision: this fork can freely overwrite its own `source=keypaper`
>   objects as the keypaper set changes without touching upstream's data.
>   The BERTopic intermediate cache (keyed by `config=<name>/umap_cfg=<hash>/
>   hdbscan_cfg=<hash>/…`) was copied too, so cache hits are preserved for
>   unchanged UMAP/HDBSCAN params. `r2.embeddings_local_root` points at
>   `input/embeddings` so the RunPod path→s3 translation still resolves.
> - **TCAC 1.0 has been removed** from this fork (comparison stage, inputs,
>   `compare_corpora()`, and Corpus Report comparison sections).

## Pipeline Architecture

The pipeline is orchestrated with the
[`targets`](https://docs.ropensci.org/targets/) R package. Entry point
is `_targets.R`. Configuration lives in `input/config.yaml`.

### Pipeline stages (each block invalidates independently)

1. **Inputs** (`input/`) — search-term `.txt` files, keypapers `.rds`,
   work-type filter `.csv`, OpenAlex snapshot dir.
2. **Search-term assembly** — `tfc_st`, `nature_st`, `tca_st`
   (combined as `(nature) AND (transformative change)`).
3. **OpenAlex statistics** — `count_st` (hit counts per individual and
   combined search), `yearly_counts` (publication-year buckets for the
   universe + each search bucket).
4. **Corpus** — `corpus_tcac20` is a **static input** (`input/corpus`,
   a frozen clone of the upstream corpus; not re-extracted in this fork).
6. **Embeddings** — `emb_tcac20_{title,abstract,title_abstract}` are
   **static input** targets pointing at the frozen corpus-embedding clones
   under `input/embeddings/config=…/source=corpus/variant=…/`.
   `emb_keypapers_{…}` stay **live**: `embed_works()` (self-hosted TEI +
   SPECTER2) writes them to `input/embeddings/…/source=keypaper/…`, so a
   changed keypaper set is re-embedded. Corpus embeddings are mirrored to
   Cloudflare R2 for the RunPod BERTopic dispatch (see
   `scripts/runpod/sync_embeddings_to_r2.sh`).
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
10. **Reports** — Quarto reports rendered as `tar_quarto` targets:
    - `report_embeddings` → `Reimaging TFC Embedding Report.qmd`
      (corpus stats, embedding quality, keypaper coherence).
    - `report_topic_modelling` → `Reimaging TFC Topic Modelling Report.qmd`
      (BERTopic diagnostics, keypaper coverage per topic).

    `Reimaging TFC Corpus Report.qmd` is no longer auto-rendered by the
    pipeline (its `report_corpus` target was removed) — render it
    manually with `quarto::quarto_render("Reimaging TFC Corpus Report.qmd")`
    when needed. Its upstream targets (`count_st`, `yearly_counts`,
    `corpus_tcac20`, `key_works`, etc.) are untouched and may still
    feed other things.

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
- `input/key papers/key_papers.csv` — **fork:** curated keypaper set —
  a mix of academic papers and non-paper "concept" entries (case
  studies, artistic projects, other examples), columns
  title/abstract/link/type. `prepare_key_works()` converts this
  directly into the standardized `id/title/abstract/link/type`
  parquet (`key_works` target) that feeds `emb_keypapers_*` — no
  OpenAlex DOI lookup in this path anymore (superseded
  `get_key_works()` / `key_papers_TCAC_1.0.rds`, which only worked for
  entries with a resolvable DOI).
- `input/corpus/` — **fork:** frozen clone of the upstream TCAC 2.0
  corpus (read-only; consumed as a static input, not in git).
- `input/embeddings/config=…/source={corpus,keypaper}/variant=…/` —
  **fork:** `source=corpus` is a frozen clone (read-only, static input);
  `source=keypaper` is writable and regenerated by `emb_keypapers_*`.
  Not in git.
- `input/snapshot/` — local OpenAlex snapshot (large; not in git).

### Outputs (`output/`)

- `output/keyworks/` — keypaper metadata (parquet/json/jsonl).
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
quarto::quarto_render("Reimaging TFC Corpus Report.qmd")
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
