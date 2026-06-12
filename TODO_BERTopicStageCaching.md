# TD — BERTopic Stage Caching (future optimisation)

Future-work notes for splitting the monolithic BERTopic pipeline into
cacheable stages, so re-tuning `hdbscan_*` or vectorizer parameters
doesn't trigger a full re-run of the expensive UMAP fit.

Not implemented. This file captures the design so the work can be
picked up cleanly when the iteration cost justifies it.

Companion to [TD_BERTopic.md](TD_BERTopic.md) (architecture),
[TD_BERTopic_Parameters.md](TD_BERTopic_Parameters.md) (per-parameter
reference), and [TD_RunPodSetup.md](TD_RunPodSetup.md) (pod template).

## Why this isn't done today

The current Phase 1 dispatch runs the entire BERTopic pipeline inside
one Python process per invocation:

```
1. Read corpus + keypapers primary variant from R2      (~5-10 min, network + pandas)
2. cuml.UMAP.fit_transform on full corpus               (~30-60 min, GPU)  ← MAIN COST
3. cuml.HDBSCAN.fit on UMAP coords                      (~10-30 min, GPU)
4. c-TF-IDF on per-topic concatenated docs              (~2-5 min,  CPU)
5. Read fallback variant from R2 (streamed anti-join)   (~5-15 min, network)
6. UMAP.transform + HDBSCAN.approximate_predict         (~5-15 min, GPU)
7. Write 3 parquets to /work/out                        (~1 min,    disk)
```

These are all wrapped in `BERTopic.fit_transform(docs, embeddings=X)`
plus a few lines of post-processing. The intermediate state (fitted
UMAP model, HDBSCAN labels, etc.) lives only in pod memory and dies
with the process.

The targets skip-guard is a single binary cfg-hash check on
`bertopic_runpod_cfg`. Any parameter change → whole-pipeline re-run.

## What parameter changes *should* invalidate (granularity)

| Change | Cheapest stage to invalidate from | Cost saved per iteration if cached |
|---|---|---|
| `umap_n_components`, `umap_n_neighbors`, `umap_min_dist`, `umap_metric` | UMAP fit | nothing — UMAP is the cost itself |
| `hdbscan_min_cluster_size`, `hdbscan_min_samples` | HDBSCAN fit | ~30-60 min (skip UMAP) |
| `vectorizer_min_df`, `vectorizer_max_df`, `vectorizer_max_features`, `vectorizer_ngram` | c-TF-IDF | ~40-90 min (skip UMAP + HDBSCAN) |
| `keypaper_threshold`, `top_n_words` | Post-processing — pure CPU, no fit | ~all the compute |
| `random_seed` | Everything | nothing |

The biggest win by far is caching the UMAP fit — it's the single most
expensive stage, and `hdbscan_min_cluster_size` is the most common
parameter to re-tune after seeing first results.

## Proposed refactor

### Python side: one CLI per stage

Split `scripts/run_bertopic_gpu.py` into three sub-commands. Each
reads / writes intermediate state via parquet (or qs2-equivalent for
non-tabular state like the fitted UMAP model).

```
python -m bertopic_pipeline umap-fit \
    --corpus-emb-dir s3://... \
    --reference-emb-dir s3://... \
    --output-dir /work/intermediate \
    --bertopic-cfg-yaml /work/cfg.yaml

→ writes:
    /work/intermediate/umap_model.pkl       # cuml.UMAP fitted model
    /work/intermediate/umap_coords.parquet  # id, V1..V5 (5-D reduced)
```

```
python -m bertopic_pipeline hdbscan-fit \
    --umap-coords-dir /work/intermediate \
    --output-dir /work/intermediate \
    --bertopic-cfg-yaml /work/cfg.yaml

→ reads:
    umap_model.pkl, umap_coords.parquet
→ writes:
    /work/intermediate/topics.parquet       # id, topic_id, topic_source, probability
    /work/intermediate/hdbscan_model.pkl    # cuml.HDBSCAN fitted model (for fallback transform)
```

```
python -m bertopic_pipeline ctfidf \
    --topics-dir /work/intermediate \
    --corpus-emb-dir s3://... \
    --reference-emb-dir s3://... \
    --output-dir /work/out \
    --bertopic-cfg-yaml /work/cfg.yaml

→ reads:
    topics.parquet, umap_model.pkl, hdbscan_model.pkl
    + corpus title/abstract text from R2
→ writes:
    output topic_info.parquet, topics.parquet (final), topic_words.parquet
    + handles fallback variant transform
```

### Intermediate storage — Cloudflare R2

**Decision**: all intermediate state lives in R2 under
`s3://tcac-2-0/intermediate/...`. Same bucket as Phase 1 embeddings;
hive-partitioned with cfg-hash prefixes so parallel runs with
different parameters don't collide.

Why R2 (not pod volume, not laptop):

- **Survives pod termination.** A re-tune on a fresh pod reads the
  previous run's UMAP cache without any local state.
- **Multi-machine friendly.** Multiple researchers / multiple pods
  all read from the same canonical cache.
- **Reuses Phase 1 infra.** Same bucket, same credentials, same
  duckdb/rclone tooling. No new pieces.
- **Cheap.** ~3 GB per cached fit at $0.015/GB-month → ~$0.05/month
  per cached fit. Even 20 mixed-parameter iterations stay under
  $0.30/month. Trivially below the compute savings.
- **No upload cost.** R2 has zero egress; pod-to-R2 write bandwidth
  is ~50-100 MB/s, so a 2-3 GB intermediate upload is ~30-60 s.

Rejected alternatives:

- **RunPod Network Volume**: locks the cache to one pod template;
  doesn't survive volume detach; can't be shared across machines.
- **rsync to laptop**: bandwidth-intensive (2-3 GB per stage) over
  residential uplinks; ties the cache to one machine.

### R2 layout

```
s3://tcac-2-0/intermediate/
  config=SPECTER2_runpod/                  # embedding config
    umap_cfg=<umap-hash>/                  # hash of UMAP-only cfg subset
      umap_model.pkl                       # cuml.UMAP fitted model (~2 GB)
      umap_coords.parquet                  # id, V1..V5 (~80 MB)
      meta.json                            # cfg dump, fit timestamp, image SHA

      hdbscan_cfg=<hdbscan-hash>/          # hash of UMAP+HDBSCAN cfg subset
        hdbscan_model.pkl                  # cuml.HDBSCAN fitted model (~700 MB)
        topics.parquet                     # id, topic_id, prob (~90 MB)

        ctfidf_cfg=<ctfidf-hash>/          # hash of UMAP+HDBSCAN+ctfidf cfg
          topic_info.parquet
          topics.parquet                   # final, includes fallback transfer
          topic_words.parquet
```

Each layer's hash covers the parameters relevant to *that stage and
everything upstream*:

- Change `umap_n_neighbors` → new `umap_cfg=<hash>` prefix; whole
  tree below it re-runs.
- Change `hdbscan_min_cluster_size` only → same `umap_cfg=` prefix,
  new `hdbscan_cfg=<hash>` subprefix; UMAP cache reused.
- Change `vectorizer_max_df` only → same up to `hdbscan_cfg=`, new
  `ctfidf_cfg=<hash>` subprefix.

### Storage cost over time

| Scenario | Total R2 use | $/month |
|---|---|---|
| 1 full fit cached | ~3 GB | $0.05 |
| 1 UMAP + 5 HDBSCAN re-tunes | ~7 GB | $0.11 |
| 1 UMAP + 20 HDBSCAN re-tunes | ~19 GB | $0.29 |
| Add 10 keypaper-swap variants | +1 GB | +$0.02 |

Auto-cleanup via R2 lifecycle rule (30-day TTL on `intermediate/`
prefix) keeps the bucket from growing unboundedly across months:

```bash
rclone backend lifecycle r2:tcac-2-0 \
  set --rule 'prefix=intermediate/,days=30,action=delete'
```

30 days is a comfortable headroom: anything not touched in a month
is unlikely to be reused, and lifecycle deletes are async + free.

### R side: split the target

Replace the current single target with three:

```r
tar_target(
  umap_fit_runpod,
  run_umap_fit_runpod(
    corpus_emb_dir, reference_emb_dir,
    cfg          = bertopic_runpod_cfg_umap,    # only UMAP params + R2
    run_name     = active_runpod
  ),
  format = "file"
),
tar_target(
  hdbscan_fit_runpod,
  run_hdbscan_fit_runpod(
    umap_intermediate = umap_fit_runpod,
    cfg              = bertopic_runpod_cfg_hdbscan,
    run_name         = active_runpod
  ),
  format = "file"
),
tar_target(
  topics_tcac20_runpod,                          # name unchanged; downstream viz still works
  run_ctfidf_runpod(
    hdbscan_intermediate = hdbscan_fit_runpod,
    corpus_emb_dir, reference_emb_dir,           # for fallback transform
    cfg                  = bertopic_runpod_cfg,
    run_name             = active_runpod
  ),
  format = "file"
)
```

Three new `bertopic_runpod_cfg_*` targets, each pulling a subset of
`cfg` so the cfg-hash skip-guard fires at the right granularity:

```r
tar_target(
  bertopic_runpod_cfg_umap,
  cfg <- bertopic_runpod_cfg
  cfg[c("primary_variant", "fallback_variant",
        "umap_n_components", "umap_n_neighbors",
        "umap_min_dist", "umap_metric",
        "random_seed", "r2")]
),
tar_target(
  bertopic_runpod_cfg_hdbscan,
  cfg[c(names(bertopic_runpod_cfg_umap),
        "hdbscan_min_cluster_size", "hdbscan_min_samples")]
)
# ctfidf uses the full bertopic_runpod_cfg
```

### Pod-side workflow on re-tuning

User changes `hdbscan_min_cluster_size`:

1. `bertopic_runpod_cfg_hdbscan`'s hash changes.
2. `bertopic_runpod_cfg_umap`'s hash is unchanged.
3. `tar_outdated()` lists `hdbscan_fit_runpod` + `topics_tcac20_runpod`,
   NOT `umap_fit_runpod`.
4. `tar_make()` dispatches the pod with `--stage hdbscan` only.
5. The pod-side `hdbscan-fit` command:
   - Reads `umap_model.pkl` + `umap_coords.parquet` from R2 (cached from
     prior run).
   - Runs HDBSCAN on those coords with the new params.
   - Writes new `topics.parquet`.
6. `topics_tcac20_runpod` (the `ctfidf` stage) re-runs:
   - Reads new `topics.parquet`.
   - Re-builds per-topic docs.
   - Runs c-TF-IDF.
   - Re-runs fallback transform (uses cached `hdbscan_model.pkl`).
7. Final outputs written; downstream viz targets re-build on top.

Total pod time: ~30-40 min vs ~2-3 h today. **2-4× speedup on every
HDBSCAN re-tune**.

## Implementation considerations

- **Python state serialisation**: `cuml.UMAP` and `cuml.HDBSCAN` need
  pickling. cuml models can be a few hundred MB; verify they round-trip
  cleanly via `pickle` or `joblib`. If they don't, fall back to
  re-fitting on the cached coords (cheaper than re-reading 14 GB
  embeddings but more than zero).
- **Stage-failure recovery**: if the HDBSCAN stage fails mid-run, the
  UMAP cache is intact — next dispatch resumes from HDBSCAN. The
  wrapper just needs to not blindly trust "cfg hash unchanged ==
  output present"; it should verify the actual file existence in R2.
- **Cross-run sharing**: two researchers running with different
  `hdbscan_*` params but same `umap_*` params would naturally share
  the UMAP cache. Multi-tenancy for free.
- **Cache eviction**: intermediate prefixes grow over time. Add an
  rclone-based cleanup script that drops intermediate dirs older than
  N days. ~10 lines of bash.
- **Reproducibility**: the cfg-hash prefix in the R2 path doubles as a
  reproducibility token. Pinning a paper's results = recording the
  hash + image SHA, anyone can re-run from cache.

## When to do this

| Trigger | Action |
|---|---|
| 0-1 BERTopic runs done, undecided on params | Don't refactor — full re-run is fine |
| 1-2 runs done, parameter exploration confirmed needed | Consider refactor — first iteration's savings may not justify a half-day refactor |
| ≥3 runs anticipated with HDBSCAN re-tuning | Do refactor — saves >2 h per future run, pays back in 3-4 iterations |
| Multi-author / multi-machine workflow | Do refactor — UMAP cache sharing is a clean collaboration win |
| **Keypaper-swap workflow** (re-assessing corpus with different keypaper sets / definitions) | **Strong driver — caching becomes essential, see below** |

The full-run cost today is ~$1.50-2.50 in pod time + ~2-3 h wall time.
Refactor breaks even at ~3 HDBSCAN re-tunes.

## Keypaper-swap workflow — the strongest case for stage caching

When the *corpus* is fixed but the *keypaper set* (or definition of
"relevance") changes — e.g., re-assessing the corpus with an
imagination-themed keypaper set, then a sustainability-themed set,
then a transformation-themed set — most of the pipeline doesn't need
to re-run at all.

### What's actually invalidated when you swap keypapers

| Stage | Re-run on keypaper swap? | Why |
|---|---|---|
| Corpus embeddings | ❌ | Same corpus, same model |
| Corpus UMAP coords | ❌ | Same input |
| Corpus HDBSCAN topic_id | ❌ | Same input |
| c-TF-IDF topic words | ❌ | Topic content is a property of the corpus + clustering, not the keypapers |
| Keypaper embeddings | ✓ | Different keypapers → new embeddings (cheap: 50 papers × seconds) |
| `score_keypapers` (cosine corpus ↔ keypapers) | ✓ | New keypapers → new cosines (~few minutes on the laptop) |
| Per-topic `n_keypapers` count | ✓ | New keypapers fall into different topics |
| `is_relevant` flag per topic | ✓ | Re-derived from new `n_keypapers ≥ threshold` |
| Viz / fig targets | ✓ | Highlight different "relevant" clusters |

So: **a keypaper swap should cost minutes, not hours**.

### Design implication

The current BERTopic script *includes keypaper embeddings in the
BERTopic fit* (concatenated with corpus before UMAP+HDBSCAN). This
means a keypaper swap currently invalidates everything because the
cluster boundaries depend on the keypaper set.

For the keypaper-swap workflow to be cheap, the architecture has to
choose:

**Option A — Decouple keypapers from BERTopic fit**
- BERTopic fits only on the corpus (no keypapers in the fit).
- After clustering, keypapers are *projected* into the fitted UMAP
  + HDBSCAN via `umap_model.transform()` + `approximate_predict()`
  (the existing fallback machinery).
- Topic assignment of keypapers is "where do they land in the
  corpus-defined clusters?", not "how do clusters shift to include
  them?".
- `n_keypapers` per topic computed from the projected assignments.

Pros: keypaper swap is essentially free — re-embed + re-project + re-score.
Cons: clusters no longer anchored to keypapers, which may matter
slightly for cluster boundaries near keypaper-dominated topics.

**Option B — Keep keypapers in fit, but stage-cache the fit**
- BERTopic fit includes keypapers, as today.
- Stage caching at the `umap-fit` level invalidates when the
  *corpus+keypaper combined input* changes.
- Keypaper swap → UMAP re-fit + everything downstream. Defeats the
  whole optimisation for swap workflows.

Pros: cluster boundaries reflect keypaper anchoring (current
behaviour).
Cons: keypaper swap is as expensive as a full re-tune.

### Recommendation for the keypaper-swap use case

Adopt **Option A** when implementing stage caching. The keypaper
"anchoring" effect is small at corpus scale (105 keypapers vs 4.6M
corpus rows — keypapers don't meaningfully shift UMAP geometry or
HDBSCAN density boundaries). Projecting keypapers after the fact via
the existing transform machinery gives identical results in practice
and makes the swap workflow trivial.

This also aligns the BERTopic Path A and Path B behaviour with the
keypaper-similarity workflow already in `score_keypapers()` — both
become "corpus is the reference, keypapers are queries to project
into it".

### Workflow example: 3 keypaper sets in one paper

Imagine the paper assesses the corpus against three keypaper sets:
"transformative change", "imagination", "sustainability". With
stage caching + Option A:

1. **Run 1** (transformative change keypapers): full pipeline,
   ~2-3 h, ~$2.
2. **Run 2** (imagination keypapers): only `emb_imagination_*` +
   `scores_imagination_*` + projected `n_keypapers` + viz.
   ~5-10 min, ~$0 (laptop-side).
3. **Run 3** (sustainability keypapers): same as Run 2.
   ~5-10 min, ~$0.

Total: ~3 h + ~$2 for three assessments vs ~9 h + ~$6 without
caching. Bigger than that if you also iterate within each keypaper
set.

### Where each step runs

For Option A, a keypaper swap still requires a brief pod spin-up — the
fitted cuml.UMAP and cuml.HDBSCAN models are GPU-only and can't be
loaded on the laptop (Apple Silicon, no NVIDIA). But the pod time
shrinks from ~2-3 h to ~5 min.

| Step | Where | Why | Cost per swap |
|---|---|---|---|
| Embed new keypapers via TEI | Pod (or local TEI if SPECTER2 config active) | Standard TEI inference | ~1 min for 100 papers |
| Project keypapers into cached UMAP + predict HDBSCAN | Pod | cuml models load only on GPU; re-fitting on laptop CPU would produce different coords | ~seconds |
| Score corpus ↔ keypapers (cosine) | Laptop | Existing `score_keypapers()`; reuses cached corpus embeddings | ~1-2 min |
| Recompute per-topic `n_keypapers` + `is_relevant` | Laptop | Pure dataframe join | seconds |
| Re-render viz / fig | Laptop | Existing | seconds-to-minutes |

**Total per swap**: ~5 min (mostly pod boot + the brief embed+project
run), ~$0.05 in pod time.

The pod-side projection needs a new CLI subcommand alongside the
existing fit: roughly `python -m bertopic_pipeline project-keypapers
--cached-umap s3://... --cached-hdbscan s3://... --keypaper-emb-dir
s3://...`. Trivial wrapper around `umap_model.transform()` +
`hdbscan.approximate_predict()`.

### Named keypaper sets — coexistence on disk

The keypaper-swap workflow assumes prior results stay available for
comparison ("how do papers identified by the imagination keypaper set
overlap with those identified by the transformative-change set?"). So
each keypaper set needs its own persistent output path; runs should
never overwrite each other.

Mirror the existing `bertopic.configs:` named-config pattern. New
config block:

```yaml
keypaper_sets:
  active_for_viz: tcac_10_original     # which set feeds the current report

  sets:
    tcac_10_original:
      source: rds
      path: input/key papers/key_papers_TCAC_1.0.rds
      description: |
        Canonical TCAC 1.0 key papers; ~105 papers.

    imagination_2026:
      source: json                     # title + abstract list of dicts
      path: input/key papers/imagination_2026.json
      description: |
        Curated set on imagination, social imaginaries, speculative
        futures. ~50 papers.

    sustainability_2026:
      source: csv                      # id, title, abstract columns
      path: input/key papers/sustainability_2026.csv
      description: |
        Sustainability transitions corpus seed.

    # Add a new set: drop a json/csv under input/key papers/,
    # add an entry here, flip active_for_viz, re-run.
```

Supported input formats:

| Format | Schema | When to use |
|---|---|---|
| `.rds` | RDS file containing a character vector or list of DOIs | TCAC 1.0 compatibility; resolved via OpenAlex API for metadata |
| `.json` | List of `{title: str, abstract: str, doi: str?}` objects | Hand-curated sets where you have the titles/abstracts already |
| `.csv` | Columns: `id` (DOI or OpenAlex ID), `title`, `abstract` | Spreadsheet-friendly; easy to compile by hand |

For `.json` and `.csv`, the DOI/ID is optional — if absent, the
keypaper is assigned a synthetic ID like `kpset=imagination_2026/n=42`.
This lets you score against hypothetical "what if a paper said
exactly this" definitions, not just real published papers.

### Output layout with named keypaper sets

```
output/TCAC_2.0/embeddings/config=SPECTER2_runpod/
  source=keypaper_set=tcac_10_original/variant=…/*.parquet
  source=keypaper_set=imagination_2026/variant=…/*.parquet

output/TCAC_2.0/scores/config=SPECTER2_runpod/
  keypaper_set=tcac_10_original/scores_*.parquet
  keypaper_set=imagination_2026/scores_*.parquet

output/TCAC_2.0/topics/config=SPECTER2_runpod/
  bertopic=default_runpod/variant=title_abstract/
    keypaper_set=tcac_10_original/
      topic_info.parquet                # is_relevant derived from THIS set
      topics.parquet
      topic_words.parquet
    keypaper_set=imagination_2026/
      topic_info.parquet                # same clusters, different is_relevant
      topics.parquet
      topic_words.parquet
```

Note that under Option A (decouple keypapers from BERTopic fit), the
*clusters themselves* are identical across keypaper sets — only the
`is_relevant`, `n_keypapers`, `top_words_by_keypaper_overlap` columns
differ. The shared expensive bits (UMAP, HDBSCAN, c-TF-IDF on corpus
text) live one level up; only the cheap "score + tag is_relevant"
work duplicates per set.

### Comparison view (cross-keypaper-set)

Once two or more sets have results, a comparison target can compute:

```r
viz_keypaper_set_comparison <- function(topic_info_by_set, ...) {
  # topic_info_by_set: named list of topic_info data frames
  # Compare: which clusters are 'relevant' under set A but not set B?
  #          Jaccard overlap of relevant topic IDs?
  #          Heatmap: keypaper set (rows) x topic_id (cols), values = n_keypapers?
}
```

This is what makes the named-sets pattern pay off — the actual
research question is "how do different definitions of relevance see
this corpus?", and that question only exists if you have multiple sets
on disk.

### What to design now to enable this later

Without doing the full stage caching refactor today, two small habits
keep Option A on the table:

1. **Don't bake "keypapers in fit" into more places**. The current
   coupling lives in `scripts/run_bertopic_gpu.py`. As long as the
   keypaper handling stays localised, switching to a project-after-fit
   model is a single-file refactor.
2. **Treat `is_relevant` as a derived property of (topic assignments +
   keypaper set)**, not a baked-in column of `topic_info.parquet`. The
   topic_info output already computes it inline; keeping it as a
   derivation rather than a cached column means a new keypaper set
   regenerates it without re-running BERTopic.

Both are zero-cost today.

## Alternative: caching at Python-level only

If the targets-level refactor feels too heavy, a lighter approach:

- Keep the single `topics_tcac20_runpod` target.
- Have the Python script check for cached intermediate files at
  `/work/intermediate/` (or R2) and skip stages whose inputs match the
  cfg hash.
- The pod-side script becomes stage-aware; targets remains coarse.

Pros: no `_targets.R` change.

Cons:
- targets' `tar_outdated()` can't reason about intra-stage caching, so
  it'll always show `topics_tcac20_runpod` as needing dispatch when
  cfg changes.
- All-or-nothing from R's perspective; the runtime is much faster but
  R doesn't know that.

A reasonable middle path is to start with the lighter Python-only
approach (preserves cache benefit, no R refactor) and migrate to the
target-level split if the team workflow evolves to need it.

## Open questions for when this becomes real

1. **R2 layout for intermediate**: flat under `s3://tcac-2-0/intermediate/`
   or hive-partitioned like `embeddings/`? Hive matches the existing
   convention.
2. **Cfg hash inputs**: should the embedding `active_embedding` config
   (SPECTER2 vs SPECTER2_runpod) be part of every stage's hash? Yes —
   different embedding model invalidates everything downstream.
3. **Cleanup policy**: 30-day TTL on intermediate? Manual cleanup?
   Probably TTL-based via R2 lifecycle rule.
4. **Pickle vs joblib for cuml models**: which serialises more
   reliably across cuml versions? Verify before committing to one.
5. **Fallback variant strategy**: the fallback transform currently runs
   inside the c-TF-IDF stage. Should it move to its own stage so
   re-tuning c-TF-IDF doesn't re-run the (cheap) fallback? Marginal.
