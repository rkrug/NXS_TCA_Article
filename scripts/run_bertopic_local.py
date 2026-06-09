#!/usr/bin/env python3
"""
BERTopic clustering — local (CPU) sample-fit + transform-everything mode,
memory-bounded.

Fits BERTopic on a stratified sample of the corpus primary variant + ALL
keypapers, then projects every remaining corpus work in BOTH the primary
AND the fallback variant onto the fitted UMAP/HDBSCAN model so that
every corpus work and every keypaper receives a topic_id.

Earlier versions materialised the entire corpus primary (~4.6M × 768
floats ≈ 14 GB) into a single pandas DataFrame and OOM'd on macOS. This
version streams sampling + transform via duckdb so peak RAM stays at
~50K rows × 768 floats ≈ 150 MB per chunk plus the fit-time matrix.

Output (3 parquets + marker stamped by the R wrapper):

    <output_dir>/config=<X>/bertopic=<run_name>/variant=<primary>/topics.parquet
    <output_dir>/config=<X>/bertopic=<run_name>/variant=<primary>/topic_info.parquet
    <output_dir>/config=<X>/bertopic=<run_name>/variant=<primary>/topic_words.parquet

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
import pyarrow.dataset as pads
import yaml


# ---------------------------------------------------------------------------
# Schema helpers (shared with run_bertopic_gpu.py)
# ---------------------------------------------------------------------------

def _embedding_columns(table_columns):
    """Names of V1..V<n> embedding columns, ordered by index."""
    ev = [c for c in table_columns if c.startswith("V") and c[1:].isdigit()]
    return sorted(ev, key=lambda c: int(c[1:]))


def _matrix_from_df(df: pd.DataFrame) -> np.ndarray:
    cols = _embedding_columns(df.columns)
    return df[cols].to_numpy(dtype=np.float32)


def _docs_from_df(df: pd.DataFrame) -> list[str]:
    title = df.get("title_clean", pd.Series([""] * len(df))).fillna("")
    abstract = df.get("abstract_clean", pd.Series([""] * len(df))).fillna("")
    return (title.astype(str) + " " + abstract.astype(str)).tolist()


def _leaf_dir(out_root: Path, config_name: str, run_name: str,
              primary: str) -> Path:
    p = out_root / f"config={config_name}" / f"bertopic={run_name}" / f"variant={primary}"
    p.mkdir(parents=True, exist_ok=True)
    return p


# ---------------------------------------------------------------------------
# Data loaders — all streamed via duckdb except small full-load of keypapers
# ---------------------------------------------------------------------------

def _read_full_variant(emb_root: Path, variant: str) -> pd.DataFrame:
    """
    Materialise an entire variant into pandas. Use ONLY for small variants
    like the keypapers reference set (~100 rows). For the corpus primary
    variant, use _sample_variant + _stream_variant_excluding instead.
    """
    variant_dir = emb_root / f"variant={variant}"
    if not variant_dir.is_dir():
        raise FileNotFoundError(f"No partition: {variant_dir}")
    dset = pads.dataset(str(variant_dir), format="parquet")
    cols = dset.schema.names
    keep = ["id", "title_clean", "abstract_clean"]
    keep = [c for c in keep if c in cols] + _embedding_columns(cols)
    return dset.to_table(columns=keep).to_pandas()


def _glob(emb_root: Path, variant: str) -> str:
    return str(emb_root / f"variant={variant}" / "**" / "*.parquet")


def _sample_variant(emb_root: Path, variant: str,
                    n_sample: int, seed: int) -> pd.DataFrame:
    """
    Random sample of N rows from a variant via duckdb's RESERVOIR sampler.
    Streams the input parquets without materialising the whole variant.
    Reproducible given (n_sample, seed).
    """
    import duckdb
    con = duckdb.connect()
    try:
        df = con.execute(f"""
            SELECT *
            FROM read_parquet('{_glob(emb_root, variant)}', hive_partitioning = false)
            USING SAMPLE {int(n_sample)} ROWS (RESERVOIR, {int(seed)})
        """).df()
    finally:
        con.close()
    return df


def _stream_variant_excluding(emb_root: Path, variant: str,
                              exclude_ids,
                              chunk_rows: int = 50_000):
    """
    Yield DataFrames in chunks of ~`chunk_rows`: all rows from `variant`
    whose id is NOT in `exclude_ids`. Streams via duckdb anti-join — never
    materialises the whole variant in memory.
    """
    import duckdb
    con = duckdb.connect()
    try:
        excl_df = pd.DataFrame({"id": list(exclude_ids)} if exclude_ids
                               else {"id": pd.Series([], dtype=object)})
        con.register("excl", excl_df)
        res = con.execute(f"""
            SELECT *
            FROM read_parquet('{_glob(emb_root, variant)}', hive_partitioning = false) AS p
            WHERE p.id NOT IN (SELECT id FROM excl)
        """)
        while True:
            chunk = res.fetch_df_chunk()
            if chunk is None or len(chunk) == 0:
                break
            yield chunk
    finally:
        con.close()


def _stream_variant_minus_primary(emb_root: Path,
                                  fallback_variant: str,
                                  primary_variant: str,
                                  chunk_rows: int = 50_000):
    """
    Yield DataFrames in chunks of ~`chunk_rows`: rows in `fallback_variant`
    whose id is NOT in `primary_variant`. duckdb anti-join, streamed.
    """
    import duckdb
    con = duckdb.connect()
    try:
        res = con.execute(f"""
            SELECT *
            FROM read_parquet('{_glob(emb_root, fallback_variant)}', hive_partitioning = false) AS f
            WHERE f.id NOT IN (
              SELECT id FROM read_parquet('{_glob(emb_root, primary_variant)}', hive_partitioning = false)
            )
        """)
        while True:
            chunk = res.fetch_df_chunk()
            if chunk is None or len(chunk) == 0:
                break
            yield chunk
    finally:
        con.close()


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

    # ---------- 1. Load keypapers (small) -----------------------------------
    print("[step] loading keypapers primary variant")
    df_ref_p = _read_full_variant(refer_root, primary)
    df_ref_p["source"] = "keypaper"
    print(f"        keypapers: {len(df_ref_p):,}")

    # ---------- 2. Sample corpus primary via duckdb (streamed) -------------
    print(f"[step] sampling {sample_size:,} corpus rows from variant={primary}")
    df_corpus_sample = _sample_variant(corpus_root, primary, sample_size, seed)
    df_corpus_sample["source"] = "corpus"
    print(f"        corpus sample: {len(df_corpus_sample):,}")
    sample_ids = set(df_corpus_sample["id"].astype(str).tolist())

    # ---------- 3. Fit BERTopic on (sample + keypapers) --------------------
    df_fit   = pd.concat([df_corpus_sample, df_ref_p], ignore_index=True)
    X_fit    = _matrix_from_df(df_fit)
    docs_fit = _docs_from_df(df_fit)

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

    topics_fit, _probs_fit = topic_model.fit_transform(docs_fit, embeddings=X_fit)
    df_fit["topic_id"]     = np.asarray(topics_fit, dtype=np.int64)
    df_fit["topic_source"] = "embedding"
    df_fit["probability"]  = np.nan

    # Free the large fit-time matrix; keep only the small assignments df.
    del X_fit, docs_fit, df_corpus_sample
    fit_assignments = df_fit[["id", "source", "topic_id", "topic_source", "probability"]].copy()
    del df_fit

    # ---------- 4. Stream the rest of corpus primary, transform per chunk --
    print("[step] transferring remaining corpus primary rows (streamed)")
    rest_chunks = []
    n_done = 0
    for chunk in _stream_variant_excluding(
        corpus_root, primary, sample_ids, chunk_rows=50_000
    ):
        topics_chunk, _probs = topic_model.transform(
            documents=_docs_from_df(chunk),
            embeddings=_matrix_from_df(chunk),
        )
        rest_chunks.append(pd.DataFrame({
            "id":           chunk["id"].astype(str).values,
            "source":       "corpus",
            "topic_id":     np.asarray(topics_chunk, dtype=np.int64),
            "topic_source": "transferred",
            "probability":  np.nan,
        }))
        n_done += len(chunk)
        print(f"        transferred {n_done:,}")
        del chunk
    df_rest = (pd.concat(rest_chunks, ignore_index=True)
               if rest_chunks else
               pd.DataFrame(columns=fit_assignments.columns))
    del rest_chunks

    # ---------- 5. Fallback variant (rows present only in fallback) --------
    df_fb = pd.DataFrame(columns=fit_assignments.columns)
    if fallback:
        print(f"[step] processing fallback variant ({fallback}) for no-primary works")
        fb_chunks = []
        n_done = 0
        for chunk in _stream_variant_minus_primary(
            corpus_root, fallback, primary, chunk_rows=50_000
        ):
            topics_chunk, _probs = topic_model.transform(
                documents=_docs_from_df(chunk),
                embeddings=_matrix_from_df(chunk),
            )
            fb_chunks.append(pd.DataFrame({
                "id":           chunk["id"].astype(str).values,
                "source":       "corpus",
                "topic_id":     np.asarray(topics_chunk, dtype=np.int64),
                "topic_source": "fallback",
                "probability":  np.nan,
            }))
            n_done += len(chunk)
            print(f"        fallback {n_done:,}")
            del chunk
        if fb_chunks:
            df_fb = pd.concat(fb_chunks, ignore_index=True)
        del fb_chunks

    # ---------- 6. Combine all assignments ---------------------------------
    out_topics = pd.concat([fit_assignments, df_rest, df_fb], ignore_index=True)
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
