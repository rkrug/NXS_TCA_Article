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
  preprocessor_args = list(),
  assessment = NULL
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
  # Optional per-assessment sub-partition. Each assessment becomes its own
  # leaf (own skip-guard marker), so re-embedding one assessment leaves the
  # other's embeddings untouched. Readers open the parent variant= dir and
  # arrow globs both assessment leaves transparently.
  if (!is.null(assessment) && nzchar(assessment)) {
    leaf_dir <- file.path(leaf_dir, paste0("assessment=", assessment))
  }

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

    # Fork safety guard: frozen (read-only) leaves — the reused TCAC 2.0
    # corpus embeddings — must never be wiped. A writable leaf (e.g.
    # source=keypaper, regenerated on a keypaper-set change) passes through.
    if (file.access(leaf_dir, mode = 2L) != 0L) {
      stop(sprintf(
        "[%s|%s] leaf is read-only (frozen in this fork) but flagged partial (actual=%s vs marker=%s). Refusing to wipe %s. If regeneration is truly intended, `chmod -R u+w` the leaf first.",
        source, variant_name,
        format(n_have, big.mark = ","),
        format(n_expected, big.mark = ","), leaf_dir
      ), call. = FALSE)
    }

    message(sprintf(
      "[%s|%s] leaf partial: actual=%s vs marker=%s — wiping and re-embedding.",
      source, variant_name,
      format(n_have, big.mark = ","),
      format(n_expected, big.mark = ",")
    ))
    unlink(leaf_dir, recursive = TRUE)
  }

  # ---- Merge fresh connection / throughput config -----------------------
  # The caller passes only the value-affecting config fields (model,
  # sep_token, title_cap_combined, pilot_n) so that changing the TEI host or
  # tuning batch/concurrency does NOT invalidate the embedding targets. The
  # connection/throughput fields are read fresh here (untracked by targets)
  # from the active config block in input/config.yaml.
  conn <- tryCatch(
    yaml::read_yaml("input/config.yaml")$embeddings$configs[[config_name]],
    error = function(e) NULL
  )
  conn_fields <- c("host", "port", "scheme", "auth_token_keyring",
                   "batch_size", "max_batch_size", "concurrency")
  if (!is.null(conn)) {
    cfg <- utils::modifyList(cfg, conn[intersect(names(conn), conn_fields)])
  }
  if (is.null(cfg$host) || is.null(cfg$port)) {
    stop("embed_works: no host/port resolved for config '", config_name,
         "'. Check embeddings.configs.", config_name, " in input/config.yaml.")
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

  # ---- Embed each input partition into a mirrored output sub-leaf --------
  # The corpus is hive-partitioned (e.g. chapter=Chapter%201/). We embed each
  # sub-partition independently and mirror its relative sub-path into the
  # output leaf, so `chapter` is carried through purely via the directory
  # path and never becomes a data column — embed_corpus_parallel and the
  # preprocessors stay untouched. A single-file input (keypaper) or a flat
  # directory (pilot subset) yields one unnamed partition → the original
  # flat-leaf behaviour, unchanged.
  partitions <- enumerate_input_partitions(corpus_path)

  base_scratch <- file.path(out_dir, ".raw", config_name, source, variant_name)
  if (!is.null(assessment) && nzchar(assessment)) {
    base_scratch <- file.path(base_scratch, assessment)
  }
  unlink(base_scratch, recursive = TRUE)
  on.exit(unlink(base_scratch, recursive = TRUE), add = TRUE)

  cleaner_args <- if (length(preprocessor_args)) preprocessor_args else list()

  total_written <- 0L
  for (i in seq_along(partitions)) {
    part     <- partitions[[i]]
    sub_rel  <- part$rel
    sub_leaf <- if (nzchar(sub_rel)) file.path(leaf_dir, sub_rel) else leaf_dir
    scr_key  <- if (nzchar(sub_rel)) sub_rel else "_flat"

    total_written <- total_written + embed_one_partition(
      part_files      = part$files,
      sub_leaf        = sub_leaf,
      scratch_project = file.path(base_scratch, scr_key),
      backend         = backend,
      model_part      = model_part,
      cfg             = cfg,
      source          = source,
      variant_name    = variant_name,
      part_tag        = if (nzchar(sub_rel)) sub_rel else "(flat)",
      preprocessor    = preprocessor,
      cleaner_args    = cleaner_args
    )
  }

  message(sprintf(
    "[%s|%s] all %d partition(s) done; wrote %s rows total to %s",
    source, variant_name, length(partitions),
    format(total_written, big.mark = ","), leaf_dir
  ))
  write_embed_marker(leaf_dir, total_written)
  leaf_dir
}

# ----------------------------------------------------------------------------
# Enumerate the hive sub-partitions of an embed input.
#
# Returns a list of partitions, each `list(rel = <sub-dir path relative to
# corpus_path, "" when flat>, files = <absolute parquet paths>)`. A single
# parquet file (keypaper) or a directory whose parquets sit at its root
# (pilot subset) yields exactly one partition with `rel = ""`; a partitioned
# corpus (…/chapter=Chapter%201/part-0.parquet) yields one partition per
# distinct sub-dir. Ordering is stable (sorted by `rel`) so runs are
# deterministic.
# ----------------------------------------------------------------------------
enumerate_input_partitions <- function(corpus_path) {
  if (!dir.exists(corpus_path)) {
    # Single-file input (keypaper) — one flat partition.
    return(list(list(rel = "", files = normalizePath(corpus_path, mustWork = TRUE))))
  }
  base <- normalizePath(corpus_path, mustWork = TRUE)
  all_pq <- list.files(base, pattern = "\\.parquet$",
                       recursive = TRUE, full.names = TRUE)
  if (length(all_pq) == 0L) {
    stop("enumerate_input_partitions: no parquet files under ", corpus_path)
  }
  rel_files <- substring(normalizePath(all_pq), nchar(base) + 2L)  # drop "base/"
  sub_rel   <- dirname(rel_files)
  sub_rel[sub_rel == "."] <- ""
  lapply(sort(unique(sub_rel)), function(sr) {
    list(rel = sr, files = all_pq[sub_rel == sr])
  })
}

# ----------------------------------------------------------------------------
# Embed one input partition: symlink its parquet(s) into a private scratch
# project, run embed_corpus_parallel (HTTP → TEI), then consolidate the
# scratch shards into ~1 GB part-NNNN.parquet chunks under `sub_leaf` via a
# streaming duckdb COPY. Returns the number of rows written.
#
# Factored out of embed_works so the per-partition loop can reuse it
# verbatim; the consolidation logic is identical to the pre-partition
# single-leaf path, just targeting `sub_leaf` instead of the top leaf.
# ----------------------------------------------------------------------------
embed_one_partition <- function(part_files, sub_leaf, scratch_project,
                                backend, model_part, cfg, source,
                                variant_name, part_tag,
                                preprocessor, cleaner_args) {
  if (!requireNamespace("duckdb", quietly = TRUE)) {
    stop("Package 'duckdb' is required for the embed_works consolidation step. ",
         "Install via: install.packages('duckdb')")
  }
  if (!requireNamespace("DBI", quietly = TRUE)) {
    stop("Package 'DBI' is required for the embed_works consolidation step.")
  }

  # ---- Scratch dir layout (mirrors openalexVectorComp::embed_corpus) -----
  # Symlink each parquet of this partition into a flat `input/` dir; arrow
  # opens that dir as the corpus. basenames within one partition are unique
  # (part-0.parquet, part-1.parquet, …), so no collision handling needed.
  unlink(scratch_project, recursive = TRUE)
  input_dir <- file.path(scratch_project, "input")
  dir.create(input_dir, recursive = TRUE, showWarnings = FALSE)
  for (f in part_files) {
    file.symlink(normalizePath(f, mustWork = TRUE),
                 file.path(input_dir, basename(f)))
  }
  corpus_name <- "input"
  raw_label_dir <- file.path(
    scratch_project, "embeddings",
    paste0("model_id=", model_part),
    paste0("label=", variant_name)
  )

  # ---- Progress watcher --------------------------------------------------
  n_in <- tryCatch(
    nrow(arrow::open_dataset(
      input_dir,
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
      label       = sprintf("%s|%s|%s", source, variant_name, part_tag)
    )
    on.exit(stop_shard_watcher(watcher), add = TRUE)
  }

  message(sprintf(
    "--- source = %s, variant = %s, partition = %s, input rows = %s ---",
    source, variant_name, part_tag,
    if (is.na(n_in)) "?" else format(n_in, big.mark = ",")
  ))

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

  # ---- Re-partition into ~1 GB consolidated parquet chunks per leaf -----
  # Output shape: <sub_leaf>/part-{NNNN}.parquet — multiple files, each
  # ~1 GB at SPECTER2 dimensionality (768 float32 cols × 250K rows). Row
  # groups remain 50K rows so analytical reads stay fast. config/source/
  # variant/assessment/chapter are NOT written into the parquet itself; hive
  # partitioning encodes them in the path, and arrow::open_dataset()
  # synthesises them on read. A `batch` column is added from each scratch
  # shard's batch number so the embed_corpus_parallel ordering is recoverable.
  #
  # Why multi-file: ~1 GB chunks let rclone resume per-chunk on
  # interruption, and let duckdb httpfs parallelise reads across files on the
  # BERTopic pod. Streamed via duckdb's COPY — the arrow-side variants
  # (collect first, lazy mutate, Scanner+ParquetFileWriter) all OOM'd at
  # 4–5M rows on macOS. duckdb's parquet writer streams with bounded memory.
  any_shard <- length(list.files(
    raw_label_dir, pattern = "[.]parquet$", recursive = TRUE
  ))
  if (any_shard == 0L) {
    stop("No scratch parquets found under: ", raw_label_dir)
  }

  dir.create(sub_leaf, recursive = TRUE, showWarnings = FALSE)
  # Write into a sibling tmp dir, then atomically move files into the
  # leaf. Avoids partial state if duckdb dies mid-write.
  tmp_dir <- file.path(sub_leaf, ".parts.tmp")
  if (dir.exists(tmp_dir)) unlink(tmp_dir, recursive = TRUE)
  dir.create(tmp_dir, recursive = TRUE)
  # Clear any stale part-*.parquet from a previous run in the leaf — the
  # marker file is what makes a leaf "complete"; we never accept a leaf
  # that has both old and new parts.
  old_parts <- list.files(sub_leaf, pattern = "^part-.*[.]parquet$",
                          full.names = TRUE)
  if (length(old_parts)) file.remove(old_parts)

  shards_glob <- file.path(raw_label_dir, "batch=*", "embeddings-*.parquet")
  message(sprintf(
    "[%s|%s|%s] consolidating scratch shards into ~1 GB part-NNNN.parquet chunks via duckdb COPY",
    source, variant_name, part_tag
  ))

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
  try(DBI::dbExecute(con, "PRAGMA enable_progress_bar"),       silent = TRUE)
  try(DBI::dbExecute(con, "PRAGMA progress_bar_time = 1000"),  silent = TRUE)

  # FILE_SIZE_BYTES caps each file at ~1 GB; ROW_GROUP_SIZE keeps row
  # groups at 50K rows for analytical-read efficiency. COMPRESSION SNAPPY
  # is fast both ways; on float32 embeddings the savings are modest but
  # the decode is essentially free.
  copy_sql <- sprintf(
    "COPY (
       SELECT * EXCLUDE (filename),
              CAST(regexp_extract(filename, '-(\\d+)\\.parquet$', 1) AS INTEGER) AS batch
       FROM read_parquet('%s', filename = true)
     ) TO '%s' (
       FORMAT PARQUET,
       ROW_GROUP_SIZE 50000,
       FILE_SIZE_BYTES 1000000000,
       FILENAME_PATTERN 'part-{i}',
       COMPRESSION SNAPPY,
       OVERWRITE_OR_IGNORE
     )",
    shards_glob, tmp_dir
  )
  DBI::dbExecute(con, copy_sql)

  n_written <- as.integer(DBI::dbGetQuery(con, sprintf(
    "SELECT COUNT(*)::BIGINT AS n FROM read_parquet('%s/*.parquet')", tmp_dir
  ))$n)

  DBI::dbDisconnect(con, shutdown = TRUE)

  # Move the new parquets into the leaf and drop the tmp dir.
  new_parts <- list.files(tmp_dir, pattern = "^part-.*[.]parquet$",
                          full.names = TRUE)
  if (!length(new_parts)) {
    stop("duckdb COPY produced no parquet files under ", tmp_dir)
  }
  for (p in new_parts) {
    file.rename(p, file.path(sub_leaf, basename(p)))
  }
  unlink(tmp_dir, recursive = TRUE)

  message(sprintf(
    "[%s|%s|%s] consolidation done; wrote %s rows across %d files to %s",
    source, variant_name, part_tag, format(n_written, big.mark = ","),
    length(new_parts), sub_leaf
  ))

  n_written
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
