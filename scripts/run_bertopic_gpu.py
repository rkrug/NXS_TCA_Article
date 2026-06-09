#!/usr/bin/env python3
"""
BERTopic clustering — GPU full-corpus mode (cuml).

Runs INSIDE a RunPod pod from the bertopic-runpod image. Uses cuml's
UMAP + HDBSCAN so the full 5+M-row corpus fits comfortably in the GPU's
VRAM and finishes in minutes-to-hours rather than days.

Same I/O contract as run_bertopic_local.py — three parquets + the
hive-partitioned leaf layout — so downstream R-side code is identical
between paths.

Inputs:
    --corpus-emb-dir    .../config=<X>/source=corpus
    --reference-emb-dir .../config=<X>/source=keypaper
    --output-dir        .../topics
    --bertopic-cfg-yaml /tmp/bertopic_cfg.yaml
    --run-name          default_runpod

Output:
    <output_dir>/config=<X>/bertopic=<run_name>/variant=<primary>/
        topics.parquet  topic_info.parquet  topic_words.parquet

Self-contained — drop into openalexVectorComp/inst/scripts/ later.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd
import pyarrow.dataset as ds
import yaml


# Heartbeat path that the idle watchdog watches. Touched at start + every
# minute while compute is running, so an idle pod (no script) can be
# auto-stopped without killing an actively-running BERTopic job.
HEARTBEAT_PATH = Path("/work/.heartbeat")


def _heartbeat():
    try:
        HEARTBEAT_PATH.parent.mkdir(parents=True, exist_ok=True)
        HEARTBEAT_PATH.touch()
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Helpers (identical to run_bertopic_local.py — kept inline for self-contained)
# ---------------------------------------------------------------------------

def _embedding_columns(table_columns):
    ev = [c for c in table_columns if c.startswith("V") and c[1:].isdigit()]
    return sorted(ev, key=lambda c: int(c[1:]))


def _read_source_variant(emb_root: Path, variant: str) -> pd.DataFrame:
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
    title = df.get("title_clean", pd.Series([""] * len(df))).fillna("")
    abstract = df.get("abstract_clean", pd.Series([""] * len(df))).fillna("")
    return (title.astype(str) + " " + abstract.astype(str)).tolist()


def _leaf_dir(out_root: Path, config_name: str, run_name: str,
              primary: str) -> Path:
    p = out_root / f"config={config_name}" / f"bertopic={run_name}" / f"variant={primary}"
    p.mkdir(parents=True, exist_ok=True)
    return p


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
    p.add_argument("--bertopic-cfg-yaml", required=True)
    p.add_argument("--run-name",          required=True)
    args = p.parse_args()

    _heartbeat()

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

    primary  = cl["primary_variant"]
    fallback = cl.get("fallback_variant")
    seed     = int(cl.get("random_seed", 13))

    print(f"[info] config_name = {config_name}")
    print(f"[info] run_name    = {run_name}")
    print(f"[info] primary     = {primary}    fallback = {fallback}")

    # ---------- 1. Load primary variant: full corpus + all keypapers --------
    print("[step] reading primary variant for corpus + keypapers")
    df_corpus_p = _read_source_variant(corpus_root, primary)
    df_ref_p    = _read_source_variant(refer_root,  primary)
    df_corpus_p["source"] = "corpus"
    df_ref_p["source"]    = "keypaper"
    df_fit = pd.concat([df_corpus_p, df_ref_p], ignore_index=True)
    print(f"        corpus={len(df_corpus_p):,}  keypaper={len(df_ref_p):,}  total={len(df_fit):,}")
    _heartbeat()

    X_fit    = _matrix(df_fit)
    docs_fit = _docs(df_fit)

    # ---------- 2. Build UMAP + HDBSCAN + BERTopic (cuml-backed) -----------
    print("[step] fitting cuml.UMAP + cuml.HDBSCAN + c-TF-IDF (BERTopic)")
    from bertopic import BERTopic
    from cuml.manifold import UMAP as cumlUMAP
    from cuml.cluster import HDBSCAN as cumlHDBSCAN
    from sklearn.feature_extraction.text import CountVectorizer

    umap_model = cumlUMAP(
        n_components=int(cl.get("umap_n_components", 5)),
        n_neighbors=int(cl.get("umap_n_neighbors",  30)),
        min_dist=float(cl.get("umap_min_dist",       0.0)),
        metric=cl.get("umap_metric", "cosine"),
        random_state=seed,
    )
    hdbscan_model = cumlHDBSCAN(
        min_cluster_size=int(cl.get("hdbscan_min_cluster_size", 200)),
        min_samples=int(cl.get("hdbscan_min_samples", 50)),
        metric="euclidean",
        cluster_selection_method="eom",
        prediction_data=True,
    )
    vectorizer = CountVectorizer(
        stop_words="english",
        min_df=int(cl.get("vectorizer_min_df", 10)),
        max_df=float(cl.get("vectorizer_max_df", 0.5)),
        max_features=int(cl.get("vectorizer_max_features", 20_000)),
        ngram_range=tuple(cl.get("vectorizer_ngram", [1, 2])),
    )

    topic_model = BERTopic(
        embedding_model=None,
        umap_model=umap_model,
        hdbscan_model=hdbscan_model,
        vectorizer_model=vectorizer,
        top_n_words=int(cl.get("top_n_words", 15)),
        calculate_probabilities=False,
        verbose=True,
    )

    t0 = time.time()
    topics_fit, _probs = topic_model.fit_transform(docs_fit, embeddings=X_fit)
    print(f"[time] fit_transform: {time.time() - t0:.1f}s")
    _heartbeat()

    df_fit["topic_id"]     = np.asarray(topics_fit, dtype=np.int64)
    df_fit["topic_source"] = "embedding"
    df_fit["probability"]  = np.nan

    # ---------- 3. Fallback variant: works without primary -----------------
    df_fb_assignments = pd.DataFrame(columns=["id", "source", "topic_id", "topic_source", "probability"])
    if fallback:
        print(f"[step] reading fallback variant ({fallback}) for corpus")
        df_corpus_fb = _read_source_variant(corpus_root, fallback)
        already = set(df_corpus_p["id"])
        df_corpus_fb = df_corpus_fb[~df_corpus_fb["id"].isin(already)].reset_index(drop=True)
        print(f"        no-primary corpus works to transfer: {len(df_corpus_fb):,}")
        _heartbeat()
        if len(df_corpus_fb):
            X_fb = _matrix(df_corpus_fb)
            topics_fb, _probs_fb = topic_model.transform(
                documents=_docs(df_corpus_fb), embeddings=X_fb
            )
            df_corpus_fb["topic_id"]     = np.asarray(topics_fb, dtype=np.int64)
            df_corpus_fb["topic_source"] = "fallback"
            df_corpus_fb["source"]       = "corpus"
            df_corpus_fb["probability"]  = np.nan
            df_fb_assignments = df_corpus_fb[["id", "source", "topic_id", "topic_source", "probability"]]
            _heartbeat()

    # ---------- 4. Combine + build outputs ---------------------------------
    out_topics = pd.concat(
        [
            df_fit[["id", "source", "topic_id", "topic_source", "probability"]],
            df_fb_assignments,
        ],
        ignore_index=True,
    )
    out_topics["topic_id"] = out_topics["topic_id"].astype(np.int64)

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

    # ---------- 5. Write parquets ------------------------------------------
    out_dir = _leaf_dir(out_root, config_name, run_name, primary)
    print(f"[step] writing parquets to {out_dir}")
    out_topics.to_parquet(out_dir / "topics.parquet",       index=False)
    info.to_parquet(      out_dir / "topic_info.parquet",   index=False)
    topic_words.to_parquet(out_dir / "topic_words.parquet", index=False)

    n_topics = int((info["topic_id"] >= 0).sum())
    n_noise  = int((out_topics["topic_id"] == -1).sum())
    n_fb     = int((out_topics["topic_source"] == "fallback").sum())
    print(f"[done] topics={n_topics}  noise={n_noise:,}  fallback={n_fb:,}")
    print(str(out_dir / "topic_info.parquet"))
    _heartbeat()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
