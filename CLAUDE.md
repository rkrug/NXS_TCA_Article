# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**TCAC 2.0** (Transformative Change Assessment Corpus 2.0) is an R-based data pipeline that builds a scientific literature corpus from the OpenAlex academic database. It extends TCAC 1.0 by searching OpenAlex with topic-specific search terms (transformative change + nature), filtering by publication type, and extracting full records from a local OpenAlex snapshot.

The OpenAlex snapshot used is `RELEASE 2026-01-15`. All metadata is extracted from this local snapshot (not live API) to ensure consistency between TCAC 1.0 and TCAC 2.0.

## Pipeline Architecture

The pipeline is orchestrated with the [`targets`](https://docs.ropensci.org/targets/) R package. The entry point is `_targets.R`, which:

1. Reads parameters from the YAML front matter of `TCAC 2.0 Building.qmd`
2. Dynamically creates one `tar_target` per parameter (prefixed `param_*`)
3. Defines the remaining pipeline targets

### Key pipeline stages (in order):

| Target | Function | Description |
|---|---|---|
| `key_works` | `prepare_keypapers()` | Fetches key papers (DOIs from TCAC 1.0 RDS) via OpenAlex API |
| `types_filter` | inline | Reads `input/openalex_types.csv`, keeps only `Included == TRUE` types |
| `tfc_st` / `nature_st` / `tca_st` | inline | Loads search term text files and combines with AND |
| `count_st` | `get_count()` | Counts matching works on OpenAlex (saves to `output/serch_strings/count.rds`) |
| `tcac_20_ids` | `get_tcac20_ids()` | Downloads OpenAlex IDs matching the combined search term + type filter |
| `tcac_20_corpus` | `get_corpus_from_snapshot()` | Extracts full records from local snapshot using TCAC 2.0 IDs |
| `tcac_10_corpus` | `get_corpus_from_snapshot()` | Same extraction for TCAC 1.0 IDs (for consistency) |

### Key external packages

- **`openalexPro`**: Internal/custom package for OpenAlex API queries (`pro_query`, `pro_fetch`, `pro_request`)
- **`openalexPro`**: Internal/custom package for OpenAlex snapshot lookup (`lookup_by_id`)
- **`arrow`**: Parquet file I/O for IDs
- **`keyring`**: Stores the OpenAlex API key — retrieved via `keyring::key_get("API_openalex")`
- **`targets`** / **`tarchetypes`**: Pipeline orchestration
- **`renv`**: Package dependency management

### Input files

All inputs live under `input/`:
- `input/search terms/tfc_TCAC_1.0.txt` — transformative change search term
- `input/search terms/nature_TCAC_1.0.txt` — nature search term
- `input/openalex_types.csv` — OpenAlex work types with `Included` column
- `input/key papers/key_papers_TCAC_1.0.rds` — key paper DOIs (character vector, possibly nested list)
- `input/TCAC_1.0/ids.parquet` — TCAC 1.0 OpenAlex IDs
- `input/snapshot/` — local OpenAlex snapshot (large; not in git), must contain `works_id_idx.parquet`

### Output files

- `output/keyworks/` — key papers fetched from OpenAlex (parquet/json/jsonl)
- `output/TCAC_2.0_ids/` — TCAC 2.0 OpenAlex IDs (parquet/json/jsonl)
- `output/TCAC_2.0/corpus/` — full TCAC 2.0 records extracted from snapshot
- `output/TCAC_1.0/corpus/` — full TCAC 1.0 records extracted from snapshot
- `output/serch_strings/count.rds` — work counts per search term combination

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

# renv: restore packages from lockfile (run after cloning or when renv.lock changes)
make renv-restore

# renv: snapshot current package state
make renv-snapshot
```

To run a single target interactively in R:
```r
targets::tar_make(names = "tcac_20_ids")
targets::tar_load(tcac_20_ids)
```

## Notes

- The OpenAlex API key must be set in the system keyring before running: `keyring::key_set("API_openalex")`
- `workers` parameter (default 8) controls parallel API requests via `openalexPro`
- `_targets/` and most `output/` subdirectories are gitignored; only the ID parquet files under `output/TCAC_2.0_ids/` and `output/keyworks/parquet/` are tracked
- The Quarto report (`TCAC 2.0 Building.qmd`) is currently rendered separately from the pipeline (the `tar_render` target is commented out)
- TODO: Add corpus scoring against key papers using `openalexVectorComp`
