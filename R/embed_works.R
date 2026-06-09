# Embed one (source, variant) pair and write to a hive-partitioned leaf.
#
# Single-variant target so each (source, variant) is independently invalidatable
# in the targets DAG. Earlier "embed all three variants in one call" version is
# gone — see plan: let-s-distangle-that-construct-glistening-umbrella.md.
#
# Skip guard: if the leaf partition already contains parquet rows, return its
# path without touching TEI. Makes the function idempotent across targets
# metadata loss, and lets pre-existing embeddings be registered cheaply.
#
# Progress: a background callr watcher tails the scratch dir and emits
# rate / elapsed / ETA after each shard the embedder writes.
#
# Remote TEI (RunPod): cfg may set `scheme: https`, plus
# `auth_token_keyring: <keyring entry>` to pull a bearer token. Otherwise
# defaults to plain http://host:port/embed (local Metal TEI).

embed_works <- function(
  corpus_path,
  out_dir,
  source,
  config_name,
  cfg,
  variant_name,
  preprocessor,
  preprocessor_args = list()
) {
  if (!source %in% c("corpus", "keypaper")) {
    stop("`source` must be 'corpus' or 'keypaper', got: ", source)
  }
  if (!is.character(variant_name) || length(variant_name) != 1L ||
      !nzchar(variant_name)) {
    stop("`variant_name` must be a non-empty string.")
  }
  if (!is.character(config_name) || length(config_name) != 1L ||
      !nzchar(config_name)) {
    stop("`config_name` must be a non-empty string.")
  }

  leaf_dir <- file.path(
    out_dir,
    paste0("config=",  config_name),
    paste0("source=",  source),
    paste0("variant=", variant_name)
  )

  # ---- Skip guard ---------------------------------------------------------
  # Marker-based wholeness check:
  #   * marker present  → trust if marker count == actual leaf count; on
  #                       mismatch the leaf is partial → wipe + re-embed.
  #   * marker absent   → migration case (existing parquets from before this
  #                       refactor). Trust the leaf at face value and stamp a
  #                       marker. We deliberately don't run the preprocessor
  #                       here — on the full corpus the per-row `clean_text`
  #                       pass OOM's the worker before TEI is even contacted.
  # Future runs always write a marker on success, so partial-run detection
  # kicks in from the next embed_works invocation onward.
  existing_parquets <- list.files(
    leaf_dir, pattern = "\\.parquet$", recursive = TRUE, full.names = FALSE
  )
  if (length(existing_parquets) > 0L) {
    # exclude_invalid_files = TRUE skips non-parquet files like our
    # `.embed_complete` marker; without it arrow would error on the marker
    # and we'd misread n_have as NA → could wipe a complete leaf.
    n_have <- tryCatch(
      nrow(arrow::open_dataset(
        leaf_dir,
        factory_options = list(exclude_invalid_files = TRUE)
      )),
      error = function(e) NA_integer_
    )
    n_expected <- read_embed_marker(leaf_dir)

    if (is.na(n_expected)) {
      message(sprintf(
        "[%s|%s] leaf has %s rows, no completion marker — trusting (migration) and stamping marker.",
        source, variant_name,
        if (is.na(n_have)) "?" else format(n_have, big.mark = ",")
      ))
      if (!is.na(n_have)) write_embed_marker(leaf_dir, n_have)
      return(leaf_dir)
    }

    if (!is.na(n_have) && n_have == n_expected) {
      message(sprintf(
        "[%s|%s] leaf complete (%s rows) — skipping TEI.",
        source, variant_name, format(n_have, big.mark = ",")
      ))
      return(leaf_dir)
    }

    # Belt-and-braces: if the row count couldn't be read AT ALL but parquet
    # files and a marker are present, refuse to wipe — that's a sign of
    # an arrow/version/permission problem we'd rather surface than silently
    # destroy completed work.
    if (is.na(n_have)) {
      stop(sprintf(
        "[%s|%s] leaf has %d parquet file(s) and a marker (%s rows), but arrow could not read the row count. Refusing to wipe. Investigate the leaf at %s before re-running.",
        source, variant_name, length(existing_parquets),
        format(n_expected, big.mark = ","), leaf_dir
      ))
    }

    message(sprintf(
      "[%s|%s] leaf partial: actual=%s vs marker=%s — wiping and re-embedding.",
      source, variant_name,
      format(n_have, big.mark = ","),
      format(n_expected, big.mark = ",")
    ))
    unlink(leaf_dir, recursive = TRUE)
  }

  # ---- Backend -----------------------------------------------------------
  backend <- build_tei_backend(cfg)
  info <- openalexVectorComp::backend_info(backend)
  model_id   <- if (!is.null(info$model_id) && nzchar(info$model_id)) {
    info$model_id
  } else {
    cfg$model
  }
  model_part <- gsub("/", "_", model_id, fixed = TRUE)

  # ---- Scratch dir layout (mirrors openalexVectorComp::embed_corpus) -----
  corpus_name <- basename(corpus_path)
  scratch_project <- file.path(
    out_dir, ".raw", config_name, source, variant_name
  )
  unlink(scratch_project, recursive = TRUE)
  dir.create(scratch_project, recursive = TRUE, showWarnings = FALSE)
  file.symlink(
    normalizePath(corpus_path, mustWork = TRUE),
    file.path(scratch_project, corpus_name)
  )
  raw_label_dir <- file.path(
    scratch_project, "embeddings",
    paste0("model_id=", model_part),
    paste0("label=", variant_name)
  )

  # ---- Progress watcher --------------------------------------------------
  n_in <- tryCatch(
    nrow(arrow::open_dataset(
      corpus_path,
      factory_options = list(exclude_invalid_files = TRUE)
    )),
    error = function(e) NA_integer_
  )
  watcher <- NULL
  if (!is.na(n_in) && n_in > 0) {
    watcher <- start_shard_watcher(
      scratch_dir = raw_label_dir,
      n_in        = n_in,
      batch_size  = cfg$batch_size,
      label       = sprintf("%s|%s", source, variant_name)
    )
    on.exit(stop_shard_watcher(watcher), add = TRUE)
  }

  # ---- Embed -------------------------------------------------------------
  message(sprintf(
    "--- config = %s, source = %s, variant = %s, input rows = %s ---",
    config_name, source, variant_name,
    if (is.na(n_in)) "?" else format(n_in, big.mark = ",")
  ))

  cleaner_args <- if (length(preprocessor_args)) preprocessor_args else list()
  # Local drop-in replacement for openalexVectorComp::embed_corpus() that
  # parallelises ONLY the HTTP layer when cfg$concurrency > 1. concurrency = 1
  # (the default) is behaviourally identical to a sequential embed_corpus().
  embed_corpus_parallel(
    project_dir       = scratch_project,
    backend           = backend,
    corpus_name       = corpus_name,
    label             = variant_name,
    batch_size        = cfg$batch_size,
    text_preprocessor = preprocessor,
    cleaner_args      = cleaner_args,
    concurrency       = if (is.null(cfg$concurrency)) 1L else as.integer(cfg$concurrency),
    verbose           = TRUE
  )

  # ---- Re-partition into a single consolidated parquet per leaf ---------
  # Output shape: <leaf_dir>/part-0.parquet — one file containing all rows,
  # with row groups of ~50K rows so analytical reads stay fast even though
  # the dataset is one file. config/source/variant are NOT written into the
  # parquet itself; hive partitioning encodes them in the path, and
  # arrow::open_dataset() synthesises them on read. A `batch` column is
  # added from each scratch shard's batch number so the original
  # embed_corpus_parallel ordering is recoverable.
  #
  # Streamed via duckdb's COPY — the arrow-side variants (collect first,
  # lazy mutate, Scanner+ParquetFileWriter) all OOM'd at 4–5M rows on
  # macOS. duckdb's parquet writer streams natively with bounded memory.
  if (!requireNamespace("duckdb", quietly = TRUE)) {
    stop("Package 'duckdb' is required for the embed_works consolidation step. ",
         "Install via: install.packages('duckdb')")
  }
  if (!requireNamespace("DBI", quietly = TRUE)) {
    stop("Package 'DBI' is required for the embed_works consolidation step.")
  }

  any_shard <- length(list.files(
    raw_label_dir, pattern = "[.]parquet$", recursive = TRUE
  ))
  if (any_shard == 0L) {
    stop("No scratch parquets found under: ", raw_label_dir)
  }

  dir.create(leaf_dir, recursive = TRUE, showWarnings = FALSE)
  out_tmp   <- file.path(leaf_dir, "part-0.parquet.tmp")
  out_final <- file.path(leaf_dir, "part-0.parquet")
  if (file.exists(out_tmp))   file.remove(out_tmp)
  if (file.exists(out_final)) file.remove(out_final)

  shards_glob <- file.path(raw_label_dir, "batch=*", "embeddings-*.parquet")
  message(sprintf(
    "[%s|%s] consolidating scratch shards into part-0.parquet via duckdb COPY",
    source, variant_name
  ))

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
  try(DBI::dbExecute(con, "PRAGMA enable_progress_bar"),       silent = TRUE)
  try(DBI::dbExecute(con, "PRAGMA progress_bar_time = 1000"),  silent = TRUE)

  copy_sql <- sprintf(
    "COPY (
       SELECT * EXCLUDE (filename),
              CAST(regexp_extract(filename, '-(\\d+)\\.parquet$', 1) AS INTEGER) AS batch
       FROM read_parquet('%s', filename = true)
     ) TO '%s' (FORMAT PARQUET, ROW_GROUP_SIZE 50000)",
    shards_glob, out_tmp
  )
  DBI::dbExecute(con, copy_sql)

  n_written <- as.integer(DBI::dbGetQuery(con, sprintf(
    "SELECT COUNT(*)::BIGINT AS n FROM read_parquet('%s')", out_tmp
  ))$n)

  DBI::dbDisconnect(con, shutdown = TRUE)
  file.rename(out_tmp, out_final)

  message(sprintf(
    "[%s|%s] consolidation done; wrote %s rows to %s",
    source, variant_name, format(n_written, big.mark = ","), out_final
  ))
  write_embed_marker(leaf_dir, n_written)

  unlink(scratch_project, recursive = TRUE)
  leaf_dir
}

# ----------------------------------------------------------------------------
# Backend builder.
# - cfg$scheme + cfg$host + cfg$port construct the TEI /embed URL.
# - cfg$auth_token_keyring (optional) names a keyring entry whose secret is
#   exported as OVC_API_TOKEN so the package's request layer attaches it as
#   Authorization: Bearer <token>.
# - cfg$max_batch_size overrides the TEI-reported max client batch size.
# ----------------------------------------------------------------------------
build_tei_backend <- function(cfg) {
  if (!is.null(cfg$auth_token_keyring) && nzchar(cfg$auth_token_keyring)) {
    tok <- tryCatch(
      keyring::key_get(cfg$auth_token_keyring),
      error = function(e) stop(sprintf(
        "Could not retrieve auth token from keyring entry '%s': %s",
        cfg$auth_token_keyring, conditionMessage(e)
      ))
    )
    Sys.setenv(OVC_API_TOKEN = tok)
  }
  scheme <- if (!is.null(cfg$scheme) && nzchar(cfg$scheme)) cfg$scheme else "http"
  tei_url <- sprintf("%s://%s:%d/embed", scheme, cfg$host, as.integer(cfg$port))
  backend <- openalexVectorComp::backend_config(
    provider = "tei",
    tei_url  = tei_url,
    model    = cfg$model
  )
  if (!is.null(cfg$max_batch_size)) {
    backend$max_batch_size <- as.integer(cfg$max_batch_size)
  }
  backend
}

# ----------------------------------------------------------------------------
# Completion marker — written next to the parquet shards after a successful
# embed_works run; records the row count so subsequent runs can verify the
# leaf is whole (and detect partial / crashed prior runs).
# ----------------------------------------------------------------------------
embed_marker_path <- function(leaf_dir) {
  file.path(leaf_dir, ".embed_complete")
}

read_embed_marker <- function(leaf_dir) {
  p <- embed_marker_path(leaf_dir)
  if (!file.exists(p)) return(NA_integer_)
  n <- suppressWarnings(as.integer(readLines(p, n = 1L, warn = FALSE)))
  if (!isTRUE(is.finite(n))) NA_integer_ else n
}

write_embed_marker <- function(leaf_dir, n) {
  dir.create(leaf_dir, recursive = TRUE, showWarnings = FALSE)
  writeLines(as.character(as.integer(n)), embed_marker_path(leaf_dir))
}

# Expected leaf-row count = output of applying the preprocessor to the full
# input corpus (some variants drop rows, e.g. abstract skips works without
# an abstract). Cost: one full preprocessor pass — only invoked when a leaf
# exists without a marker (migration) or when we suspect a mismatch.
expected_post_prep_count <- function(corpus_path, preprocessor,
                                     preprocessor_args = list()) {
  df <- tryCatch(
    arrow::open_dataset(
      corpus_path,
      factory_options = list(exclude_invalid_files = TRUE)
    ) |> dplyr::collect(),
    error = function(e) NULL
  )
  if (is.null(df)) return(NA_integer_)
  args <- c(list(df), preprocessor_args)
  out <- tryCatch(do.call(preprocessor, args), error = function(e) NULL)
  if (is.null(out)) NA_integer_ else nrow(out)
}

# Variant → preprocessor lookup used by _targets.R when wiring the 6 emb
# targets. Centralised here so adding a variant only touches this file +
# _targets.R.
variant_preprocessor <- function(variant_name, cfg) {
  switch(
    variant_name,
    title          = list(prep = preprocessor_title,          args = list()),
    abstract       = list(prep = preprocessor_abstract,       args = list()),
    title_abstract = list(
      prep = preprocessor_title_abstract,
      args = list(
        sep       = cfg$sep_token,
        title_cap = cfg$title_cap_combined
      )
    ),
    stop("Unknown variant_name: ", variant_name)
  )
}
