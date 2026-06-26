run_bertopic <- function(
  corpus_emb_dir,
  reference_emb_dir,
  out_dir,
  cfg_path = "input/config.yaml",
  ...   # ignored — used by _targets.R to declare extra DAG deps
        # (clustering_cfg, fallback_corpus, fallback_ref)
) {
  # Inputs must share their parent (config=<X>) — same invariant score_keypapers
  # enforces, kept consistent here for predictability.
  config_dir_corpus <- dirname(corpus_emb_dir)
  config_dir_ref    <- dirname(reference_emb_dir)
  if (!identical(config_dir_corpus, config_dir_ref)) {
    stop(
      "corpus and reference embeddings must share the same config dir.\n",
      "  corpus:    ", config_dir_corpus, "\n",
      "  reference: ", config_dir_ref
    )
  }

  # Locate the project-local venv. When this function moves into
  # openalexVectorComp, swap this for a per-OS cache lookup (mirroring
  # OVC_SPECTER2_PATH).
  repo_root <- normalizePath(".", mustWork = TRUE)
  venv_python <- file.path(repo_root, ".venv", "bin", "python")
  if (!file.exists(venv_python)) {
    stop(
      "Project venv python not found at: ", venv_python, "\n",
      "Run: python3 -m venv .venv && ./.venv/bin/pip install bertopic pyarrow pyyaml"
    )
  }

  script <- file.path(repo_root, "scripts", "run_bertopic.py")
  if (!file.exists(script)) {
    stop("Expected scripts/run_bertopic.py at: ", script)
  }

  args <- c(
    shQuote(script),
    "--corpus-emb-dir",    shQuote(normalizePath(corpus_emb_dir,    mustWork = TRUE)),
    "--reference-emb-dir", shQuote(normalizePath(reference_emb_dir, mustWork = TRUE)),
    "--output-dir",        shQuote(normalizePath(out_dir, mustWork = FALSE)),
    "--config-yaml",       shQuote(normalizePath(cfg_path, mustWork = TRUE))
  )

  status <- system2(venv_python, args = args, stdout = "", stderr = "")
  if (status != 0L) {
    stop("scripts/run_bertopic.py exited with status ", status)
  }

  # Build the expected output path from the same convention the script uses:
  # <out_dir>/config=<X>/variant=<primary>/topic_info.parquet
  cfg <- yaml::read_yaml(cfg_path)
  config_name <- sub("^config=", "", basename(config_dir_corpus))
  primary     <- cfg$clustering$primary_variant
  topic_info_path <- file.path(
    out_dir,
    paste0("config=", config_name),
    paste0("variant=", primary),
    "topic_info.parquet"
  )
  if (!file.exists(topic_info_path)) {
    stop("Expected output not found: ", topic_info_path)
  }
  topic_info_path
}
