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
  if (file.exists(marker_path) && file.exists(topic_info_path)) {
    message(sprintf(
      "[bertopic_local|%s] leaf already complete — skipping run.", run_name
    ))
    return(topic_info_path)
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
  write_topics_marker(leaf_dir, run_name)

  topic_info_path
}

# ----------------------------------------------------------------------------
# Marker helpers (parallel to embed_works.R's write_embed_marker /
# read_embed_marker). Skip-guard fires on presence, not on a row-count match,
# because BERTopic outputs are small and easy to recompute if needed.
# ----------------------------------------------------------------------------
topics_marker_path <- function(leaf_dir) {
  file.path(leaf_dir, ".topics_complete")
}

read_topics_marker <- function(leaf_dir) {
  p <- topics_marker_path(leaf_dir)
  if (!file.exists(p)) return(NA_character_)
  readLines(p, n = 1L, warn = FALSE)
}

write_topics_marker <- function(leaf_dir, run_name) {
  dir.create(leaf_dir, recursive = TRUE, showWarnings = FALSE)
  writeLines(
    c(run_name, format(Sys.time(), tz = "UTC")),
    topics_marker_path(leaf_dir)
  )
}

# Local null-coalescing for use inside the function above. Kept private; the
# openalexVectorComp version of this file should use rlang::%||% or define
# the same helper at the top of the file.
`%||%` <- function(x, y) if (is.null(x)) y else x
