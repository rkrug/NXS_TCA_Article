# TD — BERTopic Parameter Reference (with citations)

Companion to [TD_BERTopic.md](TD_BERTopic.md) (architecture/design doc) and
[TD_Vectorisation.md](TD_Vectorisation.md) (SPECTER2 embedding pipeline).
This file documents *every* BERTopic-related parameter the TCAC 2.0
pipeline sets, with academic and library-documentation citations for the
choices.

Two paths share almost identical parameters; both are listed side by side
and the rationale for any divergence is noted explicitly.

The configs live under `bertopic.configs.{default_local, default_runpod}`
in [config.yaml](config.yaml). Renaming the `active_local` or
`active_runpod` pointer selects which named config drives
`topics_tcac20_local` / `topics_tcac20_runpod`.

Citation markers like [\[1\]](#ref1) are clickable — they jump to the
[References](#references) section at the bottom of this file.

## Parameter table

Sections grouped by pipeline component. For each parameter:

- **Value (Path A / Path B)** — current config; identical unless noted.
- **Citation(s)** — supporting reference number(s), clickable.
- **Rationale** — why this value, why any difference between paths.

### Top-level dispatcher

| Parameter | Path A | Path B | Citation | Rationale |
|---|---|---|---|---|
| `method` | `local` | `runpod` | — | Dispatcher key. Selects R wrapper + Python script pair; no algorithmic effect. |
| `random_seed` | `13` | `13` | [\[1\]](#ref1) | BERTopic / UMAP / HDBSCAN are deterministic given the seed. Identical seed → byte-identical outputs given identical inputs and library versions. |

### Sample-fit (Path A only)

| Parameter | Path A | Path B | Citation | Rationale |
|---|---|---|---|---|
| `sample_size` | `200000` | — (full) | [\[1\]](#ref1) [\[8\]](#ref8) | Path A fits BERTopic on a uniform random sample of this size plus all keypapers, then transforms the remainder via UMAP+HDBSCAN's `approximate_predict` ([\[1\]](#ref1) §3, [\[8\]](#ref8) "Scaling to large datasets"). 200K is the largest sample the laptop's ~16 GB RAM budget accommodates with cuml-free umap-learn + hdbscan-learn. Path B uses cuml on a GPU and fits the entire 4.6M-row corpus — no sampling. |

### UMAP — dimensionality reduction

UMAP runs on the 768-D SPECTER2 vectors and produces the 5-D space that
HDBSCAN clusters. Same parameter names whether the implementation is
`umap-learn` (Path A) or `cuml.UMAP` (Path B); cuml's API mirrors
sklearn-style UMAP [\[10\]](#ref10).

| Parameter | Path A | Path B | Citation | Rationale |
|---|---|---|---|---|
| `umap_n_components` | `5` | `5` | [\[1\]](#ref1) [\[2\]](#ref2) [\[7\]](#ref7) | BERTopic's canonical clustering UMAP target dimension. [\[1\]](#ref1) uses 5; [\[7\]](#ref7) explicitly recommends 5 for HDBSCAN downstream. Balances information preservation against HDBSCAN's curse of dimensionality at higher dims [\[3\]](#ref3) [\[4\]](#ref4). (The viz UMAP for the 2-D scatter plot is a separate target, also 2-D — `viz_umap_coords_df`.) |
| `umap_n_neighbors` | `15` | `30` | [\[2\]](#ref2) [\[8\]](#ref8) | UMAP locality / global-structure trade-off ([\[2\]](#ref2) §3.4). [\[2\]](#ref2) uses 15 as default; [\[8\]](#ref8) recommends scaling with N for large corpora to preserve global structure. At 200K (Path A), `15` keeps clusters tight enough for HDBSCAN to separate fine-grained topics. At 4.6M (Path B), `30` preserves more global structure without exploding compute; with more data the larger neighborhood is statistically stable. |
| `umap_min_dist` | `0.0` | `0.0` | [\[1\]](#ref1) [\[2\]](#ref2) [\[7\]](#ref7) | BERTopic standard: tight clusters in the reduced space so HDBSCAN's density mode finds them. [\[2\]](#ref2) §3.4 notes `min_dist=0` packs points densely; [\[7\]](#ref7) explicitly recommends 0 when downstream is HDBSCAN. |
| `umap_metric` | `cosine` | `cosine` | [\[2\]](#ref2) [\[5\]](#ref5) [\[11\]](#ref11) | SPECTER and SPECTER2 are trained with a triplet contrastive loss on citation-adjacent papers and induce cosine-similarity geometry in the 768-D space ([\[11\]](#ref11) §3, [\[5\]](#ref5) §2). Matching metric here preserves that geometry under UMAP. |

### HDBSCAN — density-based clustering

HDBSCAN runs on the 5-D UMAP output. Path A uses `hdbscan-learn`
[\[3\]](#ref3), Path B uses `cuml.HDBSCAN` [\[10\]](#ref10) which
implements the same algorithm and exposes the same parameter surface.

| Parameter | Path A | Path B | Citation | Rationale |
|---|---|---|---|---|
| `hdbscan_min_cluster_size` | `25` | `500` | [\[3\]](#ref3) [\[4\]](#ref4) [\[8\]](#ref8) | Smallest cluster HDBSCAN will keep; smaller values yield more, finer-grained topics. [\[3\]](#ref3) notes this as the algorithm's primary "what counts as signal" knob. [\[8\]](#ref8) recommends scaling with corpus size — roughly 0.01% of fitted population works well at scale: `200K × 0.0001 ≈ 25`; `4.6M × 0.0001 ≈ 500`. Path A's value was tuned empirically: 25 was the smallest threshold that didn't trigger the c-TF-IDF "max_df < min_df" sklearn error in early iteration (too-few-topics edge case). Path B's `500` is a starting point — expect to tune to 200–1000 once first results land. |
| `hdbscan_min_samples` | `5` | `50` | [\[3\]](#ref3) [\[4\]](#ref4) | Noise tolerance. Points without ≥ N neighbors within the cluster-size neighborhood are labelled noise (`topic_id = -1`). [\[3\]](#ref3) §3 recommends scaling proportionally to `min_cluster_size`; we use `min_cluster_size / 5` heuristically. |
| `cluster_selection_method` (hard-coded) | `eom` | `eom` | [\[3\]](#ref3) | "Excess of Mass" — selects the most stable clusters from the condensed tree. Default for [\[3\]](#ref3); alternative `leaf` produces more, smaller clusters but fragments large stable topics, undesirable here. Hard-coded in `scripts/run_bertopic_*.py`, not exposed as a knob. |
| `prediction_data` (hard-coded) | `True` | `True` | [\[3\]](#ref3) | Required by `hdbscan.approximate_predict` for the transfer phase (Path A) and the fallback variant transform (both paths). |
| `metric` (hard-coded) | `euclidean` | `euclidean` | [\[3\]](#ref3) | HDBSCAN operates on the UMAP-reduced 5-D space, which UMAP outputs in Euclidean coordinates regardless of input metric ([\[2\]](#ref2) §3.2). |

### c-TF-IDF — topic representation (CountVectorizer)

BERTopic's class-based TF-IDF [\[1\]](#ref1) runs after clustering:
documents within each topic are concatenated into one "topic-document",
then sklearn's `CountVectorizer` [\[9\]](#ref9) tokenizes them and a
TF-IDF transform produces the per-topic word weights.

**Critical**: "documents" at this stage = number of topics (typically
200–1500), not corpus rows. `min_df` and `max_df` are evaluated on this
*topic-document scale*, not the per-paper scale.

| Parameter | Path A | Path B | Citation | Rationale |
|---|---|---|---|---|
| `vectorizer_min_df` | `2` | `2` | [\[1\]](#ref1) [\[9\]](#ref9) | Term must appear in ≥ N topic-documents. With ~200–1500 topics, `min_df=2` keeps real terms while filtering true singletons. Earlier values of `10` caused sklearn errors when HDBSCAN produced too few topics on small samples — the per-topic-document scale doesn't tolerate aggressive minimums. |
| `vectorizer_max_df` | `0.95` | `0.95` | [\[1\]](#ref1) [\[9\]](#ref9) | Term must appear in ≤ N% of topic-documents. `0.95` filters near-universal terms (stop words, generic methodology jargon) without removing real topic-distinguishing words. Earlier value of `0.5` was far too aggressive at this scale and stripped useful vocabulary. |
| `vectorizer_max_features` | `20000` | `20000` | [\[9\]](#ref9) | Vocabulary cap. Bounds c-TF-IDF memory regardless of corpus size. 20K is at the upper end of useful English scientific-text vocabulary [\[6\]](#ref6). |
| `vectorizer_ngram` | `[1, 2]` | `[1, 2]` | [\[1\]](#ref1) [\[9\]](#ref9) | Unigrams + bigrams. Bigrams yield more readable topic labels ("transformative change", "global warming") than unigrams alone. Trigrams add little signal and blow up vocabulary. |
| `stop_words` (hard-coded) | `english` | `english` | [\[9\]](#ref9) | sklearn's English stop-list. SPECTER2 was trained on English-language scientific text ([\[5\]](#ref5) [\[11\]](#ref11)); non-English works in the corpus are rare and excluded from topic labelling but still get clustered. |

### Topic representation + post-processing

| Parameter | Path A | Path B | Citation | Rationale |
|---|---|---|---|---|
| `top_n_words` | `15` | `15` | [\[1\]](#ref1) | Number of words returned per topic by c-TF-IDF. 15 is readable in the report's topic table; 10 is terse, 25 is noisy. [\[1\]](#ref1) uses 10–20 in the published examples. |
| `keypaper_threshold` | `3` | `3` | (no formal citation) | A topic is `is_relevant = TRUE` when it contains ≥ N keypapers. Empirical: with 105 keypapers spread over ~200–1500 topics, ≥3 keypapers per "TCAC-relevant" topic is a defensible weak signal. Pilot used 2 (too lenient — random co-occurrences triggered it); 5 was tried and excluded genuine TCAC topics. |

### Variant strategy

Both paths handle the ~20% of works without abstracts via a fallback
embedding variant. See [TD_BERTopic.md](TD_BERTopic.md) §"Variant
strategy" for the full design.

| Parameter | Path A | Path B | Citation | Rationale |
|---|---|---|---|---|
| `primary_variant` | `title_abstract` | `title_abstract` | [\[5\]](#ref5) [\[11\]](#ref11) | The richer of the two SPECTER2 variants — works that have both fields produce vectors that capture topical structure best. Matches SPECTER's training input format (title + `[SEP]` + abstract) ([\[11\]](#ref11) §3.1). |
| `fallback_variant` | `title` | `title` | [\[5\]](#ref5) [\[11\]](#ref11) | For corpus rows without abstracts, use the title-only SPECTER2 embedding to assign a topic via `umap_model.transform(...) → hdbscan.approximate_predict(...)`. Mathematically sensible because both variants come from the same model and live in the same 768-D space. Setting to `null` leaves no-abstract works at `topic_id = -1`. |

### Transport (Path B only)

These don't affect clustering — they configure SSH/data movement between
the laptop and the RunPod pod. With Phase 1 storage migration, the
embedding upload is replaced by R2 reads on the pod; only the cfg-yaml
push and result download still go over SSH.

| Field | Default | Rationale |
|---|---|---|
| `ssh_host` | `<IP>` from RunPod "SSH over exposed TCP" | Direct TCP, not the proxy — proxy has bandwidth caps + no SCP/SFTP support |
| `ssh_port` | `<port>` from RunPod | Dynamic per pod |
| `ssh_user` | `root` | RunPod containers run as root |
| `ssh_key_path` | `~/.ssh/id_ed25519` | Must match the public key in pod template's `PUBLIC_KEY` env var |
| `remote_workdir` | `/work` | Volume-mounted dir on the pod; small cfg yaml + result parquets pass through here |

## Path A vs Path B parameter divergence — at a glance

```
                           Path A           Path B
                           (laptop)         (RunPod GPU)

sample_size                200000           — (full fit)
umap_n_neighbors           15               30
hdbscan_min_cluster_size   25               500
hdbscan_min_samples        5                50

All other algorithmic parameters are IDENTICAL across paths.
```

That's it for genuine algorithmic differences — 4 parameters. Everything
else (UMAP dim/metric/min_dist, c-TF-IDF vectorizer setup,
keypaper_threshold, ngrams, variants, seed) is identical so that Path A
serves as a useful preview of Path B's structure on the same data.

## Notes on reproducibility

- `random_seed = 13` makes UMAP + HDBSCAN deterministic in both paths,
  but **library version pinning matters too**: a different `bertopic`,
  `umap-learn`, `hdbscan`, `cuml`, or `scikit-learn` version may yield
  different cluster IDs / topic labels even with identical seeds and
  inputs. The pinned versions are:
  - Path A: `renv.lock` + `requirements.txt` in `.venv`
  - Path B: `docker/bertopic-runpod/Dockerfile` v0.1.3 +
    `rapidsai/base:24.10-cuda12.5-py3.11` base image.
- Cluster IDs are not stable across runs with different parameters; only
  the **topic content** (top words, member works) is interpretable.
  Comparing across runs should match on top-words overlap, not on topic
  ID.
- For citation-quality reproducibility in the paper, cite the docker
  image's SHA-256 digest, not the `:v0.1.3` tag — tags can be re-pushed.

## Tuning workflow

1. Edit a param under the relevant `bertopic.configs.*` entry in
   [config.yaml](config.yaml).
2. `targets::tar_make(names = "topics_tcac20_local")` (or `_runpod`).
3. The cfg-aware skip-guard (xxhash64 of the sorted cfg list) detects the
   change and dispatches a fresh run automatically. No manual leaf wipe
   needed.
4. Inspect the new leaf under
   `output/TCAC_2.0/topics/config=<X>/bertopic=<run>/variant=<V>/`.
5. Compare to previous runs by listing topic_info.parquet alongside
   prior leaves' versions (they coexist on disk indefinitely).

Swapping `bertopic.active_for_viz` between named runs is free — both
named runs persist on disk and the report just picks whichever the
pointer references.

## References

<a id="ref1"></a>
**[1]** Grootendorst, M. (2022). *BERTopic: Neural topic modeling with a
class-based TF-IDF procedure.* arXiv:2203.05794.
<https://arxiv.org/abs/2203.05794> — primary reference for BERTopic
architecture, c-TF-IDF derivation, and the canonical
`Embeddings → UMAP → HDBSCAN → c-TF-IDF` pipeline this work follows.

<a id="ref2"></a>
**[2]** McInnes, L., Healy, J., & Melville, J. (2018). *UMAP: Uniform
Manifold Approximation and Projection for Dimension Reduction.*
arXiv:1802.03426. <https://arxiv.org/abs/1802.03426> — UMAP paper;
defines `n_components`, `n_neighbors`, `min_dist`, `metric`.

<a id="ref3"></a>
**[3]** McInnes, L., & Healy, J. (2017). *Accelerated hierarchical
density based clustering.* IEEE Data Mining Workshops (ICDMW), pp.
33–42. doi:10.1109/ICDMW.2017.12 — the `hdbscan` Python implementation;
defines `min_cluster_size`, `min_samples`, `cluster_selection_method`.

<a id="ref4"></a>
**[4]** Campello, R. J. G. B., Moulavi, D., & Sander, J. (2013).
*Density-Based Clustering Based on Hierarchical Density Estimates.*
PAKDD 2013. doi:10.1007/978-3-642-37456-2_14 — original HDBSCAN
algorithm.

<a id="ref5"></a>
**[5]** Singh, A., D'Arcy, M., Cohan, A., Downey, D., & Feldman, S.
(2023). *SciRepEval: A Multi-Format Benchmark for Scientific Document
Representations.* EMNLP 2023, arXiv:2211.13308.
<https://arxiv.org/abs/2211.13308> — SPECTER2 paper; justifies cosine
metric for the 768-D embeddings we cluster.

<a id="ref6"></a>
**[6]** Egger, R., & Yu, J. (2022). *A Topic Modeling Comparison Between
LDA, NMF, Top2Vec, and BERTopic to Demystify Twitter Posts.* Frontiers
in Sociology 7. doi:10.3389/fsoc.2022.886498 — empirical comparison;
guides reasonable defaults at corpus scale.

<a id="ref7"></a>
**[7]** Grootendorst, M. (2024). *BERTopic — Best Practices.*
<https://maartengr.github.io/BERTopic/getting_started/best_practices/best_practices.html>
— official guidance on parameter choice. Cited where the pipeline
follows specific recommended values (e.g. `min_dist=0`,
`n_components=5`, vectorizer setup post-clustering).

<a id="ref8"></a>
**[8]** Grootendorst, M. (2024). *BERTopic — Parameter Tuning.*
<https://maartengr.github.io/BERTopic/getting_started/parameter%20tuning/parametertuning.html>
— scaling guidance for `min_cluster_size` vs corpus size.

<a id="ref9"></a>
**[9]** Pedregosa, F., et al. (2011). *Scikit-learn: Machine Learning in
Python.* JMLR 12, 2825–2830 — `CountVectorizer` paper, defines
`min_df`, `max_df`, `max_features`, `ngram_range`, `stop_words`.

<a id="ref10"></a>
**[10]** RAPIDS Development Team. (2024). *cuML — GPU Machine Learning
Algorithms.* <https://docs.rapids.ai/api/cuml/stable/> — GPU
implementations of UMAP and HDBSCAN used in Path B; documents
compatibility with the sklearn / hdbscan / umap-learn APIs that
BERTopic expects.

<a id="ref11"></a>
**[11]** Cohan, A., Feldman, S., Beltagy, I., Downey, D., & Weld, D. S.
(2020). *SPECTER: Document-level Representation Learning using
Citation-informed Transformers.* ACL 2020, arXiv:2004.07180. — the
original SPECTER training objective; SPECTER2 inherits the
citation-based contrastive loss and thus the cosine-metric geometry.

<a id="ref12"></a>
**[12]** Allaoui, M., Kherfi, M. L., & Cheriet, A. (2020). *Considerably
Improving Clustering Algorithms Using UMAP Dimensionality Reduction: A
Comparative Study.* International Conference on Image and Signal
Processing, 317–325. doi:10.1007/978-3-030-51935-3_34 — empirical
evidence that UMAP-then-density-cluster outperforms raw-space density
clustering at scientific-text scale; backs the BERTopic architecture
choice.
