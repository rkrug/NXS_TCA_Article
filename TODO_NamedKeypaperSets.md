# TODO — Named Keypaper Sets

Design for supporting multiple, named, simultaneously-coexisting
keypaper sets so the TCAC 2.0 corpus can be re-assessed against
different "definitions of relevance" (transformative change,
imagination, sustainability, …) without losing prior results.

Not implemented. This file captures the agreed-on design so the work
can land cleanly when the case for it materialises (i.e. when at
least one non-`keypaper_tcac10` set is ready to test against the
corpus).

Companion to [TODO_BERTopicStageCaching.md](TODO_BERTopicStageCaching.md)
which already established R2 stage caching keyed by content hashes —
that work makes per-set runs cheap (~5-10 min each, once cached).

## Why this is needed

The TCAC 2.0 corpus is fixed; the research question that drives the
paper is *"how does this corpus look from different definitions of
relevance?"*. Right now there's a single hardcoded keypaper input
(`input/key papers/key_papers_TCAC_1.0.rds`). Switching to a different
keypaper set today means manually swapping the input file and
overwriting the previous outputs — both unsafe and uncomfortable for
side-by-side comparison.

After this work:

- Multiple keypaper sets coexist in `config.yaml`.
- Each set's outputs live under their own `keypaper_set=<name>` hive
  partition — no overwriting.
- The R2 stage cache (UMAP + HDBSCAN + c-TF-IDF + Fallback) is fully
  shared across sets, since those stages depend only on the corpus.
- Switching sets = ~5-10 min and ~$0.30 per dispatch (just the
  keypaper-projection step).

## Config structure

Plural `keypapers:` for consistency with `embeddings:` /
`bertopic.configs:`. Active-pointer pattern mirrored from
`bertopic.active_runpod`.

```yaml
keypapers:
  active:           keypaper_tcac10    # which set drives current dispatch
  active_for_viz:   keypaper_tcac10    # which set the report consumes

  sets:
    keypaper_tcac10:
      path:        input/key papers/key_papers_TCAC_1.0.rds
      format:      rds
      description: |
        Canonical TCAC 1.0 keypapers (~105 DOI-resolved papers).
        Inherited from TCAC 1.0; the baseline for all comparison work.

    keypaper_imagination:
      path:        input/key papers/key_papers_imagination.csv
      format:      csv
      description: |
        Curated set on imagination, social imaginaries, speculative
        futures. ~30-50 entries including grey literature with
        synthetic ids.

    keypaper_sustainability:
      path:        input/key papers/key_papers_sustainability.json
      format:      json
      description: |
        Sustainability transitions seed corpus, hand-compiled.
```

`active` and `active_for_viz` stay independent on purpose: lets you
dispatch a new set's pipeline (so it ends up cached + on disk) while
the report continues to consume the previous set's outputs. Stale
data in a dependency is fine because both leaves are always
materialised.

Supported `format` values: `rds`, `csv`, `json`. New formats can be
added by extending `R/prepare_keypapers.R`'s reader.

## Keypaper table schema

All formats are read into a canonical R data.frame with **four columns
in this order**:

| Column | Required | Type | Description |
|---|---|---|---|
| `id` | ✅ Yes | string | User-provided, must be unique within the set |
| `doi` | ❌ Optional | string | DOI (no URL prefix). Empty if grey literature |
| `title` | ⚠️ Conditional | string | Paper title. May be empty if `doi` is provided AND user wants OpenAlex's title |
| `abstract` | ⚠️ Conditional | string | Paper abstract. Same as title |

### Validation (enforced in `prepare_keypapers()`)

1. `id` must be present in every row.
2. `id` values must be unique within the set (no duplicates).
3. Each row must satisfy: (a) `title` AND `abstract` both non-empty, OR (b) `doi` non-empty (so we can fetch from OpenAlex).
4. If `doi` is present AND `title`/`abstract` are also non-empty: **use user-provided values** (consistent with "user-provided embedding source" principle below).
5. If `doi` is present AND `title` or `abstract` is empty: fetch the missing field(s) from OpenAlex via `openalexPro::pro_fetch()`.

### Example CSV

```csv
id,doi,title,abstract
imag_001,10.1016/j.cosust.2020.04.001,Transformations to sustainability,"Recent work on sustainability transitions..."
imag_002,,Imagined sustainable futures (grey literature),"A position paper that articulates a vision..."
imag_003,10.1126/science.xyz,,                                                                      ← title+abstract from OpenAlex
imag_004,10.1038/example.2021,Speculative methods,,                                                  ← only abstract from OpenAlex
```

### Example RDS

For backwards compatibility with the existing TCAC 1.0 set (currently
a character vector of DOIs):

- Single-column DOI vector → wrap into the 4-column schema, synthesise
  `id` as `kpset=<set>/n=<row>` per row, defer title+abstract to
  OpenAlex.
- 4-column data.frame matching the schema → use as-is.

## Embedding-source principle

When a row has both `doi` and `title`+`abstract`, we **always use the
user-provided title+abstract** for embedding via TEI, never refetch
from OpenAlex. Reasons:

1. Consistent treatment of DOI-bearing and DOI-less rows.
2. User gets exactly what they specified.
3. No surprise drift between corpus embedding (which uses OpenAlex's
   snapshot version) and keypaper embedding for the "same" paper.

The DOI is then a **cross-reference label** — useful for "is this
keypaper also in the corpus?" diagnostics but not the embedding source.

## Output path layout — Option A (hive-partitioned, simple)

Add a `keypaper_set=<name>` hive partition wherever keypaper-set-
specific data lives. All other path components unchanged.

```
output/TCAC_2.0/
  embeddings/config=SPECTER2_runpod/
    source=corpus/variant=…/                          ← unchanged (corpus only)
    source=keypaper/
      keypaper_set=keypaper_tcac10/variant=…/         ← per set
      keypaper_set=keypaper_imagination/variant=…/
      ...

  scores/config=SPECTER2_runpod/
    keypaper_set=keypaper_tcac10/scores_title_abstract.parquet
    keypaper_set=keypaper_imagination/scores_title_abstract.parquet
    ...

  topics/config=SPECTER2_runpod/bertopic=default_runpod/variant=title_abstract/
    keypaper_set=keypaper_tcac10/
      topic_info.parquet            ← n_keypapers + is_relevant for THIS set
      topics.parquet                ← corpus assignments + this set's keypaper assignments
      topic_words.parquet           ← byte-identical across sets (cluster vocabulary)
      .topics_complete              ← wrapper marker
    keypaper_set=keypaper_imagination/
      topic_info.parquet
      topics.parquet
      topic_words.parquet
      .topics_complete
```

### Why Option A over a shared/per-set split

- Each set's leaf is **self-contained**: one path → complete topic
  table + topic info + topic words.
- Downstream viz/report code reads one leaf, no joining logic.
- Duplication of `topic_words.parquet` across sets is ~50 MB × N ─
  negligible.
- Simple to delete a set's outputs: `rm -rf .../keypaper_set=<name>/`.

## R2 cache compatibility

The four R2 cache stages (UMAP, HDBSCAN, c-TF-IDF, Fallback) are
**corpus-only** — they hash zero keypaper-related fields. So:

- Same `config=SPECTER2_runpod/umap_cfg=<hash>/` prefix for all sets.
- All four stages cache-hit on every set switch.
- Only Stage 4 (keypaper projection) varies per set, and that's cheap
  (~1-2 min for 50-100 keypapers).

Net cost per set after the first one is cached:

| Stage | Per-set work |
|---|---|
| Embed new keypapers via TEI (laptop or RunPod) | ~30s for 100 papers |
| UMAP cache hit | ~3-5 min (download from R2) |
| HDBSCAN cache hit | ~30s |
| c-TF-IDF cache hit | ~10s |
| Project new keypapers | ~1-2 min |
| Fallback cache hit | ~30s |
| Write outputs | ~1 min |
| **Total** | **~7-10 min, ~$0.30** |

## Pipeline file touch list

| File | Change |
|---|---|
| `config.yaml` | New `keypapers:` block with active pointers + `sets:` map |
| `R/prepare_keypapers.R` | Refactor to: read active set's path, dispatch on format, validate schema (uniqueness, conditional fields), fetch missing title/abstract from OpenAlex for DOI-only rows. Return canonical 4-column data.frame. |
| `_targets.R` | New `keypapers_cfg` target (reads keypapers.active). `emb_keypapers_*` targets gain `keypaper_set=` hive partition in their `out_dir`. `score_keypapers` outputs similarly partitioned. `topics_tcac20_runpod`'s out_dir extends to include keypaper_set partition. |
| `R/embed_works.R` | No change — already accepts `out_dir`; targets just passes a per-set dir. |
| `R/run_bertopic_runpod.R` | Output path: include `keypaper_set=` segment after the variant. Wrapper marker stored at the per-set leaf. |
| `scripts/runpod/run_bertopic_gpu.py` | No change — script writes to `--output-dir` it's told; targets passes the per-set leaf. |
| `R/build_visualisations.R` (viz / fig targets) | Read from active_for_viz set's leaf paths. |
| `TCAC 2.0 Vectorisation.qmd` / `TCAC 2.0 Building.qmd` | No change unless mentioning the active set in captions. |

## Open questions deferred for later

1. **Cross-set comparison viz** — Jaccard overlap of relevant topics,
   heatmap of n_keypapers × topic × set, per-keypaper distance to
   nearest topic centroid. Belongs in `R/build_visualisations.R` as
   its own target once ≥2 sets are populated. Out of scope here.

2. **DOI-corpus cross-reference diagnostic** — "of N keypapers in
   set X, M are also in the OpenAlex corpus (by DOI match)". Useful
   sanity check, ~5 lines in a viz target. Add when convenient.

3. **Renaming the existing `default_runpod` bertopic config to
   reflect the corpus-only character** of UMAP/HDBSCAN/c-TF-IDF. Not
   blocking; cosmetic only.

## When to do this

Triggers (in order of likely arrival):

- First non-`keypaper_tcac10` set is ready and you want to compare.
- Reviewer asks "what if you defined relevance differently?".
- You want to use grey literature or hypothetical-paper descriptions
  as keypapers.

Until then, the current single-input workflow is fine for the TCAC
1.0 baseline.

## Effort estimate

| Piece | Hours |
|---|---|
| `prepare_keypapers.R` refactor + multi-format reader + validation | 2-3 |
| OpenAlex fallback fetch logic | 1 |
| `_targets.R` rewiring with `keypaper_set=` partitions | 2-3 |
| `R/run_bertopic_runpod.R` output-path tweak | 0.5 |
| Viz layer pickup of `keypaper_set` from cfg | 1 |
| Test: build `keypaper_imagination` (or other set), dispatch, compare with `keypaper_tcac10` baseline | 1-2 |
| Documentation + CHANGES entries | 0.5 |
| **Total** | **~1 working day** |

No image rebuild required — all changes are R-side + config.
