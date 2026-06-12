#!/usr/bin/env python3
"""
BERTopic clustering — GPU full-corpus mode (cuml), with R2 stage caching.

This replaces BERTopic.fit_transform's monolithic pipeline with direct
orchestration of cuml.UMAP + cuml.HDBSCAN + sklearn-based c-TF-IDF.
Two motivations:

  1. BERTopic's Representation step OOM'd at 4.6M rows on a 116 GB pod
     by holding multiple internal copies of the document set. Direct
     orchestration on per-topic concatenated documents (sklearn
     CountVectorizer on ~500 strings, not 4.6M) cuts peak RAM by ~3x.
  2. Each fitting stage (UMAP, HDBSCAN, c-TF-IDF) writes intermediate
     state to R2 keyed by a cascade cfg-hash, so re-running with
     unchanged upstream params loads from cache instead of recomputing.

Pipeline stages:
  1. UMAP fit on corpus primary variant only (keypapers decoupled).
  2. HDBSCAN fit on UMAP coords.
  3. c-TF-IDF on per-topic concatenated corpus docs.
  4. Project keypapers into the fitted UMAP + HDBSCAN.
  5. Project fallback variant (no-abstract corpus works).
  6. Compose final topic_info / topics / topic_words outputs.

R2 cache layout:
  s3://<bucket>/intermediate/
    config=<embedding_config>/
      umap_cfg=<umap_hash>/
        umap_model.pkl              # cuml.UMAP fitted model
        umap_coords.parquet         # id + V1..V_n
        meta.json
        hdbscan_cfg=<hdbscan_hash>/
          hdbscan_model.pkl
          topics.parquet            # id, topic_id, probability
          meta.json
          ctfidf_cfg=<ctfidf_hash>/
            topic_info.parquet      # topic_id, label, top_words
            topic_words.parquet     # topic_id, word, weight, rank
            meta.json

Cascade semantics: changing `hdbscan_min_cluster_size` invalidates the
hdbscan_cfg + ctfidf_cfg subtrees but reuses umap_cfg. Changing
`vectorizer_*` invalidates only ctfidf_cfg. Keypaper-swap workflow
touches none of the cache.

R2 credentials come from env (R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY).
Endpoint + bucket from the cfg yaml's r2: block.

Self-contained — droppable into openalexVectorComp/inst/scripts/.
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import io
import json
import os
import sys
import time
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd
import yaml


HEARTBEAT_PATH = Path("/work/.heartbeat")


def _heartbeat():
    try:
        HEARTBEAT_PATH.parent.mkdir(parents=True, exist_ok=True)
        HEARTBEAT_PATH.touch()
    except OSError:
        pass


def _start_heartbeat_thread(interval_s: int = 30):
    """Background thread keeping /work/.heartbeat fresh during long-running
    blocking library calls. Belt-and-braces only — the entrypoint also runs
    an external bash heartbeat that doesn't depend on the GIL."""
    import threading
    def _loop():
        while True:
            _heartbeat()
            time.sleep(interval_s)
    t = threading.Thread(target=_loop, daemon=True)
    t.start()
    return t


# ---------------------------------------------------------------------------
# Schema helpers
# ---------------------------------------------------------------------------

def _embedding_columns(table_columns):
    ev = [c for c in table_columns if c.startswith("V") and c[1:].isdigit()]
    return sorted(ev, key=lambda c: int(c[1:]))


def _matrix_from_df(df: pd.DataFrame) -> np.ndarray:
    cols = _embedding_columns(df.columns)
    return df[cols].to_numpy(dtype=np.float32)


def _leaf_dir(out_root: Path, config_name: str, run_name: str,
              primary: str) -> Path:
    p = out_root / f"config={config_name}" / f"bertopic={run_name}" / f"variant={primary}"
    p.mkdir(parents=True, exist_ok=True)
    return p


def _glob(emb_root: str, variant: str) -> str:
    root = emb_root.rstrip("/")
    return f"{root}/variant={variant}/**/*.parquet"


# ---------------------------------------------------------------------------
# duckdb httpfs setup (R2)
# ---------------------------------------------------------------------------

def _setup_duckdb_s3(con: duckdb.DuckDBPyConnection, r2_cfg: dict) -> None:
    endpoint = r2_cfg.get("endpoint")
    if not endpoint:
        return
    key_id = os.environ.get("R2_ACCESS_KEY_ID")
    secret = os.environ.get("R2_SECRET_ACCESS_KEY")
    if not (key_id and secret):
        raise SystemExit(
            "R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY env vars must be set on the pod."
        )
    con.execute("INSTALL httpfs; LOAD httpfs;")
    con.execute(f"SET s3_region='{r2_cfg.get('region', 'auto')}'")
    con.execute(f"SET s3_endpoint='{endpoint}'")
    con.execute(f"SET s3_access_key_id='{key_id}'")
    con.execute(f"SET s3_secret_access_key='{secret}'")
    con.execute("SET s3_url_style='path'")
    con.execute("SET s3_use_ssl=true")


def _read_full_variant_with_text(emb_root: str, variant: str, r2_cfg: dict) -> pd.DataFrame:
    """Read embeddings + text columns (title_clean, abstract_clean) via duckdb.
    Used for the UMAP-fit stage which needs both for the cache write."""
    con = duckdb.connect()
    try:
        _setup_duckdb_s3(con, r2_cfg)
        pattern = _glob(emb_root, variant)
        schema = con.execute(
            f"DESCRIBE SELECT * FROM read_parquet('{pattern}', hive_partitioning = false) LIMIT 0"
        ).fetchdf()
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


def _read_text_only(emb_root: str, variant: str, r2_cfg: dict) -> pd.DataFrame:
    """Read id + text columns only (no embeddings). Used in c-TF-IDF stage
    when umap_coords cache hits but we still need corpus text."""
    con = duckdb.connect()
    try:
        _setup_duckdb_s3(con, r2_cfg)
        pattern = _glob(emb_root, variant)
        df = con.execute(
            f"SELECT id, title_clean, abstract_clean "
            f"FROM read_parquet('{pattern}', hive_partitioning = false)"
        ).fetchdf()
        return df
    finally:
        con.close()


def _stream_variant_minus_primary(emb_root: str,
                                  fallback_variant: str,
                                  primary_variant: str,
                                  r2_cfg: dict,
                                  chunk_rows: int = 50_000):
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
# R2 IO helpers (boto3-based for non-parquet artefacts)
# ---------------------------------------------------------------------------

def _r2_client(r2_cfg: dict):
    import boto3
    return boto3.client(
        "s3",
        endpoint_url=f"https://{r2_cfg['endpoint']}",
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
        region_name=r2_cfg.get("region", "auto"),
    )


def _r2_exists(client, bucket: str, key: str) -> bool:
    try:
        client.head_object(Bucket=bucket, Key=key)
        return True
    except client.exceptions.ClientError:
        return False
    except Exception:
        return False


def _r2_put_bytes(client, bucket: str, key: str, data: bytes) -> None:
    # upload_fileobj auto-chunks via multipart (default threshold 8 MB,
    # part size 8 MB). The cuml.UMAP pickle is 1-3 GB, which a single
    # client.put_object cannot reliably push to R2 — Cloudflare's TLS
    # endpoint drops the connection mid-upload (ssl.SSLEOFError) for
    # large monolithic PUTs. Multipart is also retried per-part on
    # transient failures, no extra retry logic needed in our code.
    import boto3.s3.transfer
    config = boto3.s3.transfer.TransferConfig(
        multipart_threshold=8 * 1024 * 1024,     # 8 MB
        multipart_chunksize=64 * 1024 * 1024,    # 64 MB chunks
        max_concurrency=8,
        use_threads=True,
    )
    client.upload_fileobj(io.BytesIO(data), bucket, key, Config=config)


def _r2_get_bytes(client, bucket: str, key: str) -> bytes:
    obj = client.get_object(Bucket=bucket, Key=key)
    return obj["Body"].read()


def _pickle_to_r2(client, bucket: str, key: str, obj) -> None:
    """cloudpickle handles cuml/numpy/sklearn objects more robustly than
    stdlib pickle."""
    import cloudpickle
    _r2_put_bytes(client, bucket, key, cloudpickle.dumps(obj))


def _unpickle_from_r2(client, bucket: str, key: str):
    import cloudpickle
    return cloudpickle.loads(_r2_get_bytes(client, bucket, key))


def _parquet_to_r2(client, bucket: str, key: str, df: pd.DataFrame) -> None:
    buf = io.BytesIO()
    df.to_parquet(buf, index=False, compression="snappy")
    _r2_put_bytes(client, bucket, key, buf.getvalue())


def _parquet_from_r2(client, bucket: str, key: str) -> pd.DataFrame:
    return pd.read_parquet(io.BytesIO(_r2_get_bytes(client, bucket, key)))


def _meta_to_r2(client, bucket: str, key: str, cfg: dict, stage: str) -> None:
    meta = {
        "stage": stage,
        "cfg": cfg,
        "fit_timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "image_sha": os.environ.get("IMAGE_SHA", "unknown"),
        "python_version": sys.version,
    }
    _r2_put_bytes(client, bucket, key, json.dumps(meta, indent=2).encode())


# ---------------------------------------------------------------------------
# Cfg-hash helpers
# ---------------------------------------------------------------------------
#
# Hashes are blake2b(canonical-json) truncated to 16 hex chars. The
# canonical-json form (sorted keys, no whitespace) is stable across Python
# versions and platforms; xxhash would be marginally faster but blake2b is
# stdlib.
#
# Cascade hashing: hdbscan_cfg includes all umap_cfg fields, ctfidf_cfg
# includes all hdbscan_cfg fields, etc. So changes to upstream params
# invalidate downstream hashes naturally without explicit propagation logic.

_UMAP_FIELDS = (
    "primary_variant", "umap_n_components", "umap_n_neighbors",
    "umap_min_dist", "umap_metric", "random_seed",
)

_HDBSCAN_FIELDS = _UMAP_FIELDS + (
    "hdbscan_min_cluster_size", "hdbscan_min_samples",
)

_CTFIDF_FIELDS = _HDBSCAN_FIELDS + (
    "vectorizer_min_df", "vectorizer_max_df", "vectorizer_max_features",
    "vectorizer_ngram", "top_n_words",
)


def _cfg_subset(cl: dict, fields: tuple) -> dict:
    return {k: cl.get(k) for k in fields}


def _cfg_hash(d: dict) -> str:
    canonical = json.dumps(d, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.blake2b(canonical.encode(), digest_size=8).hexdigest()


# ---------------------------------------------------------------------------
# Stage 1: UMAP fit (corpus only, keypapers decoupled)
# ---------------------------------------------------------------------------

def stage_umap(corpus_root: str, r2_cfg: dict, config_name: str,
               cl: dict, umap_hash: str):
    bucket = r2_cfg["bucket"]
    prefix = f"intermediate/config={config_name}/umap_cfg={umap_hash}"
    keys = {
        "model":  f"{prefix}/umap_model.pkl",
        "coords": f"{prefix}/umap_coords.parquet",
        "meta":   f"{prefix}/meta.json",
    }
    client = _r2_client(r2_cfg)

    if _r2_exists(client, bucket, keys["model"]) and _r2_exists(client, bucket, keys["coords"]):
        print(f"[cache hit] UMAP: s3://{bucket}/{prefix}")
        umap_model = _unpickle_from_r2(client, bucket, keys["model"])
        umap_coords = _parquet_from_r2(client, bucket, keys["coords"])
        return umap_model, umap_coords

    print(f"[cache miss] UMAP: s3://{bucket}/{prefix}")
    print("[step] reading corpus primary variant for UMAP fit")
    df_corpus = _read_full_variant_with_text(corpus_root, cl["primary_variant"], r2_cfg)
    n_corpus = len(df_corpus)
    print(f"        loaded {n_corpus:,} corpus rows")
    _heartbeat()

    # Extract everything we need from df_corpus, then DROP IT before
    # cuml.UMAP.fit_transform runs. df_corpus holds title + abstract text
    # for the whole corpus (~50-70 GB at 4.6M rows); keeping it alive
    # through fit_transform causes OOM on pods with <120 GB host RAM.
    # We don't need text again until the c-TF-IDF stage, which re-reads
    # it from R2 via duckdb. ids + X are all we need for UMAP + downstream.
    ids = df_corpus["id"].astype(str).values
    X = _matrix_from_df(df_corpus)
    del df_corpus
    gc.collect()
    _heartbeat()

    print(f"[step] cuml.UMAP fit_transform on {n_corpus:,} corpus rows")
    from cuml.manifold import UMAP as cumlUMAP
    umap_model = cumlUMAP(
        n_components=int(cl.get("umap_n_components", 5)),
        n_neighbors=int(cl.get("umap_n_neighbors",  30)),
        min_dist=float(cl.get("umap_min_dist",       0.0)),
        metric=cl.get("umap_metric", "cosine"),
        random_state=int(cl.get("random_seed", 13)),
    )
    t0 = time.time()
    umap_arr = umap_model.fit_transform(X)
    print(f"[time] UMAP fit_transform: {time.time() - t0:.1f}s")
    _heartbeat()

    n_comp = umap_arr.shape[1]
    coord_cols = [f"V{i+1}" for i in range(n_comp)]
    umap_coords = pd.DataFrame(np.asarray(umap_arr, dtype=np.float32), columns=coord_cols)
    umap_coords.insert(0, "id", ids)

    # Free large host-side arrays before pickle (cuml model keeps its own GPU copy).
    del X, umap_arr
    gc.collect()
    _heartbeat()

    print(f"[cache write] UMAP model + coords to s3://{bucket}/{prefix}")
    _pickle_to_r2(client, bucket, keys["model"], umap_model)
    _parquet_to_r2(client, bucket, keys["coords"], umap_coords)
    _meta_to_r2(client, bucket, keys["meta"], _cfg_subset(cl, _UMAP_FIELDS), "umap")
    _heartbeat()

    return umap_model, umap_coords


# ---------------------------------------------------------------------------
# Stage 2: HDBSCAN fit
# ---------------------------------------------------------------------------

def stage_hdbscan(umap_coords: pd.DataFrame, r2_cfg: dict, config_name: str,
                  cl: dict, umap_hash: str, hdbscan_hash: str):
    bucket = r2_cfg["bucket"]
    prefix = f"intermediate/config={config_name}/umap_cfg={umap_hash}/hdbscan_cfg={hdbscan_hash}"
    keys = {
        "model":  f"{prefix}/hdbscan_model.pkl",
        "topics": f"{prefix}/topics.parquet",
        "meta":   f"{prefix}/meta.json",
    }
    client = _r2_client(r2_cfg)

    if _r2_exists(client, bucket, keys["model"]) and _r2_exists(client, bucket, keys["topics"]):
        print(f"[cache hit] HDBSCAN: s3://{bucket}/{prefix}")
        hdbscan_model = _unpickle_from_r2(client, bucket, keys["model"])
        topics_corpus = _parquet_from_r2(client, bucket, keys["topics"])
        return hdbscan_model, topics_corpus

    print(f"[cache miss] HDBSCAN: s3://{bucket}/{prefix}")
    coord_cols = sorted(
        [c for c in umap_coords.columns if c.startswith("V") and c[1:].isdigit()],
        key=lambda c: int(c[1:])
    )
    X_umap = umap_coords[coord_cols].to_numpy(dtype=np.float32)

    print(f"[step] cuml.HDBSCAN fit_predict on {len(umap_coords):,} UMAP coords")
    from cuml.cluster import HDBSCAN as cumlHDBSCAN
    hdbscan_model = cumlHDBSCAN(
        min_cluster_size=int(cl["hdbscan_min_cluster_size"]),
        min_samples=int(cl["hdbscan_min_samples"]),
        metric="euclidean",
        cluster_selection_method="eom",
        prediction_data=True,
    )
    t0 = time.time()
    labels = hdbscan_model.fit_predict(X_umap)
    print(f"[time] HDBSCAN fit_predict: {time.time() - t0:.1f}s")
    _heartbeat()

    topics_corpus = pd.DataFrame({
        "id": umap_coords["id"].astype(str).values,
        "topic_id": np.asarray(labels, dtype=np.int64),
        "topic_source": "embedding",
        "probability": np.nan,
    })

    del X_umap
    gc.collect()

    print(f"[cache write] HDBSCAN model + topics to s3://{bucket}/{prefix}")
    _pickle_to_r2(client, bucket, keys["model"], hdbscan_model)
    _parquet_to_r2(client, bucket, keys["topics"], topics_corpus)
    _meta_to_r2(client, bucket, keys["meta"], _cfg_subset(cl, _HDBSCAN_FIELDS), "hdbscan")
    _heartbeat()

    return hdbscan_model, topics_corpus


# ---------------------------------------------------------------------------
# Stage 3: c-TF-IDF on per-topic concatenated docs
# ---------------------------------------------------------------------------
#
# This is the memory-friendly replacement for BERTopic's Representation step
# that OOM'd on the 116 GB pod. Instead of tokenizing 4.6M individual
# documents, we group corpus docs by topic_id, concatenate within each topic,
# then run CountVectorizer on the resulting ~500 topic-documents. That's
# ~10K-fold reduction in tokenizer input size.

def stage_ctfidf(corpus_root: str, topics_corpus: pd.DataFrame,
                 r2_cfg: dict, config_name: str, cl: dict,
                 umap_hash: str, hdbscan_hash: str, ctfidf_hash: str):
    bucket = r2_cfg["bucket"]
    prefix = (f"intermediate/config={config_name}/umap_cfg={umap_hash}/"
              f"hdbscan_cfg={hdbscan_hash}/ctfidf_cfg={ctfidf_hash}")
    keys = {
        "info":  f"{prefix}/topic_info.parquet",
        "words": f"{prefix}/topic_words.parquet",
        "meta":  f"{prefix}/meta.json",
    }
    client = _r2_client(r2_cfg)

    if _r2_exists(client, bucket, keys["info"]) and _r2_exists(client, bucket, keys["words"]):
        print(f"[cache hit] c-TF-IDF: s3://{bucket}/{prefix}")
        topic_info  = _parquet_from_r2(client, bucket, keys["info"])
        topic_words = _parquet_from_r2(client, bucket, keys["words"])
        return topic_info, topic_words

    print(f"[cache miss] c-TF-IDF: s3://{bucket}/{prefix}")

    print("[step] reading corpus text (id + title_clean + abstract_clean)")
    df_text = _read_text_only(corpus_root, cl["primary_variant"], r2_cfg)
    print(f"        loaded {len(df_text):,} corpus text rows")
    _heartbeat()

    df = df_text.merge(
        topics_corpus[["id", "topic_id"]].astype({"id": str}),
        on="id", how="inner"
    )
    del df_text
    gc.collect()

    df["doc"] = (df["title_clean"].fillna("").astype(str)
                 + " "
                 + df["abstract_clean"].fillna("").astype(str))
    df = df[df["topic_id"] >= 0]

    print(f"[step] aggregating corpus docs per topic ({df['topic_id'].nunique()} topics)")
    docs_per_topic = (
        df.groupby("topic_id", sort=True)["doc"]
          .apply(lambda s: " ".join(s.values))
          .reset_index()
    )
    del df
    gc.collect()
    _heartbeat()

    print(f"[step] CountVectorizer + TfidfTransformer on {len(docs_per_topic)} topic-documents")
    from sklearn.feature_extraction.text import CountVectorizer, TfidfTransformer
    cv = CountVectorizer(
        stop_words="english",
        min_df=int(cl.get("vectorizer_min_df", 2)),
        max_df=float(cl.get("vectorizer_max_df", 0.95)),
        max_features=int(cl.get("vectorizer_max_features", 20_000)),
        ngram_range=tuple(cl.get("vectorizer_ngram", [1, 2])),
    )
    counts = cv.fit_transform(docs_per_topic["doc"].values)
    tfidf = TfidfTransformer(smooth_idf=True, sublinear_tf=False)
    weights = tfidf.fit_transform(counts).toarray()
    vocab = np.array(cv.get_feature_names_out())
    _heartbeat()

    top_n = int(cl.get("top_n_words", 15))
    word_rows = []
    info_rows = []
    for i, tid in enumerate(docs_per_topic["topic_id"].values):
        w = weights[i]
        top_idx = np.argsort(-w)[:top_n]
        top_words_list = []
        for rank, idx in enumerate(top_idx, start=1):
            word = str(vocab[idx])
            weight = float(w[idx])
            word_rows.append({"topic_id": int(tid), "word": word,
                              "weight": weight, "rank": rank})
            top_words_list.append(word)
        label = f"{int(tid)}_" + "_".join(top_words_list[:4])
        info_rows.append({
            "topic_id": int(tid),
            "label": label,
            "top_words": top_words_list,
        })

    topic_words = pd.DataFrame(word_rows)
    topic_info  = pd.DataFrame(info_rows)

    # Include noise topic if any rows fell into it (always with empty words).
    if (topics_corpus["topic_id"] == -1).any():
        topic_info = pd.concat([
            topic_info,
            pd.DataFrame([{"topic_id": -1, "label": "-1_noise", "top_words": []}])
        ], ignore_index=True)

    print(f"[cache write] c-TF-IDF outputs to s3://{bucket}/{prefix}")
    _parquet_to_r2(client, bucket, keys["info"],  topic_info)
    _parquet_to_r2(client, bucket, keys["words"], topic_words)
    _meta_to_r2(client, bucket, keys["meta"], _cfg_subset(cl, _CTFIDF_FIELDS), "ctfidf")
    _heartbeat()

    return topic_info, topic_words


# ---------------------------------------------------------------------------
# Stage 4: Project keypapers (decoupled — Option A from TODO)
# ---------------------------------------------------------------------------

def stage_project_keypapers(refer_root: str, umap_model, hdbscan_model,
                            r2_cfg: dict, cl: dict) -> pd.DataFrame:
    print("[step] projecting keypapers into fitted UMAP + HDBSCAN")
    df_kp = _read_full_variant_with_text(refer_root, cl["primary_variant"], r2_cfg)
    print(f"        loaded {len(df_kp):,} keypapers")
    X_kp = _matrix_from_df(df_kp)

    umap_kp = umap_model.transform(X_kp)
    from cuml.cluster.hdbscan import approximate_predict
    labels_kp, probs_kp = approximate_predict(hdbscan_model, umap_kp)

    return pd.DataFrame({
        "id": df_kp["id"].astype(str).values,
        "source": "keypaper",
        "topic_id": np.asarray(labels_kp, dtype=np.int64),
        "topic_source": "projected",
        "probability": np.asarray(probs_kp, dtype=np.float64),
    })


# ---------------------------------------------------------------------------
# Stage 5: Fallback variant projection (no-abstract corpus works)
# ---------------------------------------------------------------------------

def stage_project_fallback(corpus_root: str, umap_model, hdbscan_model,
                           r2_cfg: dict, cl: dict) -> pd.DataFrame:
    fallback = cl.get("fallback_variant")
    empty_cols = ["id", "source", "topic_id", "topic_source", "probability"]
    if not fallback:
        return pd.DataFrame(columns=empty_cols)

    print(f"[step] streaming fallback variant ({fallback}) for no-primary corpus works")
    from cuml.cluster.hdbscan import approximate_predict

    fb_chunks = []
    n_done = 0
    for chunk in _stream_variant_minus_primary(
        corpus_root, fallback, cl["primary_variant"], r2_cfg, chunk_rows=50_000
    ):
        X_chunk = _matrix_from_df(chunk)
        umap_chunk = umap_model.transform(X_chunk)
        labels, probs = approximate_predict(hdbscan_model, umap_chunk)
        fb_chunks.append(pd.DataFrame({
            "id": chunk["id"].astype(str).values,
            "source": "corpus",
            "topic_id": np.asarray(labels, dtype=np.int64),
            "topic_source": "fallback",
            "probability": np.asarray(probs, dtype=np.float64),
        }))
        n_done += len(chunk)
        print(f"        fallback {n_done:,}")
        _heartbeat()
        del chunk, X_chunk, umap_chunk

    if not fb_chunks:
        return pd.DataFrame(columns=empty_cols)
    return pd.concat(fb_chunks, ignore_index=True)


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
    _start_heartbeat_thread(interval_s=30)

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

    r2_cfg = cl.get("r2", {}) or {}
    if not r2_cfg.get("endpoint") or not r2_cfg.get("bucket"):
        raise SystemExit(
            "Stage caching requires cfg.r2.endpoint and cfg.r2.bucket. "
            "Either populate them or revert to a pre-v0.1.8 image for the "
            "monolithic flow."
        )

    primary  = cl["primary_variant"]
    fallback = cl.get("fallback_variant")
    print(f"[info] config_name = {config_name}")
    print(f"[info] run_name    = {run_name}")
    print(f"[info] primary     = {primary}    fallback = {fallback}")
    print(f"[info] r2 endpoint = {r2_cfg['endpoint']}  bucket = {r2_cfg['bucket']}")

    # Cascade cfg hashes — printed up front so cache hits/misses are easy to
    # trace in the log.
    umap_hash    = _cfg_hash(_cfg_subset(cl, _UMAP_FIELDS))
    hdbscan_hash = _cfg_hash(_cfg_subset(cl, _HDBSCAN_FIELDS))
    ctfidf_hash  = _cfg_hash(_cfg_subset(cl, _CTFIDF_FIELDS))
    print(f"[info] cfg hashes  umap={umap_hash}  hdbscan={hdbscan_hash}  ctfidf={ctfidf_hash}")

    # -------- Stage 1: UMAP fit (or load) --------------------------------
    umap_model, umap_coords = stage_umap(corpus_root, r2_cfg, config_name, cl, umap_hash)
    _heartbeat()

    # -------- Stage 2: HDBSCAN fit (or load) -----------------------------
    hdbscan_model, topics_corpus = stage_hdbscan(
        umap_coords, r2_cfg, config_name, cl, umap_hash, hdbscan_hash
    )
    _heartbeat()

    # UMAP coords table no longer needed beyond this point.
    del umap_coords
    gc.collect()

    # -------- Stage 3: c-TF-IDF on per-topic docs (or load) --------------
    topic_info, topic_words = stage_ctfidf(
        corpus_root, topics_corpus, r2_cfg, config_name, cl,
        umap_hash, hdbscan_hash, ctfidf_hash
    )
    _heartbeat()

    # -------- Stage 4: project keypapers ---------------------------------
    topics_kp = stage_project_keypapers(refer_root, umap_model, hdbscan_model, r2_cfg, cl)
    _heartbeat()

    # -------- Stage 5: project fallback variant --------------------------
    topics_fb = stage_project_fallback(corpus_root, umap_model, hdbscan_model, r2_cfg, cl)
    _heartbeat()

    # -------- Stage 6: combine + per-topic counts + final outputs --------
    print("[step] composing final outputs")
    topics_corpus_out = topics_corpus.copy()
    topics_corpus_out["source"] = "corpus"
    out_topics = pd.concat([topics_corpus_out, topics_kp, topics_fb], ignore_index=True)
    out_topics["topic_id"] = out_topics["topic_id"].astype(np.int64)

    cnt = (
        out_topics.groupby(["topic_id", "source"]).size()
        .unstack(fill_value=0).reset_index()
    )
    if "corpus"   not in cnt.columns: cnt["corpus"]   = 0
    if "keypaper" not in cnt.columns: cnt["keypaper"] = 0
    cnt = cnt.rename(columns={"corpus": "n_corpus", "keypaper": "n_keypapers"})

    kp_thresh = int(cl.get("keypaper_threshold", 3))
    info = topic_info.merge(cnt[["topic_id", "n_corpus", "n_keypapers"]],
                            on="topic_id", how="left")
    info["n_corpus"]    = info["n_corpus"].fillna(0).astype(int)
    info["n_keypapers"] = info["n_keypapers"].fillna(0).astype(int)
    info["n_total"]     = info["n_corpus"] + info["n_keypapers"]
    info["is_relevant"] = info["n_keypapers"] >= kp_thresh

    out_dir = _leaf_dir(out_root, config_name, run_name, primary)
    print(f"[step] writing parquets to {out_dir}")
    out_topics.to_parquet( out_dir / "topics.parquet",      index=False)
    info.to_parquet(       out_dir / "topic_info.parquet",  index=False)
    topic_words.to_parquet(out_dir / "topic_words.parquet", index=False)

    n_topics = int((info["topic_id"] >= 0).sum())
    n_noise  = int((out_topics["topic_id"] == -1).sum())
    n_fb     = int((out_topics["topic_source"] == "fallback").sum())
    n_proj   = int((out_topics["topic_source"] == "projected").sum())
    print(f"[done] topics={n_topics}  noise={n_noise:,}  fallback={n_fb:,}  keypapers_projected={n_proj}")
    print(str(out_dir / "topic_info.parquet"))
    _heartbeat()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
