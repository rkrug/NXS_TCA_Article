# TD — BERTopic Clustering Pipeline

Companion technical doc to [TD_Vectorisation.md](TD_Vectorisation.md). Describes
the topic-modelling layer that sits on top of the SPECTER2 embeddings.

## Context

Inspection of the pilot UMAP shows that the per-work scalar score (max cosine
to any keypaper) is a poor relevance filter on its own — the embedding contains
topical structure (visible as clusters) that gets lost when reduced to a single
number. The cluster-level view in the UMAP suggests works are reliably grouped
by topic, and **keypapers co-locate with on-topic clusters**. A clustering
layer on top of the existing SPECTER2 embeddings can leverage that structure to
produce:

1. Human-readable topic labels per cluster (via c-TF-IDF on the cluster's
   cleaned text)
2. A per-cluster "is on-topic" flag derived from keypaper membership
3. A relevance signal that depends on cluster membership, not just point-wise
   cosine

The canonical tool is **BERTopic** (Grootendorst, 2022, arXiv:2203.05794) —
`embeddings → UMAP → HDBSCAN → c-TF-IDF`. We already have SPECTER2 embeddings,
UMAP code, and the keypaper layer, so most of the work is the HDBSCAN
clustering and the topic-word extraction.

This first pass runs on the pilot (1000 corpus + 141 keypapers, `title_abstract`
variant with title fallback for no-abstract works). All R-side code is
structured so it can later become an exported function in `openalexVectorComp`;
all Python code mirrors the location of the existing
`scripts/prepare_specter2_merged.py`.

## References

1. Grootendorst, M. (2022). *BERTopic: Neural topic modeling with a class-based
   TF-IDF procedure.* arXiv:2203.05794. <https://arxiv.org/abs/2203.05794>
2. Angelov, D. (2020). *Top2Vec: Distributed representations of topics.*
   arXiv:2008.09470. <https://arxiv.org/abs/2008.09470>
3. Campello, R. J. G. B., Moulavi, D., & Sander, J. (2013). *Density-Based
   Clustering Based on Hierarchical Density Estimates.* PAKDD 2013.
4. McInnes, L., Healy, J., & Melville, J. (2018). *UMAP: Uniform Manifold
   Approximation and Projection for Dimension Reduction.* arXiv:1802.03426.
5. Egger, R., & Yu, J. (2022). *A Topic Modeling Comparison Between LDA, NMF,
   Top2Vec, and BERTopic to Demystify Twitter Posts.* Front. Sociol. 7.

## Architecture (mirrors existing SPECTER2 / TEI pattern)

```
scripts/run_bertopic.py     standalone Python; reads + writes parquet
                            via pyarrow (matches prepare_specter2_merged.py)
R/run_bertopic.R            R wrapper that calls the python via system2()
_targets.R                  new tar_target(topics_tcac20) using run_bertopic()
TCAC 2.0 Vectorisation.qmd  new "Topics" section consuming topics.parquet
```

The Python script's CLI takes input embedding paths, output dir, and a path to
`config.yaml`. It does not import any R artifacts; it depends only on
`bertopic`, `pyarrow`, `pandas`, `numpy`, `pyyaml`. This is what makes it
directly droppable into `openalexVectorComp/inst/scripts/`.

## Pipeline

```
[input]  output/TCAC_2.0/embeddings/config=SPECTER2/                 (existing)
            source=corpus/variant=title_abstract/  *.parquet
            source=keypaper/variant=title_abstract/ *.parquet
            source=corpus/variant=title/  *.parquet           (for fallback)
                                                  ┃
                                                  ▼
            ┌──────────────────────────────────────────────────────┐
            │  scripts/run_bertopic.py                              │
            │  1. read both partitions of primary variant           │
            │     (V1..V768, id, title_clean, abstract_clean)       │
            │  2. fit UMAP (n_components=5, cosine)                 │
            │  3. fit HDBSCAN                                       │
            │  4. c-TF-IDF on cleaned text per topic                │
            │  5. transfer no-abstract works via fallback variant   │
            │  6. count keypapers per topic; mark is_relevant       │
            │  7. write 3 parquets                                  │
            └──────────────────────────────────────────────────────┘
                                                  ┃
                                                  ▼
[output] output/TCAC_2.0/topics/config=SPECTER2/variant=title_abstract/
            topics.parquet      id, source, topic_id, probability,
                                topic_source ∈ {embedding, transfer}
            topic_info.parquet  topic_id, label, top_words (list),
                                n_corpus, n_keypapers, is_relevant
            topic_words.parquet topic_id, word, weight, rank (long form)
                                                  ┃
                                                  ▼
[consume] TCAC 2.0 Vectorisation.qmd — new "Topics" section
            • Table of topics sorted by keypaper density, with auto-labels
            • UMAP rendered again (cheap, cached) coloured by topic_id
            • Per-relevant-topic top-5 corpus titles for sanity-check
```

## Variant strategy (handles the ~20 % of works with no abstract)

**Approach (A): fit on `title_abstract`, transfer to no-abstract works via
their `title` embedding.**

1. **Fit phase** (BERTopic UMAP + HDBSCAN) uses only the `title_abstract`
   embeddings (corpus + keypapers).
2. **Topic centroids** are computed per cluster in the 5D UMAP space.
3. **Transfer phase**: for corpus works that exist in the `title` variant but
   not in `title_abstract`, take their *title* embedding, apply the same fitted
   UMAP (`umap_model.transform(...)`), and assign the topic via
   `HDBSCAN.approximate_predict`.
4. Output table flags each row's `topic_source` ∈ {`embedding`, `transfer`}
   so downstream consumers know which assignments are lower-confidence.

Both embeddings come from the same SPECTER2 model and live in the same 768-D
space, so nearest-centroid transfer is mathematically sensible.

## Config (`config.yaml` → `clustering:` block)

```yaml
clustering:
  # UMAP for cluster space (separate from the 2D vis UMAP in the report)
  umap_n_components: 5
  umap_n_neighbors:  15
  umap_min_dist:     0.0
  umap_metric:       cosine

  # HDBSCAN
  hdbscan_min_cluster_size: 10
  hdbscan_min_samples:      5

  # Topic representation
  top_n_words:        10        # for c-TF-IDF labels
  keypaper_threshold: 2         # topic is "relevant" if it contains ≥ N keypapers

  # Variant + fallback strategy
  primary_variant:  title_abstract
  fallback_variant: title       # null disables transfer; works without primary stay topic = -1

  # Reproducibility
  random_seed: 42
```

| Knob | Rationale |
|---|---|
| `umap_n_components: 5` | Clustering deserves more dimensions than the 2D vis UMAP. BERTopic default. |
| `umap_metric: cosine` | Matches the embedding space metric. |
| `hdbscan_min_cluster_size: 10` | At ~1140 pilot points, 10 ≈ 1 % yields ~30–80 topics. |
| `keypaper_threshold: 2` | Single keypaper could be noise; two is a deliberate signal. |
| `primary_variant` / `fallback_variant` | Implements approach (A) above. |

## Files

| Path | Action | Note |
|---|---|---|
| `scripts/run_bertopic.py` | New | Standalone Python; eventual home: `openalexVectorComp/inst/scripts/` |
| `R/run_bertopic.R` | New | R wrapper; eventual home: `openalexVectorComp/R/` |
| `_targets.R` | +1 target | `topics_tcac20` after the score targets |
| `config.yaml` | +1 block | `clustering:` |
| `TCAC 2.0 Vectorisation.qmd` | +1 section | `# Topics` |
| `scripts/README.md` | +1 line | `./.venv/bin/pip install bertopic` |

## Prerequisites

- `.venv` exists at the repo root.
- One-time: `./.venv/bin/pip install bertopic` (pulls hdbscan + umap-learn +
  scikit-learn transitively).
- TEI server can be off — this step uses pre-computed embeddings, no API
  needed.

## Scaling to the full corpus

The script is embedding-source-agnostic — it accepts any Arrow dataset with
`V1..Vd` columns. Specific knobs that change between 1k and 4M:

- **UMAP fit**: with 4M points, swap `umap-learn` for `cuml.UMAP` (RAPIDS, GPU)
  or use a `parametric_umap` model. One-line backend swap behind a CLI flag.
- **HDBSCAN fit**: switch to `cuml.HDBSCAN` (GPU). Raise
  `min_cluster_size` heuristic to `max(50, 0.0005 × N)`.
- **Memory**: load embeddings in batches via Arrow's `Scanner`.
- **c-TF-IDF**: `sklearn`'s `CountVectorizer` is `O(N)`, fine at 4M.

## Verification

1. **Script smoke test** — run `run_bertopic.py` standalone on the pilot
   output and inspect the three parquets directly. Expect 30–80 topics +
   `-1` noise topic.
2. **R wrapper** — `tar_make(names = "topics_tcac20")` should complete in
   under 2 minutes on the pilot.
3. **Sanity check on cluster–keypaper alignment** — topics with the highest
   `n_keypapers` should have top words matching obvious TCAC themes
   (biodiversity, transformative, governance, …).
4. **Visual** — render the QMD; the new UMAP coloured by topic should show
   coloured patches roughly matching the contour underlay, with red keypaper
   triangles concentrated in just a few colour patches.
5. **DAG** — `tar_visnetwork()` confirms `topics_tcac20` depends on
   `emb_tcac20` and `emb_keypapers`, and `report_vectorisation` depends on
   `topics_tcac20`.
