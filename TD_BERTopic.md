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

## Config (`config.yaml` → `bertopic:` block)

The dual-path layout: each named entry under `bertopic.configs:` produces
its own `(config, bertopic, variant)` hive partition under
`output/TCAC_2.0/topics/`, so multiple runs coexist on disk for
comparison. `bertopic.active_local` and `bertopic.active_runpod` pick
which config feeds the two pipeline targets.

```yaml
bertopic:
  active_local:   default_local
  active_runpod:  default_runpod
  active_for_viz: default_local         # which run feeds the report

  configs:
    default_local:  { method: local,  ... }
    default_runpod: { method: runpod, ... }
```

### Parameter reference

Every parameter under each named config, with current default and reasoning.
Path A (`default_local`) fits on a sample; Path B (`default_runpod`) fits on
the full corpus. Same parameter names, different scale-appropriate values.

| Parameter | Path A default | Path B default | Why this value? Why is it different? |
|---|---|---|---|
| `method` | `local` | `runpod` | Dispatcher key; selects R wrapper / Python script pair. |
| `sample_size` | `200000` | *(n/a — full fit)* | Path A fits BERTopic on a uniform random sample of this size + all keypapers, then transforms the rest via `approximate_predict`. 200K is the largest sample that fits the laptop's RAM budget while still anchoring keypaper neighborhoods reasonably. Path B uses the full 4.6M-row primary variant on the L40S — no sampling needed. |
| `umap_n_components` | `5` | `5` | BERTopic standard for clustering UMAP; balances information preservation against HDBSCAN's curse-of-dimensionality at higher dims. (The viz UMAP is separately 2-D.) |
| `umap_n_neighbors` | `15` | `30` | UMAP's locality knob. At 200K (Path A), `15` keeps clusters tight enough that HDBSCAN can separate fine-grained topics. At 4.6M (Path B), `30` preserves more global structure without exploding compute; with more data the larger neighborhood is statistically stable. |
| `umap_min_dist` | `0.0` | `0.0` | BERTopic standard — tight clusters in the reduced space so HDBSCAN finds them. |
| `umap_metric` | `cosine` | `cosine` | SPECTER2 was trained with cosine similarity; matches the embedding geometry. |
| `hdbscan_min_cluster_size` | `25` | `500` | Smallest cluster HDBSCAN will keep; smaller values yield more, finer topics. Scales roughly as 0.01% of the fitted population: `200K → ~25`, `4.6M → ~500`. Path A's `25` was the smallest value that didn't trigger the c-TF-IDF "max_df < min_df" error in early iteration; higher values produced too few topics. Path B's `500` is a starting point — expect to tune to 200–1000 based on the first result. |
| `hdbscan_min_samples` | `5` | `50` | HDBSCAN's noise tolerance — points without at least this many neighbors within the cluster-size neighborhood are labelled noise. Scales with `min_cluster_size`. |
| `top_n_words` | `15` | `15` | c-TF-IDF returns the top N terms per topic. 15 is readable for the topic table in the report (10 is terse, 25 is noisy). |
| `keypaper_threshold` | `3` | `3` | A topic is `is_relevant = TRUE` when it contains ≥ N keypapers. With 105 keypapers spread over ~200–1500 topics, ≥3 keypapers per "TCAC-relevant" topic is a defensible weak signal. Original pilot used 2 (too lenient at scale, every random co-occurrence triggered it); 5 was tried and excluded genuine signal. |
| `primary_variant` | `title_abstract` | `title_abstract` | The richer of the two embedding variants — works that have both fields produce vectors that capture topical structure best. |
| `fallback_variant` | `title` | `title` | For corpus rows without abstracts (~20%), use the title-only embedding to assign a topic via UMAP transform. Set to `null` to leave those works un-clustered. |
| `vectorizer_min_df` | `2` | `2` | CountVectorizer's "word must appear in ≥ N documents". **BERTopic applies the vectorizer to per-topic concatenated text**, so "documents" here = number of topics, not corpus size. With ~200–1500 topics, `min_df=2` keeps real terms while filtering true singletons. Earlier values of 10 caused sklearn errors when HDBSCAN produced too few topics. |
| `vectorizer_max_df` | `0.95` | `0.95` | "Word must appear in ≤ N% of documents". `0.95` filters near-universal terms (stop words, generic methodology jargon) without losing real topic-distinguishing words. Earlier value of `0.5` was too aggressive at the per-topic-document scale. |
| `vectorizer_max_features` | `20000` | `20000` | Vocabulary cap. Bounds c-TF-IDF memory regardless of corpus size. 20K is the upper end of useful vocabulary for English scientific text. |
| `vectorizer_ngram` | `[1, 2]` | `[1, 2]` | Unigrams + bigrams. Bigrams produce more readable topic labels ("transformative change", "global warming") than unigrams alone. Trigrams add little signal and a lot of vocabulary explosion. |
| `random_seed` | `13` | `13` | Reproducibility. UMAP + HDBSCAN are deterministic given the seed; re-running the same cfg produces byte-identical outputs. |

### Path B specific transport fields

Only on `default_runpod`:

| Field | Default | Why |
|---|---|---|
| `ssh_host` | `<pod-id>.ssh.runpod.io` | Filled in after the pod is up — RunPod assigns the host on boot. |
| `ssh_port` | `22` | Standard SSH; the docker/bertopic-runpod image exposes it on TCP/22. |
| `ssh_user` | `root` | RunPod containers run as root. |
| `ssh_key_path` | `~/.ssh/id_ed25519` | Used by `R/run_bertopic_runpod.R` for both rsync upload and the ssh-triggered run. Must match the key pasted into the pod template's `PUBLIC_KEY` env var. |
| `remote_workdir` | `/work` | Volume-mounted dir on the pod where embeddings get rsync'd to and where the GPU script writes its outputs. |

### Tuning workflow

1. Edit a param in `config.yaml`.
2. `targets::tar_make(names = "topics_tcac20_local")` (or `_runpod`).
3. The marker file stores a xxhash64 of the cfg; the skip-guard sees the
   hash changed and dispatches a fresh run.
4. No manual leaf wipe needed between iterations.

Swapping `active_for_viz` between runs is free — both named runs persist
on disk and the report just picks whichever is set.

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
