#!/usr/bin/env python3
"""
BERTopic clustering — GPU full-corpus mode (cuml), memory-conscious.

Runs INSIDE a RunPod pod from the bertopic-runpod image. Uses cuml's
UMAP + HDBSCAN so the full 5+M-row corpus fits in VRAM and finishes in
minutes-to-hours rather than days.

Phase 1: embedding inputs live in Cloudflare R2 (S3-compatible). All
reads go through duckdb httpfs — no local parquet files on the pod. The
primary variant is materialised once into pandas (cuml.UMAP needs the
full matrix); the fallback variant is streamed via duckdb anti-join in
50K-row chunks.

Inputs (paths may be local OR `s3://bucket/prefix/...`):
    --corpus-emb-dir    .../config=<X>/source=corpus
    --reference-emb-dir .../config=<X>/source=keypaper
    --output-dir        .../topics
    --bertopic-cfg-yaml /tmp/bertopic_cfg.yaml
    --run-name          default_runpod

S3/R2 credentials come from env vars (set in the RunPod template):
    R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY
Endpoint + region come from the cfg yaml's r2: block (no secrets).

Output:
    <output_dir>/config=<X>/bertopic=<run_name>/variant=<primary>/
        topics.parquet  topic_info.parquet  topic_words.parquet

Self-contained — drop into openalexVectorComp/inst/scripts/ later.
"""

from __future__ import annotations

import argparse
import gc
import os
import sys
import time
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd
import yaml


# Heartbeat path that the idle watchdog watches. Touched at start + every
# step, so an idle pod (no script) can be auto-stopped without killing an
# actively-running BERTopic job.
HEARTBEAT_PATH = Path("/work/.heartbeat")


def _heartbeat():
    try:
        HEARTBEAT_PATH.parent.mkdir(parents=True, exist_ok=True)
        HEARTBEAT_PATH.touch()
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Schema helpers (shared with run_bertopic_local.py)
# ---------------------------------------------------------------------------

def _embedding_columns(table_columns):
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


def _glob(emb_root: str, variant: str) -> str:
    """Build a glob over parquet files for a variant.
    emb_root may be a local path or an s3://bucket/prefix URI."""
    root = emb_root.rstrip("/")
    return f"{root}/variant={variant}/**/*.parquet"


def _setup_duckdb_s3(con: duckdb.DuckDBPyConnection, r2_cfg: dict) -> None:
    """Configure duckdb httpfs for R2. Idempotent — safe to call per query."""
    endpoint = r2_cfg.get("endpoint")
    if not endpoint:
        return
    key_id = os.environ.get("R2_ACCESS_KEY_ID")
    secret = os.environ.get("R2_SECRET_ACCESS_KEY")
    if not (key_id and secret):
        raise SystemExit(
            "R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY env vars must be set on "
            "the pod (RunPod template — set as Secrets)."
        )
    con.execute("INSTALL httpfs; LOAD httpfs;")
    con.execute(f"SET s3_region='{r2_cfg.get('region', 'auto')}'")
    con.execute(f"SET s3_endpoint='{endpoint}'")
    con.execute(f"SET s3_access_key_id='{key_id}'")
    con.execute(f"SET s3_secret_access_key='{secret}'")
    # R2 uses virtual-hosted-style by default; path style is the safe choice
    # when the endpoint is the bare account host without bucket subdomain.
    con.execute("SET s3_url_style='path'")
    con.execute("SET s3_use_ssl=true")


def _read_full_variant(emb_root: str, variant: str, r2_cfg: dict) -> pd.DataFrame:
    """
    Materialise an entire variant into pandas via duckdb. Used for the
    primary variant (cuml.UMAP needs the full matrix in one shot) and for
    keypapers (small). Works for local paths and s3:// URIs alike.
    """
    con = duckdb.connect()
    try:
        _setup_duckdb_s3(con, r2_cfg)
        pattern = _glob(emb_root, variant)
        # Probe the schema first so we keep only the columns we need.
        schema_q = f"DESCRIBE SELECT * FROM read_parquet('{pattern}', hive_partitioning = false) LIMIT 0"
        schema = con.execute(schema_q).fetchdf()
        cols_all = schema["column_name"].tolist()
        emb_cols = _embedding_columns(cols_all)
        if not emb_cols:
            raise RuntimeError(f"No embedding columns (V<int>) found at {pattern}")
        keep = [c for c in ("id", "title_clean", "abstract_clean") if c in cols_all] + emb_cols
        select_list = ", ".join(f'"{c}"' for c in keep)
        df = con.execute(
            f"SELECT {select_list} FROM read_parquet('{pattern}', hive_partitioning = false)"
        ).fetchdf()
        if df.empty:
            raise FileNotFoundError(f"No rows at {pattern}")
        return df
    finally:
        con.close()


def _stream_variant_minus_primary(emb_root: str,
                                  fallback_variant: str,
                                  primary_variant: str,
                                  r2_cfg: dict,
                                  chunk_rows: int = 50_000):
    """
    Yield DataFrames in chunks of ~`chunk_rows`: rows in `fallback_variant`
    whose id is NOT in `primary_variant`. duckdb anti-join, streamed — so
    we never hold the full fallback dataset in RAM alongside the primary.
    """
    con = duckdb.connect()
    try:
        _setup_duckdb_s3(con, r2_cfg)
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

    _heartbeat()

    # Paths may be local or s3:// — keep them as strings, don't Path()-ify
    # (Path mangles s3:// into s3:/).
    def _is_s3(p: str) -> bool:
        return p.startswith("s3://")

    def _parent(p: str) -> str:
        return p.rstrip("/").rsplit("/", 1)[0]

    def _basename(p: str) -> str:
        return p.rstrip("/").rsplit("/", 1)[-1]

    corpus_root = args.corpus_emb_dir if _is_s3(args.corpus_emb_dir)    else str(Path(args.corpus_emb_dir).resolve())
    refer_root  = args.reference_emb_dir if _is_s3(args.reference_emb_dir) else str(Path(args.reference_emb_dir).resolve())
    out_root    = Path(args.output_dir).resolve()
    cfg_path    = Path(args.bertopic_cfg_yaml).resolve()
    run_name    = args.run_name

    if _parent(corpus_root) != _parent(refer_root):
        sys.exit(
            "corpus and reference must share parent (config dir); got\n"
            f"  corpus:    {corpus_root}\n  reference: {refer_root}"
        )
    config_name = _basename(_parent(corpus_root)).split("=", 1)[1]

    with cfg_path.open("r") as fh:
        cl = yaml.safe_load(fh)

    primary  = cl["primary_variant"]
    fallback = cl.get("fallback_variant")
    seed     = int(cl.get("random_seed", 13))
    r2_cfg   = cl.get("r2", {}) or {}

    print(f"[info] config_name = {config_name}")
    print(f"[info] run_name    = {run_name}")
    print(f"[info] primary     = {primary}    fallback = {fallback}")
    if r2_cfg.get("endpoint"):
        print(f"[info] r2 endpoint = {r2_cfg['endpoint']}  bucket = {r2_cfg.get('bucket')}")

    # ---------- 1. Load primary variant: full corpus + all keypapers --------
    print("[step] reading primary variant for corpus + keypapers")
    df_corpus_p = _read_full_variant(corpus_root, primary, r2_cfg)
    df_ref_p    = _read_full_variant(refer_root,  primary, r2_cfg)
    df_corpus_p["source"] = "corpus"
    df_ref_p["source"]    = "keypaper"
    df_fit = pd.concat([df_corpus_p, df_ref_p], ignore_index=True)
    del df_corpus_p   # ref'd into df_fit; release the copy
    print(f"        total fit rows: {len(df_fit):,}  (keypapers: {len(df_ref_p):,})")
    _heartbeat()

    X_fit    = _matrix_from_df(df_fit)
    docs_fit = _docs_from_df(df_fit)

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
        min_cluster_size=int(cl.get("hdbscan_min_cluster_size", 500)),
        min_samples=int(cl.get("hdbscan_min_samples", 50)),
        metric="euclidean",
        cluster_selection_method="eom",
        prediction_data=True,
    )
    vectorizer = CountVectorizer(
        stop_words="english",
        min_df=int(cl.get("vectorizer_min_df", 2)),
        max_df=float(cl.get("vectorizer_max_df", 0.95)),
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

    # Extract small assignments table and free the large fit objects so the
    # fallback transform step has the RAM headroom of an empty pod.
    fit_assignments = df_fit[["id", "source", "topic_id", "topic_source", "probability"]].copy()
    del X_fit, docs_fit, df_fit, df_ref_p
    gc.collect()
    _heartbeat()

    # ---------- 3. Fallback variant streamed via duckdb anti-join ----------
    df_fb_assignments = pd.DataFrame(
        columns=["id", "source", "topic_id", "topic_source", "probability"]
    )
    if fallback:
        print(f"[step] streaming fallback variant ({fallback}) for no-primary works")
        fb_chunks = []
        n_done = 0
        for chunk in _stream_variant_minus_primary(
            corpus_root, fallback, primary, r2_cfg, chunk_rows=50_000
        ):
            topics_chunk, _probs_fb = topic_model.transform(
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
            _heartbeat()
        if fb_chunks:
            df_fb_assignments = pd.concat(fb_chunks, ignore_index=True)
        del fb_chunks

    # ---------- 4. Combine + build outputs ---------------------------------
    out_topics = pd.concat(
        [fit_assignments, df_fb_assignments],
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

    kp_thresh = int(cl.get("keypaper_threshold", 3))
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
