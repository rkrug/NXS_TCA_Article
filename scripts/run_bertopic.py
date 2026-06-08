#!/usr/bin/env python3
"""
BERTopic clustering on pre-computed SPECTER2 embeddings.

Reads the (config, source, variant)-partitioned embedding parquet dataset,
fits BERTopic (UMAP -> HDBSCAN -> c-TF-IDF) on the *primary* variant of corpus
plus keypapers, optionally transfers no-abstract corpus works to the closest
topic via their fallback-variant embedding, and writes three parquets:

    <output_dir>/config=<X>/variant=<primary>/topics.parquet
    <output_dir>/config=<X>/variant=<primary>/topic_info.parquet
    <output_dir>/config=<X>/variant=<primary>/topic_words.parquet

All hyperparameters come from the YAML at --config-yaml; there are no script-
level defaults beyond what BERTopic / UMAP / HDBSCAN provide if a knob is
missing from the YAML. This script is intentionally self-contained so it can be
dropped into openalexVectorComp/inst/scripts/.

Usage:
    python run_bertopic.py \\
      --corpus-emb-dir    <path>/config=SPECTER2/source=corpus \\
      --reference-emb-dir <path>/config=SPECTER2/source=keypaper \\
      --output-dir        <path>/topics \\
      --config-yaml       config.yaml
"""

from __future__ import annotations

import argparse
import os
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

    emb_root looks like: .../config=SPECTER2/source=corpus
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


def _config_path_for_variant(out_dir: Path, config_name: str, variant: str) -> Path:
    p = out_dir / f"config={config_name}" / f"variant={variant}"
    p.mkdir(parents=True, exist_ok=True)
    return p


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--corpus-emb-dir",    required=True,
                   help="Path to .../config=<X>/source=corpus")
    p.add_argument("--reference-emb-dir", required=True,
                   help="Path to .../config=<X>/source=keypaper")
    p.add_argument("--output-dir",        required=True,
                   help="Topic output root (gets config=<X>/variant=<primary>/ inside)")
    p.add_argument("--config-yaml",       required=True,
                   help="Path to config.yaml; reads the `clustering:` block")
    args = p.parse_args()

    corpus_root = Path(args.corpus_emb_dir).resolve()
    refer_root  = Path(args.reference_emb_dir).resolve()
    out_root    = Path(args.output_dir).resolve()
    cfg_path    = Path(args.config_yaml).resolve()

    if corpus_root.parent != refer_root.parent:
        sys.exit(
            f"corpus and reference must share parent (config dir); got\n"
            f"  corpus:    {corpus_root}\n  reference: {refer_root}"
        )
    config_name = corpus_root.parent.name.split("=", 1)[1]

    with cfg_path.open("r") as fh:
        cfg = yaml.safe_load(fh)
    cl = cfg["clustering"]
    primary  = cl["primary_variant"]
    fallback = cl.get("fallback_variant")  # may be None
    seed     = int(cl.get("random_seed", 42))

    print(f"[info] config_name = {config_name}")
    print(f"[info] primary variant  = {primary}")
    print(f"[info] fallback variant = {fallback}")

    # ---------- 1. Load primary variant for corpus + keypapers ---------------
    print("[step] reading primary variant for corpus + keypapers")
    df_corpus_p = _read_source_variant(corpus_root, primary)
    df_ref_p    = _read_source_variant(refer_root, primary)
    df_corpus_p["source"] = "corpus"
    df_ref_p["source"]    = "keypaper"
    df_fit = pd.concat([df_corpus_p, df_ref_p], ignore_index=True)
    print(f"        corpus={len(df_corpus_p)}  keypaper={len(df_ref_p)}  total={len(df_fit)}")

    X_fit = _matrix(df_fit)
    docs_fit = _docs(df_fit)

    # ---------- 2. Build UMAP, HDBSCAN, BERTopic -----------------------------
    print("[step] fitting UMAP + HDBSCAN + c-TF-IDF (BERTopic)")
    from bertopic import BERTopic
    from umap import UMAP
    from hdbscan import HDBSCAN
    from sklearn.feature_extraction.text import CountVectorizer

    umap_model = UMAP(
        n_components = int(cl.get("umap_n_components", 5)),
        n_neighbors  = int(cl.get("umap_n_neighbors", 15)),
        min_dist     = float(cl.get("umap_min_dist", 0.0)),
        metric       = cl.get("umap_metric", "cosine"),
        random_state = seed,
    )
    hdbscan_model = HDBSCAN(
        min_cluster_size = int(cl.get("hdbscan_min_cluster_size", 10)),
        min_samples      = int(cl.get("hdbscan_min_samples", 5)),
        metric           = "euclidean",
        cluster_selection_method = "eom",
        prediction_data  = True,           # required for approximate_predict()
    )
    vectorizer = CountVectorizer(stop_words="english", min_df=2)

    topic_model = BERTopic(
        embedding_model    = None,         # we supply embeddings directly
        umap_model         = umap_model,
        hdbscan_model      = hdbscan_model,
        vectorizer_model   = vectorizer,
        top_n_words        = int(cl.get("top_n_words", 10)),
        calculate_probabilities = False,
        verbose            = True,
    )

    topics_fit, _probs_fit = topic_model.fit_transform(docs_fit, embeddings=X_fit)
    df_fit["topic_id"]      = topics_fit
    df_fit["topic_source"]  = "embedding"
    df_fit["probability"]   = np.nan       # not produced; cheap & not needed downstream

    # ---------- 3. Transfer no-abstract corpus works (fallback variant) ------
    df_fb_assignments = pd.DataFrame(columns=["id", "topic_id", "topic_source", "source"])
    if fallback:
        print(f"[step] reading fallback variant ({fallback}) for corpus")
        df_corpus_fb = _read_source_variant(corpus_root, fallback)
        # only works that are NOT in the primary fit (no abstract)
        already = set(df_corpus_p["id"])
        df_corpus_fb = df_corpus_fb[~df_corpus_fb["id"].isin(already)].reset_index(drop=True)
        print(f"        no-abstract corpus works to transfer: {len(df_corpus_fb)}")

        if len(df_corpus_fb):
            X_fb = _matrix(df_corpus_fb)
            # BERTopic.transform handles UMAP.transform + HDBSCAN.approximate_predict
            topics_fb, _probs_fb = topic_model.transform(
                documents = _docs(df_corpus_fb),
                embeddings = X_fb,
            )
            df_corpus_fb["topic_id"]     = topics_fb
            df_corpus_fb["topic_source"] = "transfer"
            df_corpus_fb["source"]       = "corpus"
            df_corpus_fb["probability"]  = np.nan
            df_fb_assignments = df_corpus_fb[["id", "source", "topic_id", "topic_source", "probability"]]

    # ---------- 4. Combine assignments + build outputs -----------------------
    out_topics = pd.concat(
        [
            df_fit[["id", "source", "topic_id", "topic_source", "probability"]],
            df_fb_assignments,
        ],
        ignore_index=True,
    )

    info = topic_model.get_topic_info()
    # Per-topic keypaper / corpus counts
    cnt = (
        out_topics
        .groupby(["topic_id", "source"])
        .size()
        .unstack(fill_value=0)
        .reset_index()
    )
    if "corpus" not in cnt.columns:    cnt["corpus"] = 0
    if "keypaper" not in cnt.columns:  cnt["keypaper"] = 0
    cnt = cnt.rename(columns={"corpus": "n_corpus", "keypaper": "n_keypapers"})

    kp_thresh = int(cl.get("keypaper_threshold", 2))
    info = info.rename(columns={"Topic": "topic_id", "Name": "label", "Count": "n_total"})
    info = info.merge(cnt[["topic_id", "n_corpus", "n_keypapers"]],
                      on="topic_id", how="left")
    info["n_corpus"]    = info["n_corpus"].fillna(0).astype(int)
    info["n_keypapers"] = info["n_keypapers"].fillna(0).astype(int)
    info["is_relevant"] = info["n_keypapers"] >= kp_thresh

    # Top words per topic (long form)
    top_n = int(cl.get("top_n_words", 10))
    rows = []
    for tid in info["topic_id"]:
        for rank, (word, weight) in enumerate(topic_model.get_topic(tid)[:top_n], start=1):
            rows.append({"topic_id": int(tid), "word": word, "weight": float(weight), "rank": int(rank)})
    topic_words = pd.DataFrame(rows)

    # `top_words` as a list column on info (handy for kable / DT)
    info["top_words"] = info["topic_id"].map(
        topic_words.groupby("topic_id")["word"].apply(list).to_dict()
    )

    # ---------- 5. Write parquets ------------------------------------------
    out_dir = _config_path_for_variant(out_root, config_name, primary)
    print(f"[step] writing parquets to {out_dir}")
    out_topics.to_parquet(out_dir / "topics.parquet",      index=False)
    info.to_parquet(      out_dir / "topic_info.parquet",  index=False)
    topic_words.to_parquet(out_dir / "topic_words.parquet", index=False)

    n_topics  = int((info["topic_id"] >= 0).sum())
    n_noise   = int(out_topics["topic_id"].eq(-1).sum())
    n_xfer    = int(out_topics["topic_source"].eq("transfer").sum())
    print(f"[done] topics={n_topics}  noise_assignments={n_noise}  transferred={n_xfer}")
    print(str(out_dir / "topic_info.parquet"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
