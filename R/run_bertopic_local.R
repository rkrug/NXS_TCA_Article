# Local-mode BERTopic wrapper.
#
# Drives scripts/run_bertopic_local.py via the project venv. Same shape as the
# original R/run_bertopic.R wrapper, with these changes:
#   - cfg is passed as a one-config YAML the script can consume directly
#     (decouples the script from the project's full config.yaml layout)
#   - output leaf path includes bertopic=<run_name> for side-by-side runs
#   - skip-guard on .topics_complete marker
#
# Designed for migration into openalexVectorComp: signature uses only public
# pieces of the repo, no hidden state, no env-side dependencies beyond a
# project venv with bertopic + umap-learn + hdbscan.

run_bertopic_local <- function(
  corpus_emb_dir,
  reference_emb_dir,
  out_dir,
  cfg,
  run_name,
  ...   # ignored — dep tokens for targets DAG (fallback_corpus, fallback_ref)
) {
  # ---- arg validation ---------------------------------------------------
  if (!is.list(cfg) || !nzchar(cfg$primary_variant %||% "")) {
    stop("`cfg` must be a list with at least `primary_variant`.")
  }
  if (!is.character(run_name) || length(run_name) != 1L || !nzchar(run_name)) {
    stop("`run_name` must be a non-empty string.")
  }

  config_dir_corpus <- dirname(corpus_emb_dir)
  config_dir_ref    <- dirname(reference_emb_dir)
  if (!identical(config_dir_corpus, config_dir_ref)) {
    stop(
      "corpus and reference embeddings must share the same config dir.\n",
      "  corpus:    ", config_dir_corpus, "\n",
      "  reference: ", config_dir_ref
    )
  }
  config_name <- sub("^config=", "", basename(config_dir_corpus))
  primary     <- cfg$primary_variant

  leaf_dir <- file.path(
    out_dir,
    paste0("config=",   config_name),
    paste0("bertopic=", run_name),
    paste0("variant=",  primary)
  )
  topic_info_path <- file.path(leaf_dir, "topic_info.parquet")
  marker_path     <- file.path(leaf_dir, ".topics_complete")

  # ---- skip-guard -------------------------------------------------------
  # Cfg-aware: skip only if the prior run was driven by an IDENTICAL cfg.
  # The marker stores a hash of the cfg used; if the cfg changes (e.g. you
  # bumped hdbscan_min_cluster_size), the hash mismatches and we re-run.
  # The Python script overwrites the three output parquets, so we don't
  # need to wipe the leaf first.
  current_cfg_hash <- paste0(
    .topics_cfg_hash(cfg), "_", .reference_fingerprint(reference_emb_dir)
  )
  if (file.exists(marker_path) && file.exists(topic_info_path)) {
    marker <- read_topics_marker(leaf_dir)
    if (!is.na(marker$cfg_hash) &&
        identical(marker$cfg_hash, current_cfg_hash)) {
      message(sprintf(
        "[bertopic_local|%s] leaf already complete with matching cfg — skipping run.",
        run_name
      ))
      return(topic_info_path)
    }
    if (is.na(marker$cfg_hash)) {
      message(sprintf(
        "[bertopic_local|%s] marker has no cfg hash (older format) — re-running to refresh.",
        run_name
      ))
    } else {
      message(sprintf(
        "[bertopic_local|%s] cfg changed since last run (hash %s -> %s) — re-running.",
        run_name, substr(marker$cfg_hash, 1, 8), substr(current_cfg_hash, 1, 8)
      ))
    }
  }

  # ---- locate the project venv -----------------------------------------
  repo_root   <- normalizePath(".", mustWork = TRUE)
  venv_python <- file.path(repo_root, ".venv", "bin", "python")
  if (!file.exists(venv_python)) {
    stop(
      "Project venv python not found at: ", venv_python, "\n",
      "Run: python3 -m venv .venv && ",
      "./.venv/bin/pip install bertopic umap-learn hdbscan pyarrow pyyaml scikit-learn"
    )
  }
  script <- file.path(repo_root, "scripts", "run_bertopic_local.py")
  if (!file.exists(script)) stop("Expected scripts/run_bertopic_local.py at: ", script)

  # ---- write the single-config YAML the script consumes ---------------
  cfg_tmp <- tempfile(pattern = "bertopic_cfg_", fileext = ".yaml")
  on.exit(unlink(cfg_tmp), add = TRUE)
  yaml::write_yaml(cfg, cfg_tmp)

  # ---- invoke ----------------------------------------------------------
  args <- c(
    shQuote(script),
    "--corpus-emb-dir",    shQuote(normalizePath(corpus_emb_dir,    mustWork = TRUE)),
    "--reference-emb-dir", shQuote(normalizePath(reference_emb_dir, mustWork = TRUE)),
    "--output-dir",        shQuote(normalizePath(out_dir, mustWork = FALSE)),
    "--bertopic-cfg-yaml", shQuote(cfg_tmp),
    "--run-name",          shQuote(run_name)
  )

  message(sprintf("[bertopic_local|%s] dispatching script", run_name))
  status <- system2(venv_python, args = args, stdout = "", stderr = "")
  if (status != 0L) {
    stop("scripts/run_bertopic_local.py exited with status ", status)
  }

  # ---- validate + stamp marker ------------------------------------------
  expected <- c("topic_info.parquet", "topics.parquet", "topic_words.parquet")
  missing  <- expected[!file.exists(file.path(leaf_dir, expected))]
  if (length(missing)) {
    stop("Expected outputs missing in ", leaf_dir, ": ",
         paste(missing, collapse = ", "))
  }
  write_topics_marker(leaf_dir, run_name, current_cfg_hash)

  topic_info_path
}

# ----------------------------------------------------------------------------
# Marker helpers (parallel to embed_works.R's write_embed_marker /
# read_embed_marker). Marker file is three lines:
#
#     <run_name>
#     <UTC timestamp>
#     <cfg_hash>          # xxhash64 of the bertopic cfg list
#
# Skip-guard fires only when the stored cfg_hash matches the current cfg's
# hash — so a config change invalidates the cached result automatically.
# Older 2-line markers (no cfg_hash) return NA and force a refresh on
# next invocation.
# ----------------------------------------------------------------------------
topics_marker_path <- function(leaf_dir) {
  file.path(leaf_dir, ".topics_complete")
}

read_topics_marker <- function(leaf_dir) {
  p <- topics_marker_path(leaf_dir)
  if (!file.exists(p)) {
    return(list(run_name = NA_character_, timestamp = NA_character_,
                cfg_hash = NA_character_))
  }
  lines <- readLines(p, warn = FALSE)
  list(
    run_name  = if (length(lines) >= 1L) lines[1] else NA_character_,
    timestamp = if (length(lines) >= 2L) lines[2] else NA_character_,
    cfg_hash  = if (length(lines) >= 3L) lines[3] else NA_character_
  )
}

write_topics_marker <- function(leaf_dir, run_name, cfg_hash) {
  dir.create(leaf_dir, recursive = TRUE, showWarnings = FALSE)
  writeLines(
    c(run_name, format(Sys.time(), tz = "UTC"),
      if (is.null(cfg_hash) || is.na(cfg_hash)) "" else cfg_hash),
    topics_marker_path(leaf_dir)
  )
}

# Stable hash of the bertopic cfg list, used by the skip-guard to detect
# cfg-driven changes. Sorts keys for a canonical form so cosmetic re-ordering
# in YAML doesn't trigger spurious re-runs. xxhash64 is fast and fine for
# change detection (not a cryptographic guarantee).
.topics_cfg_hash <- function(cfg) {
  if (!is.list(cfg)) return(NA_character_)
  if (!requireNamespace("digest", quietly = TRUE)) {
    warning("Package `digest` not available; skip-guard cfg comparison disabled.")
    return(NA_character_)
  }
  cfg_sorted <- cfg[order(names(cfg))]
  digest::digest(cfg_sorted, algo = "xxhash64")
}

# Lightweight content-sensitive fingerprint of a reference (keypaper)
# embedding directory, folded into the skip-guard hash alongside cfg.
# .topics_cfg_hash() alone can't detect "the keypaper SET changed but
# bertopic params didn't" — e.g. swapping the keypaper input file and
# re-embedding produces an identical cfg_hash, so the skip-guard would
# silently keep serving results scored against the OLD keypaper set. This
# closes that gap by fingerprinting the files that will actually be scored.
# Uses path + size + mtime rather than full content hashing — cheap even
# for large leaves, and any real change (new/removed/rewritten parquet)
# touches at least one of these.
.reference_fingerprint <- function(reference_emb_dir) {
  files <- list.files(
    reference_emb_dir, recursive = TRUE, full.names = TRUE,
    pattern = "\\.parquet$"
  )
  if (!length(files)) return(NA_character_)
  info <- file.info(files)
  fp <- paste(
    sort(paste(basename(files), info$size, format(info$mtime, "%Y%m%d%H%M%S"))),
    collapse = "|"
  )
  if (!requireNamespace("digest", quietly = TRUE)) return(fp)
  digest::digest(fp, algo = "xxhash64")
}

# Local null-coalescing for use inside the function above. Kept private; the
# openalexVectorComp version of this file should use rlang::%||% or define
# the same helper at the top of the file.
`%||%` <- function(x, y) if (is.null(x)) y else x
