#!/usr/bin/env python3
"""
BERTopic clustering — local (CPU) sample-fit + transform-everything mode.

Reads the (config, source, variant)-partitioned embedding parquet dataset,
fits BERTopic on a random sample of the corpus + ALL keypapers in the
primary variant, then projects every remaining corpus work in BOTH the
primary AND the fallback variant onto the fitted UMAP/HDBSCAN model, so
that every corpus work and every keypaper receives a topic_id.

Output (3 parquets + marker stamped by the R wrapper):

    <output_dir>/config=<X>/bertopic=<run_name>/variant=<primary>/topics.parquet
    <output_dir>/config=<X>/bertopic=<run_name>/variant=<primary>/topic_info.parquet
    <output_dir>/config=<X>/bertopic=<run_name>/variant=<primary>/topic_words.parquet

All hyperparameters come from the YAML at --bertopic-cfg-yaml; no script-
level defaults beyond what BERTopic / UMAP / HDBSCAN provide if a knob is
missing. Self-contained — drop into openalexVectorComp/inst/scripts/.

Usage:
    python run_bertopic_local.py \\
      --corpus-emb-dir    <path>/config=<X>/source=corpus \\
      --reference-emb-dir <path>/config=<X>/source=keypaper \\
      --output-dir        <path>/topics \\
      --bertopic-cfg-yaml /tmp/bertopic_cfg.yaml \\
      --run-name          default_local
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pyarrow.dataset as ds
import yaml


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _embedding_columns(table_columns):
    """Names of V1..V<n> embedding columns, ordered by index."""
    ev = [c for c in table_columns if c.startswith("V") and c[1:].isdigit()]
    return sorted(ev, key=lambda c: int(c[1:]))


def _read_source_variant(emb_root: Path, variant: str) -> pd.DataFrame:
    """
    Read all rows for a given variant from a source directory.

    emb_root looks like: .../config=<X>/source=corpus
    """
    variant_dir = emb_root / f"variant={variant}"
    if not variant_dir.is_dir():
        raise FileNotFoundError(f"No partition: {variant_dir}")
    dset = ds.dataset(str(variant_dir), format="parquet")
    cols = dset.schema.names
    keep = ["id", "title_clean", "abstract_clean"]
    keep = [c for c in keep if c in cols] + _embedding_columns(cols)
    return dset.to_table(columns=keep).to_pandas()


def _matrix(df: pd.DataFrame) -> np.ndarray:
    return df[_embedding_columns(df.columns)].to_numpy(dtype=np.float32)


def _docs(df: pd.DataFrame) -> list[str]:
    """Cleaned title + abstract for c-TF-IDF input."""
    title = df.get("title_clean", pd.Series([""] * len(df))).fillna("")
    abstract = df.get("abstract_clean", pd.Series([""] * len(df))).fillna("")
    return (title.astype(str) + " " + abstract.astype(str)).tolist()


def _leaf_dir(out_root: Path, config_name: str, run_name: str,
              primary: str) -> Path:
    p = out_root / f"config={config_name}" / f"bertopic={run_name}" / f"variant={primary}"
    p.mkdir(parents=True, exist_ok=True)
    return p


def _chunked_transform(topic_model, df: pd.DataFrame,
                       chunk_size: int = 50_000) -> np.ndarray:
    """
    Project + predict in chunks so we don't blow up memory on the full
    non-sampled corpus. Returns a 1-D int array of topic_ids aligned with df.
    """
    n = len(df)
    out = np.empty(n, dtype=np.int64)
    docs = _docs(df)
    X = _matrix(df)
    for start in range(0, n, chunk_size):
        end = min(n, start + chunk_size)
        topics_chunk, _probs = topic_model.transform(
            documents=docs[start:end], embeddings=X[start:end]
        )
        out[start:end] = np.asarray(topics_chunk, dtype=np.int64)
        print(f"        transformed {end:,} / {n:,}")
    return out


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--corpus-emb-dir",    required=True)
    p.add_argument("--reference-emb-dir", required=True)
    p.add_argument("--output-dir",        required=True)
    p.add_argument("--bertopic-cfg-yaml", required=True,
                   help="YAML with one config (the BERTopic params), not the full project config")
    p.add_argument("--run-name",          required=True,
                   help="Name of the BERTopic config; becomes the bertopic=<...> path component")
    args = p.parse_args()

    corpus_root = Path(args.corpus_emb_dir).resolve()
    refer_root  = Path(args.reference_emb_dir).resolve()
    out_root    = Path(args.output_dir).resolve()
    cfg_path    = Path(args.bertopic_cfg_yaml).resolve()
    run_name    = args.run_name

    if corpus_root.parent != refer_root.parent:
        sys.exit(
            "corpus and reference must share parent (config dir); got\n"
            f"  corpus:    {corpus_root}\n  reference: {refer_root}"
        )
    config_name = corpus_root.parent.name.split("=", 1)[1]

    with cfg_path.open("r") as fh:
        cl = yaml.safe_load(fh)

    primary     = cl["primary_variant"]
    fallback    = cl.get("fallback_variant")
    seed        = int(cl.get("random_seed", 13))
    sample_size = int(cl.get("sample_size", 200_000))

    print(f"[info] config_name = {config_name}")
    print(f"[info] run_name    = {run_name}")
    print(f"[info] primary     = {primary}    fallback = {fallback}")
    print(f"[info] sample_size = {sample_size:,}    seed = {seed}")

    # ---------- 1. Load primary variant: full corpus + all keypapers --------
    print("[step] reading primary variant for corpus + keypapers")
    df_corpus_p = _read_source_variant(corpus_root, primary)
    df_ref_p    = _read_source_variant(refer_root,  primary)
    df_corpus_p["source"] = "corpus"
    df_ref_p["source"]    = "keypaper"
    print(f"        corpus={len(df_corpus_p):,}  keypaper={len(df_ref_p):,}")

    # ---------- 2. Stratified sample (random corpus + ALL keypapers) -------
    # All keypapers anchor the relevant clusters; a random N from corpus
    # covers the rest of the embedding space well enough at large N. We
    # rely on randomness rather than score-based stratification so this
    # script has no dependency on the scoring stage.
    if sample_size >= len(df_corpus_p):
        df_corpus_fit = df_corpus_p
        print(f"        sample_size >= corpus_size; fitting on all {len(df_corpus_p):,} corpus rows")
    else:
        df_corpus_fit = df_corpus_p.sample(
            n=sample_size, random_state=seed, replace=False
        ).reset_index(drop=True)
        print(f"        fitting on {len(df_corpus_fit):,} corpus rows + {len(df_ref_p):,} keypapers")
    df_fit = pd.concat([df_corpus_fit, df_ref_p], ignore_index=True)

    X_fit    = _matrix(df_fit)
    docs_fit = _docs(df_fit)

    # ---------- 3. Build UMAP + HDBSCAN + BERTopic on the sample -----------
    print("[step] fitting UMAP + HDBSCAN + c-TF-IDF (BERTopic) on sample")
    from bertopic import BERTopic
    from umap import UMAP
    from hdbscan import HDBSCAN
    from sklearn.feature_extraction.text import CountVectorizer

    umap_model = UMAP(
        n_components=int(cl.get("umap_n_components", 5)),
        n_neighbors=int(cl.get("umap_n_neighbors",  30)),
        min_dist=float(cl.get("umap_min_dist",       0.0)),
        metric=cl.get("umap_metric", "cosine"),
        random_state=seed,
    )
    hdbscan_model = HDBSCAN(
        min_cluster_size=int(cl.get("hdbscan_min_cluster_size", 200)),
        min_samples=int(cl.get("hdbscan_min_samples", 50)),
        metric="euclidean",
        cluster_selection_method="eom",
        prediction_data=True,            # required for approximate_predict()
    )
    vectorizer = CountVectorizer(
        stop_words="english",
        min_df=int(cl.get("vectorizer_min_df", 10)),
        max_df=float(cl.get("vectorizer_max_df", 0.5)),
        max_features=int(cl.get("vectorizer_max_features", 20_000)),
        ngram_range=tuple(cl.get("vectorizer_ngram", [1, 2])),
    )

    topic_model = BERTopic(
        embedding_model=None,            # embeddings supplied directly
        umap_model=umap_model,
        hdbscan_model=hdbscan_model,
        vectorizer_model=vectorizer,
        top_n_words=int(cl.get("top_n_words", 15)),
        calculate_probabilities=False,
        verbose=True,
    )

    topics_fit, _probs_fit = topic_model.fit_transform(docs_fit, embeddings=X_fit)
    df_fit["topic_id"]     = topics_fit
    df_fit["topic_source"] = "embedding"
    df_fit["probability"]  = np.nan

    # ---------- 4. Transfer the REST of the corpus (primary variant) -------
    fit_ids = set(df_corpus_fit["id"])
    df_corpus_rest = df_corpus_p[~df_corpus_p["id"].isin(fit_ids)].reset_index(drop=True)
    print(f"[step] transferring {len(df_corpus_rest):,} non-sampled corpus rows (primary)")
    if len(df_corpus_rest):
        topics_rest = _chunked_transform(topic_model, df_corpus_rest)
        df_corpus_rest["topic_id"]     = topics_rest
        df_corpus_rest["topic_source"] = "transferred"
        df_corpus_rest["source"]       = "corpus"
        df_corpus_rest["probability"]  = np.nan
    else:
        df_corpus_rest = df_corpus_rest.assign(
            topic_id=pd.Series(dtype=np.int64),
            topic_source=pd.Series(dtype=str),
            probability=pd.Series(dtype=float),
        )

    # ---------- 5. Fallback variant: corpus works without primary ----------
    df_fb_assignments = pd.DataFrame(columns=["id", "source", "topic_id", "topic_source", "probability"])
    if fallback:
        print(f"[step] reading fallback variant ({fallback}) for corpus")
        df_corpus_fb = _read_source_variant(corpus_root, fallback)
        already = set(df_corpus_p["id"])           # works that DID have primary
        df_corpus_fb = df_corpus_fb[~df_corpus_fb["id"].isin(already)].reset_index(drop=True)
        print(f"        no-primary corpus works to transfer via fallback: {len(df_corpus_fb):,}")
        if len(df_corpus_fb):
            topics_fb = _chunked_transform(topic_model, df_corpus_fb)
            df_corpus_fb["topic_id"]     = topics_fb
            df_corpus_fb["topic_source"] = "fallback"
            df_corpus_fb["source"]       = "corpus"
            df_corpus_fb["probability"]  = np.nan
            df_fb_assignments = df_corpus_fb[["id", "source", "topic_id", "topic_source", "probability"]]

    # ---------- 6. Combine all assignments ---------------------------------
    out_topics = pd.concat(
        [
            df_fit[["id", "source", "topic_id", "topic_source", "probability"]],
            df_corpus_rest[["id", "source", "topic_id", "topic_source", "probability"]],
            df_fb_assignments,
        ],
        ignore_index=True,
    )
    out_topics["topic_id"] = out_topics["topic_id"].astype(np.int64)

    # ---------- 7. Build topic_info + topic_words --------------------------
    info = topic_model.get_topic_info()
    cnt = (
        out_topics.groupby(["topic_id", "source"]).size()
        .unstack(fill_value=0).reset_index()
    )
    if "corpus"   not in cnt.columns: cnt["corpus"]   = 0
    if "keypaper" not in cnt.columns: cnt["keypaper"] = 0
    cnt = cnt.rename(columns={"corpus": "n_corpus", "keypaper": "n_keypapers"})

    kp_thresh = int(cl.get("keypaper_threshold", 5))
    info = info.rename(columns={"Topic": "topic_id", "Name": "label", "Count": "n_total"})
    info = info.merge(cnt[["topic_id", "n_corpus", "n_keypapers"]],
                      on="topic_id", how="left")
    info["n_corpus"]    = info["n_corpus"].fillna(0).astype(int)
    info["n_keypapers"] = info["n_keypapers"].fillna(0).astype(int)
    info["is_relevant"] = info["n_keypapers"] >= kp_thresh

    top_n = int(cl.get("top_n_words", 15))
    rows = []
    for tid in info["topic_id"]:
        for rank, (word, weight) in enumerate(topic_model.get_topic(tid)[:top_n], start=1):
            rows.append({
                "topic_id": int(tid), "word": word,
                "weight": float(weight), "rank": int(rank),
            })
    topic_words = pd.DataFrame(rows)
    info["top_words"] = info["topic_id"].map(
        topic_words.groupby("topic_id")["word"].apply(list).to_dict()
    )

    # ---------- 8. Write parquets ------------------------------------------
    out_dir = _leaf_dir(out_root, config_name, run_name, primary)
    print(f"[step] writing parquets to {out_dir}")
    out_topics.to_parquet(out_dir / "topics.parquet",       index=False)
    info.to_parquet(      out_dir / "topic_info.parquet",   index=False)
    topic_words.to_parquet(out_dir / "topic_words.parquet", index=False)

    n_topics = int((info["topic_id"] >= 0).sum())
    n_noise  = int((out_topics["topic_id"] == -1).sum())
    n_xfer   = int((out_topics["topic_source"] == "transferred").sum())
    n_fb     = int((out_topics["topic_source"] == "fallback").sum())
    print(f"[done] topics={n_topics}  noise={n_noise:,}  transferred={n_xfer:,}  fallback={n_fb:,}")
    print(str(out_dir / "topic_info.parquet"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
