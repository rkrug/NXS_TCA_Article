# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**NXS TCA Article** is an R/Python data pipeline that builds and analyses
a scientific literature corpus from the OpenAlex academic database. It is
a keypaper-swap fork of the upstream `TCAC 2.0` repo
(`/Volumes/GitHub/TCAC 2.0/`), originally built to re-run the
keypaper-dependent stages against a different keypaper set while reusing
the upstream corpus unchanged. That "frozen corpus" premise has since been
superseded (see Fork note below): this repo now builds its own corpus from
two curated IPBES Zotero assessment groups instead.

1. Downloading curated reference lists from two IPBES Zotero assessment
   groups (TCA, NXS) and matching each item to an OpenAlex work by DOI.
2. Extracting full records for the matched works from a local OpenAlex
   snapshot.
3. Computing SPECTER2 embeddings per work and pairwise cosine
   similarity against a curated set of TCA/Nexus concept definitions.
4. Clustering the corpus with BERTopic (UMAP + HDBSCAN, RunPod GPU)
   and projecting the definitions into the resulting topic space.

The OpenAlex snapshot used is `RELEASE 2026-01-15`. All metadata is
extracted from this local snapshot (not the live API) to ensure
consistent, reproducible corpus records.

> **Fork note.** This repo started as a keypaper-swap fork of the
> upstream `TCAC 2.0` repo, reusing its corpus and corpus embeddings
> unchanged as frozen, read-only static inputs. That premise has been
> abandoned: this repo now **builds its own corpus** from two IPBES Zotero
> assessment groups, so corpus and embeddings are live pipeline outputs
> again, not frozen clones:
> - **TCA** assessment Zotero group (id `4589462`, public) and **NXS**
>   assessment literature Zotero group (id `4596166`, private — needs a
>   Zotero API key with group access; see `zotero.api_key_keyring` in
>   `input/config.yaml`) are downloaded via `download_zotero_assessment()`,
>   matched to OpenAlex ids by DOI via `get_ids_from_dois()`, and extracted
>   from the local snapshot via `get_corpus_from_snapshot()`. Each
>   assessment lands in its own hive partition —
>   `output/NXS_TCA_corpus/corpus/assessment={tca,nxs}/` — combined under
>   one `corpus` dataset root.
> - `output/NXS_TCA_corpus/embeddings/config=…/source={corpus,keypaper}/variant=…/`
>   holds both corpus and keypaper embeddings, computed live by
>   `embed_works()`. They must share one `config=` root —
>   `score_keypapers()` requires it.
> - The keypaper set (`key_works` target) now comes from
>   `input/key papers/TCA and Nexus Definitions.csv` (a curated set of TCA/
>   Nexus theory, framework, and methodology definitions, keyed by its own
>   `ID` column) via `prepare_key_definitions()`, not the older
>   `key_papers.csv` / `prepare_key_works()` path (left in place,
>   unreferenced).
> - The old frozen clones (`input/corpus/`,
>   `input/embeddings/config=SPECTER2_runpod/source=corpus/`) and the
>   search-term/types-filter/count/yearly-counts machinery (`tca_st`,
>   `types_filter`, `count_st`, `yearly_counts`, and their backing
>   `R/get_count.R` / `R/get_yearly_counts.R` / `R/assess_search_term.R`)
>   are no longer referenced by `_targets.R` — the corpus is no longer a
>   search-term-defined OpenAlex universe. Old files are left on disk,
>   unreferenced.
> - The R2 bucket is **`nxs-tca-article`**; `r2.embeddings_local_root`
>   points at `output/NXS_TCA_corpus/embeddings`.
> - **TCAC 1.0 has been removed** from this fork (comparison stage, inputs,
>   `compare_corpora()`, and Corpus Report comparison sections).

## Pipeline Architecture

The pipeline is orchestrated with the
[`targets`](https://docs.ropensci.org/targets/) R package. Entry point
is `_targets.R`. Configuration lives in `input/config.yaml`.

### Pipeline stages (each block invalidates independently)

1. **Inputs** (`input/`) — the TCA/Nexus Definitions `.csv` keypaper set,
   OpenAlex snapshot dir, Zotero group ids (`input/config.yaml`).
2. **Zotero download + OpenAlex matching** — `zotero_tca` / `zotero_nxs`
   (`download_zotero_assessment()`, one per IPBES assessment group) →
   `ids_tca` / `ids_nxs` (`get_ids_from_dois()`, DOI → OpenAlex id via the
   live API).
3. **Corpus** — `corpus_tca` / `corpus_nxs` (`get_corpus_from_snapshot()`,
   full records from the local snapshot) land in their own hive partition
   (`assessment=tca` / `assessment=nxs`); `corpus` is a thin target
   combining both into one dataset root for downstream consumers.
4. **Embeddings** — `emb_corpus_{title,abstract,title_abstract}` and
   `emb_keypapers_{…}` are both **live** `embed_works()` (self-hosted TEI +
   SPECTER2) targets writing to
   `output/NXS_TCA_corpus/embeddings/config=…/source={corpus,keypaper}/variant=…/`
   — they must share one `config=` root (`score_keypapers()` requires it).
   Corpus embeddings are mirrored to Cloudflare R2 for the RunPod BERTopic
   dispatch (see `scripts/runpod/sync_embeddings_to_r2.sh`).
5. **Keypaper similarity** — `score_keypapers()` per variant, chunked
   per parquet file to avoid OOM. Output: `pairwise-cosine.parquet`
   under `output/NXS_TCA_corpus/scores/`.
6. **Topic clustering** — Path B (`topics_runpod`): cuml
   UMAP+HDBSCAN on the full corpus, executed on a RunPod GPU pod via
   SSH + R2 (see `docker/bertopic-runpod/` + `R/run_bertopic_runpod.R`).
   Path A (`topics_local`) is a CPU subsample-fit fallback,
   currently disabled in config.
7. **Visualisation** — `viz_*_data` / `viz_*_fig` / `tbl_*` targets
   under `R/build_visualisations.R`. Score distributions, UMAP scatter,
   topic overlays, per-keypaper diagnostics. Most consumers read narrow
   slices via arrow pushdown rather than materialising the full corpus.
8. **Reports** — two Quarto reports, rendered as `tar_quarto` targets and
   copied into `output/reports/`:
    - `report_analysis` → `NXS TCS Article Chapter Analysis Report.qmd`
      (keypaper coherence + the keyset-linkage material, ending in the
      combined Approach × Action heatmap — the manuscript figure).
    - `report_citation_comparison` →
      `NXS TCS Article Citation Method Comparison Report.qmd`
      (regex vs LLM citation extraction).

    The Embedding, Topic Modelling, Corpus and index reports were removed
    along with the targets that fed them.

### Key external packages

- **`openalexPro`** — internal package for OpenAlex API queries
  (`pro_query`, `pro_count`, `pro_request`).
- **`openalexSnapshot`** — internal package for snapshot lookup
  (`lookup_by_id`).
- **`openalexVectorComp`** — internal package for embedding /
  similarity orchestration.
- **`arrow`** — parquet I/O, hive-partitioned datasets.
- **`duckdb`** — used inside `score_keypapers()` for streaming
  computation.
- **`httr2`** / **`jsonlite`** — hand-rolled Zotero API client
  (`download_zotero_assessment()`); no dedicated Zotero R package.
- **`keyring`** — stores the OpenAlex Pro API key
  (`keyring::key_get("API_openalex")`) and the Zotero API key for the
  private NXS group (`zotero.api_key_keyring` in `input/config.yaml`,
  currently `API_zotero_IPBES_spc_corpus`).
- **`targets`** / **`tarchetypes`** — pipeline orchestration + Quarto
  render targets.
- **`renv`** — package dependency management.

### Inputs (`input/`)

- `input/config.yaml` — all pipeline parameters (Zotero assessment group
  ids, active embedding config, BERTopic configs, viz knobs).
- `input/key papers/TCA and Nexus Definitions.csv` — curated set of TCA/
  Nexus theory, framework, and methodology definitions, columns
  `ID, Table code, Theory/framework/methodology, Literal definition,
  Primary approach, Secondary approach`. `prepare_key_definitions()`
  converts this into the standardized `id/title/abstract/link/
  primary_approach/secondary_approach` parquet (`key_works` target) that
  feeds `emb_keypapers_*`, keyed directly by the CSV's own `ID` column.
  Supersedes `input/key papers/key_papers.csv` / `prepare_key_works.R`
  (left in place, unreferenced).
- `input/snapshot/` — local OpenAlex snapshot (large; not in git).
- `input/corpus/`, `input/embeddings/config=SPECTER2_runpod/source=corpus/`
  — old frozen clones from the original fork architecture, no longer
  referenced by `_targets.R` (superseded by the live
  `output/NXS_TCA_corpus/corpus/` / `.../embeddings/` targets below). Left
  on disk, not deleted.

### Outputs (`output/`)

- `output/NXS_TCA_corpus/zotero/assessment={tca,nxs}/` — raw Zotero item
  metadata per assessment group.
- `output/NXS_TCA_corpus/corpus/assessment={tca,nxs}/` — full OpenAlex
  records extracted from the local snapshot, hive-partitioned by
  assessment; `corpus` reads this whole root.
- `output/NXS_TCA_corpus/embeddings/config=…/source={corpus,keypaper}/variant=…/`
  — SPECTER2 embeddings for both the corpus and the keypaper set.
- `output/NXS_TCA_corpus/keypaper/key_works.parquet` — standardized
  keypaper set (see `prepare_key_definitions()` above).
- `output/NXS_TCA_corpus/scores/` — pairwise-cosine parquets per variant.
- `output/NXS_TCA_corpus/topics/` — BERTopic outputs hive-partitioned
  config / bertopic-name / variant.
- `output/figures/` — static PNG figures (one per `viz_*_fig`).
- `output/tables/` — table HTML widgets (`tbl_*`).

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
targets::tar_make(names = "viz_pair_heatmap_appr_act_combined_fig")
targets::tar_load(link_stage1)
```

Render a report directly (bypass tar_quarto):

```r
quarto::quarto_render("NXS TCS Article Chapter Analysis Report.qmd")
```

## Notes

- The OpenAlex API key must be set in the system keyring:
  `keyring::key_set("API_openalex")`. The pipeline copies it into
  `Sys.getenv("openalexPro.apikey")` at the top of `_targets.R`.
- `workers` parameter (default 8 in `input/config.yaml`) controls
  parallel API requests.
- `_targets/` and most of `output/` are gitignored. Tracked outputs:
  the rendered `*Report.html` files.
- BERTopic Path B requires a running RunPod pod from
  `ghcr.io/rkrug/bertopic-runpod:v0.1.13`. See
  `docker/bertopic-runpod/README.md`.
- The embedding TEI server is also a RunPod pod (or local Metal); host
  defined under `embeddings.configs.<active>` in `input/config.yaml`.

## Standing TODOs

The per-topic design notes (`TODO_Visualisations.md`,
`TODO_NamedKeypaperSets.md`, `TODO_BERTopicStageCaching.md`,
`TODO_DetachedDispatch.md`, `TODO_FullCloudMigration.md`,
`TODO_ShinyMigration.md`) were removed with the pipeline prune — they
described BERTopic, the full-corpus viz layer and deferred cloud/Shiny work,
none of which the pipeline still contains. See git history if any of it is
needed again. `NEXT_STEPS.md` predates the prune and is stale.
