embed_works <- function(
  corpus_path,
  out_dir,
  source,
  config_name,
  cfg,
  variants = NULL
) {
  if (!source %in% c("corpus", "keypaper")) {
    stop("`source` must be 'corpus' or 'keypaper', got: ", source)
  }
  if (!is.character(config_name) || length(config_name) != 1L || !nzchar(config_name)) {
    stop("`config_name` must be a non-empty string")
  }

  if (is.null(variants)) {
    variants <- list(
      title          = list(prep = preprocessor_title),
      abstract       = list(prep = preprocessor_abstract),
      title_abstract = list(
        prep = preprocessor_title_abstract,
        args = list(
          sep       = cfg$sep_token,
          title_cap = cfg$title_cap_combined
        )
      )
    )
  }

  backend <- openalexVectorComp::backend_specter2_tei(
    host  = cfg$host,
    port  = cfg$port,
    model = cfg$model
  )
  # Override the TEI-reported max_client_batch_size with our cfg value, so the
  # client packs more inputs into each HTTP request (TEI internally re-batches
  # to fit max_batch_tokens).
  if (!is.null(cfg$max_batch_size)) {
    backend$max_batch_size <- as.integer(cfg$max_batch_size)
  }
  # Mirror whatever embed_corpus writes (model_id from backend_info — driven by
  # TEI's served_model_name when configured).
  info <- openalexVectorComp::backend_info(backend)
  model_id   <- if (!is.null(info$model_id) && nzchar(info$model_id)) info$model_id else cfg$model
  model_part <- gsub("/", "_", model_id, fixed = TRUE)

  project_folder <- dirname(corpus_path)
  corpus_name    <- basename(corpus_path)

  scratch_root <- file.path(out_dir, ".raw", config_name, source)
  unlink(scratch_root, recursive = TRUE)
  dir.create(scratch_root, recursive = TRUE, showWarnings = FALSE)

  per_variant_dfs <- list()

  for (vname in names(variants)) {
    v <- variants[[vname]]
    cleaner_args <- if (is.null(v$args)) list() else v$args

    message(sprintf("--- config = %s, source = %s, variant = %s ---",
                    config_name, source, vname))

    scratch_project <- file.path(scratch_root, vname)
    dir.create(scratch_project, recursive = TRUE, showWarnings = FALSE)
    file.symlink(
      normalizePath(corpus_path, mustWork = TRUE),
      file.path(scratch_project, corpus_name)
    )

    openalexVectorComp::embed_corpus(
      project_dir       = scratch_project,
      backend           = backend,
      corpus_name       = corpus_name,
      label             = vname,
      batch_size        = cfg$batch_size,
      text_preprocessor = v$prep,
      cleaner_args      = cleaner_args,
      verbose           = FALSE
    )

    raw_label_dir <- file.path(
      scratch_project, "embeddings",
      paste0("model_id=", model_part),
      paste0("label=", vname)
    )

    df <- arrow::open_dataset(
      raw_label_dir,
      factory_options = list(exclude_invalid_files = TRUE)
    ) |>
      dplyr::collect()
    df$config  <- config_name
    df$source  <- source
    df$variant <- vname
    per_variant_dfs[[vname]] <- df
  }

  combined <- dplyr::bind_rows(per_variant_dfs)

  arrow::write_dataset(
    combined,
    path         = out_dir,
    partitioning = c("config", "source", "variant"),
    format       = "parquet",
    existing_data_behavior = "delete_matching"
  )

  unlink(scratch_root, recursive = TRUE)

  file.path(out_dir, paste0("config=", config_name), paste0("source=", source))
}
