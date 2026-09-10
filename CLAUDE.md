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
3. Computing embeddings (currently BAAI/bge-large-en-v1.5, see
   `embeddings.active` in `input/config.yaml`) per work and pairwise
   cosine similarity against a curated set of TCA/Nexus concept
   definitions.
4. Linking the TCA/Nexus concept definitions to each other (TCA Approaches
   ↔ TCA Actions) on two independent signals — definition-embedding cosine
   similarity, and overlap of the works each definition cites — combined
   into the Approach × Action heatmap that is the manuscript figure.
   (BERTopic-based topic clustering of the full corpus was explored and
   then removed — see Standing TODOs.)

The OpenAlex snapshot used was `RELEASE 2026-01-15`. Metadata was
extracted from this local snapshot once (not the live API) to ensure
consistent, reproducible corpus records, then frozen as a static input
(see Fork note).

> **Fork note.** This repo started as a keypaper-swap fork of the
> upstream `TCAC 2.0` repo, reusing its corpus and corpus embeddings
> unchanged as frozen, read-only static inputs. That premise was abandoned
> in favour of **building its own corpus** from two IPBES Zotero assessment
> groups — but the corpus-extraction step has since been frozen again too,
> once stable, following the same fork pattern one level further down the
> pipeline (`input/corpus_chapter/`, see below):
> - **TCA** assessment Zotero group (id `4589462`, public) and **NXS**
>   assessment literature Zotero group (id `4596166`, private — needs a
>   Zotero API key with group access; see `zotero.api_key_keyring` in
>   `input/config.yaml`) are downloaded via `download_zotero_assessment()`,
>   matched to OpenAlex ids by DOI via `get_ids_from_dois()`. Each
>   assessment's full records were extracted from the local snapshot via
>   `get_corpus_from_snapshot()` and, once stable, moved into `input/` as a
>   frozen static input — `input/corpus_chapter/assessment={tca,nxs}/` — so
>   `input/snapshot` is no longer a live pipeline dependency.
> - `output/NXS_TCA_corpus/embeddings/config=…/source=keypaper/variant=…/`
>   holds the keypaper-definition embeddings, computed live by
>   `embed_works()` (self-hosted TEI). Full-corpus embeddings, a
>   `source=corpus` partition, and `score_keypapers()` (chapter ↔ keypaper
>   cosine scoring) existed in an earlier iteration of this pipeline but
>   were removed along with the BERTopic/topic-clustering stage — see
>   Standing TODOs.
> - The keypaper set (`key_works` target) comes from the 2 relevant sheets
>   (`TCA_Approaches_3_2`, `TCA_Actions_Ch5`) of
>   `input/TCA and Nexus Definitions-1.xlsx` via `prepare_key_definitions()`,
>   not the older `input/key papers/key_papers.csv` / `prepare_key_works()`
>   path (left in place, unreferenced).
> - The old frozen clones (`input/corpus/`,
>   `input/embeddings/config=SPECTER2_runpod/source=corpus/`) and the
>   search-term/types-filter/count/yearly-counts machinery (`tca_st`,
>   `types_filter`, `count_st`, `yearly_counts`, and their backing
>   `R/get_count.R` / `R/get_yearly_counts.R` / `R/assess_search_term.R`)
>   are no longer referenced by `_targets.R` — the corpus is no longer a
>   search-term-defined OpenAlex universe. Old files are left on disk,
>   unreferenced.
> - **TCAC 1.0 has been removed** from this fork (comparison stage, inputs,
>   `compare_corpora()`, and Corpus Report comparison sections).

## Pipeline Architecture

The pipeline is orchestrated with the
[`targets`](https://docs.ropensci.org/targets/) R package. Entry point
is `_targets.R`. Configuration lives in `input/config.yaml`.

### Pipeline stages (each block invalidates independently)

1. **Inputs** (`input/`) — `input/TCA and Nexus Definitions-1.xlsx` (the
   keypaper/definition set), Zotero group ids (`input/config.yaml`),
   `input/corpus_chapter/` (frozen static corpus, see Fork note).
2. **Zotero download + OpenAlex matching** — `zotero_tca` / `zotero_nxs`
   (`download_zotero_assessment()`, one per IPBES assessment group) →
   `ids_tca` / `ids_nxs` (`get_ids_from_dois()`, DOI → OpenAlex id via the
   live API). Both remain live targets — only the snapshot-extraction step
   downstream of them was frozen.
3. **Corpus** — `corpus_chapter` is a **frozen static input**
   (`input/corpus_chapter/assessment={tca,nxs}/chapter=…/`): full records
   originally extracted from the local OpenAlex snapshot via
   `get_corpus_from_snapshot()`, then moved into `input/` once stable, so
   `input/snapshot` is no longer a live pipeline dependency (see git history
   for the retired `corpus_chapter_tca` / `corpus_chapter_nxs` targets).
4. **Keypapers + citations** — `key_works` (`prepare_key_definitions()`,
   reads the 2 relevant `.xlsx` sheets) feeds `key_citations`
   (`extract_definition_citations()`, deterministic regex — the only
   extractor; an LLM/OpenRouter alternative and the Citation Method
   Comparison report that compared the two were retired, see git history),
   which resolves via `resolve_citations()` against the matching
   assessment's reference library (`zotero_*`/`ids_*`/`corpus_chapter`) into
   `citations_resolved` (aliased as `citations_resolved_active`), feeding
   the Stage 2 signal below.
5. **Embeddings** — `emb_keypapers_title_abstract` is a **live**
   `embed_works()` (self-hosted TEI; active model BAAI/bge-large-en-v1.5,
   see `embeddings.active` in `input/config.yaml`) target, writing to
   `output/NXS_TCA_corpus/embeddings/config=…/source=keypaper/variant=…/`.
   There is no full-corpus embedding target in the current pipeline.
6. **Keyset linkage** — TCA Approaches ↔ TCA Actions, on two independent
   signals (`R/build_linkage.R`): `link_stage1`
   (`build_link_stage1_data()`, definition-embedding cosine) and
   `link_stage2` (`build_link_stage2_data()`, Jaccard overlap of each
   definition's cited-work set). A third, cited-literature-embedding stage
   existed in an earlier iteration and was removed (it needed the
   full-corpus embeddings retired in step 5).
7. **Visualisation** — `viz_*_fig` / `viz_*_data` targets under
   `R/build_visualisations.R`: keypaper self-similarity, Sankeys and
   keyset×keyset matrices per stage, and the three Approach×Action heatmaps
   (stage1 / stage2 / combined — the last is the manuscript figure).
8. **Reports** — three Quarto/markdown documents, rendered as `tar_quarto`
   targets and copied into `output/reports/`, plus a landing page:
    - `report_analysis` → `NXS TCS Article Chapter Analysis Report.qmd`
      (keypaper coherence + the keyset-linkage material, ending in the
      combined Approach × Action heatmap — the manuscript figure).
    - `td_vectorisation` / `td_runpod_setup` → the two `TD_*.md` design
      docs, rendered read-only alongside the report (the `.md` stays the
      source of truth, read on GitHub).
    - `report_index` (`build_report_index()`) — the landing page linking
      all three.

    The Embedding, Topic Modelling, Corpus and Citation Method Comparison
    reports (and the targets that fed them) were removed along with
    BERTopic/full-corpus embeddings and the LLM citation extractor.

### Key external packages

- **`openalexPro`** — internal package for OpenAlex API queries
  (`pro_query`, `pro_count`, `pro_request`).
- **`openalexSnapshot`** — internal package for snapshot lookup
  (`lookup_by_id`).
- **`openalexVectorComp`** — internal package for embedding /
  similarity orchestration.
- **`arrow`** — parquet I/O, hive-partitioned datasets.
- **`duckdb`** — reads the `.xlsx` keypaper sheets (`read_xlsx` extension,
  in `prepare_key_definitions()`) and backs the reference-library lookups
  inside `resolve_citations()`.
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
  ids, active embedding config).
- `input/TCA and Nexus Definitions-1.xlsx` — 2 worksheets
  (`TCA_Approaches_3_2`, `TCA_Actions_Ch5`) of curated TCA/Nexus concept
  definitions. `prepare_key_definitions()` (via duckdb's `read_xlsx`)
  converts these into the standardized `key_works` parquet
  (`output/NXS_TCA_corpus/keypaper/keyset=*`), keyed by each sheet's own
  `ID` column, feeding `emb_keypapers_title_abstract` and the regex citation
  extractor. Supersedes `input/key papers/key_papers.csv` /
  `prepare_key_works.R` (left in place, unreferenced).
- `input/snapshot` — was a symlink to the local OpenAlex snapshot mount
  (large; not in git), no longer read by any active target now that
  `input/corpus_chapter/` (below) holds the frozen result of the one-time
  extraction. Already removed from this checkout.
- `input/corpus_chapter/assessment={tca,nxs}/chapter=…/` — frozen static
  input: full OpenAlex records extracted from `input/snapshot/` via
  `get_corpus_from_snapshot()`, then moved here once stable. Read directly by
  the `corpus_chapter` target (`format = "file"`, no live computation).
- `input/corpus/`, `input/embeddings/config=SPECTER2_runpod/source=corpus/`
  — old frozen clones from the original fork architecture, no longer
  referenced by `_targets.R`. Left on disk, not deleted.

### Outputs (`output/`)

- `output/NXS_TCA_corpus/zotero/assessment={tca,nxs}/` — raw Zotero item
  metadata per assessment group.
- `output/NXS_TCA_corpus/ids/assessment={tca,nxs}/` — DOI → OpenAlex id
  matches.
- `output/NXS_TCA_corpus/keypaper/keyset={TCA_Approaches_3_2,TCA_Actions_Ch5}/`
  — standardized keypaper set (see `prepare_key_definitions()` above; this
  is the `key_works` target's own tracked output).
- `output/NXS_TCA_corpus/citations_extracted/method=regex/keyset=*/`,
  `output/NXS_TCA_corpus/citations_resolved/method=regex/` — inline
  citations extracted from the definitions and resolved against the
  reference libraries (see Pipeline stage 4 above).
- `output/NXS_TCA_corpus/embeddings/config=…/source=keypaper/variant=…/`
  — keypaper-definition embeddings (active model BAAI/bge-large-en-v1.5).
- `output/figures/` — one file per named figure per download format
  (`pair_heatmap_appr_act_combined.{pdf,svg,png,eps}`, etc.);
  `output/reports/figures/` is a tracked copy of the same set alongside the
  rendered reports.

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
- `_targets/` is gitignored. `output/` itself is not (check `.gitignore`
  for the current state before assuming any subfolder is excluded) — at
  minimum the rendered `*Report.html` files under `output/reports/` are
  tracked.
- The embedding TEI server is a RunPod pod (or local Metal); host defined
  under `embeddings.configs.<active>` in `input/config.yaml`.

## Standing TODOs

The per-topic design notes (`TODO_Visualisations.md`,
`TODO_NamedKeypaperSets.md`, `TODO_BERTopicStageCaching.md`,
`TODO_DetachedDispatch.md`, `TODO_FullCloudMigration.md`,
`TODO_ShinyMigration.md`) were removed with the pipeline prune — they
described BERTopic, the full-corpus viz layer and deferred cloud/Shiny work,
none of which the pipeline still contains. See git history if any of it is
needed again. `NEXT_STEPS.md` predated the prune and has been removed.
