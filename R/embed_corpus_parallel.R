# Parallel-HTTP drop-in replacement for openalexVectorComp::embed_corpus().
#
# Same input contract (project_dir layout, parquet with id/title/abstract),
# same output contract (parquet under <project_dir>/embeddings/model_id=<X>/
# label=<Y>/batch=<n>/embeddings-NNNNN.parquet with the columns embed_corpus
# writes today). One extra arg: `concurrency`, an integer worker count for
# the HTTP layer. concurrency=1L behaves like a sequential embed_corpus().
#
# Why this exists: the package's serial HTTP loop pegs the laptop ↔ TEI link
# at ~50 docs/sec on RunPod (5-second response transit per batch, GPU idle).
# Parallelising the HTTP dispatch — and only the HTTP dispatch — saturates
# both the proxy and the GPU. See TD_RunPodSetup.md.
#
# Designed for clean migration into openalexVectorComp: signature mirrors
# embed_corpus(), uses only public exports of the package, no private
# helpers. To merge: copy this file into the package, add `furrr` and
# `future` to Imports, export the function.

embed_corpus_parallel <- function(
  project_dir,
  backend           = openalexVectorComp::backend_config(),
  corpus_name       = "corpus",
  batch_size        = 5000L,
  delete_existing   = FALSE,
  text_preprocessor = openalexVectorComp::clean_abstract_for_embedding,
  cleaner_args      = list(),
  save_text         = TRUE,
  label             = corpus_name,
  dry_run           = FALSE,
  verbose           = TRUE,
  concurrency       = 1L
) {
  # ---- arg validation ----------------------------------------------------
  if (!is.character(project_dir) || length(project_dir) != 1L ||
      !nzchar(project_dir)) {
    stop("`project_dir` must be a non-empty directory path.")
  }
  if (!is.list(backend) || is.null(backend$provider)) {
    stop("`backend` must come from openalexVectorComp::backend_config().")
  }
  if (!is.numeric(batch_size) || length(batch_size) != 1L || batch_size <= 0) {
    stop("`batch_size` must be a positive number.")
  }
  if (!is.function(text_preprocessor)) {
    stop("`text_preprocessor` must be a function.")
  }
  if (!is.numeric(concurrency) || length(concurrency) != 1L ||
      concurrency < 1L) {
    stop("`concurrency` must be a positive integer.")
  }
  concurrency <- as.integer(concurrency)
  batch_size  <- as.integer(batch_size)

  `%||%` <- function(x, y) if (is.null(x)) y else x

  # ---- backend info + output dir naming (mirrors embed_corpus) -----------
  info <- openalexVectorComp::backend_info(backend)
  model_id <- if (!is.null(info$model_id) && nzchar(info$model_id)) {
    info$model_id
  } else {
    backend$model
  }
  model_part <- gsub("/", "_", model_id, fixed = TRUE)
  label_part <- gsub("/", "_", label,    fixed = TRUE)
  emb_root   <- file.path(project_dir, "embeddings")
  model_dir  <- file.path(emb_root, paste0("model_id=", model_part))
  label_dir  <- file.path(model_dir, paste0("label=",   label_part))

  if (!isTRUE(dry_run)) {
    dir.create(label_dir, recursive = TRUE, showWarnings = FALSE)
    # Minimal backend metadata side-car (same convention as embed_corpus).
    backend_meta <- backend
    backend_meta$model <- model_id
    if (!is.null(info$max_batch_size)) {
      backend_meta$max_batch_size <- info$max_batch_size
    }
    tryCatch(
      openalexVectorComp::backend_save(
        backend = backend_meta,
        fn      = file.path(model_dir, "embed_model.yaml")
      ),
      error = function(e) {
        if (verbose) message("Note: could not write embed_model.yaml: ",
                              conditionMessage(e))
      }
    )
  }

  # ---- open the corpus ---------------------------------------------------
  corpus_path <- file.path(project_dir, corpus_name)
  ds <- arrow::open_dataset(
    corpus_path,
    factory_options = list(exclude_invalid_files = TRUE)
  )
  req_cols <- c("id", "title", "abstract")
  missing  <- setdiff(req_cols, names(ds))
  if (length(missing)) {
    stop("Dataset must contain columns: ", paste(missing, collapse = ", "))
  }
  total_rows <- nrow(ds)

  # ---- worker pool (only when concurrency > 1) ---------------------------
  if (concurrency > 1L) {
    if (!requireNamespace("future", quietly = TRUE) ||
        !requireNamespace("furrr",  quietly = TRUE)) {
      stop("`concurrency > 1` requires the `future` and `furrr` packages.")
    }
    old_plan <- future::plan(future::multisession, workers = concurrency)
    on.exit(future::plan(old_plan), add = TRUE)
  }

  # ---- HTTP batch size: prefer backend's, then server-reported, else 32 -
  max_http_batch <- as.integer(
    backend$max_batch_size %||% info$max_batch_size %||% 32L
  )
  if (max_http_batch < 1L) max_http_batch <- 32L

  # ---- per-shard worker function: ONLY HTTP work --------------------------
  # Defined at function scope so future workers capture it via globals
  # detection. Takes `backend` explicitly so future doesn't have to
  # serialise the enclosing environment.
  do_embed <- function(chunk, backend) {
    openalexVectorComp::embed_texts(texts = chunk, backend = backend)
  }

  # ---- main shard loop ---------------------------------------------------
  scanner <- arrow::Scanner$create(
    ds, columns = req_cols, batch_size = batch_size
  )
  reader  <- scanner$ToRecordBatchReader()

  shard_idx     <- 0L
  embedded_rows <- 0L
  start_time    <- Sys.time()

  if (verbose) {
    message(sprintf(
      "embed_corpus_parallel: %s rows, batch_size=%d, http_batch=%d, concurrency=%d",
      format(total_rows, big.mark = ","),
      batch_size, max_http_batch, concurrency
    ))
  }

  repeat {
    rb <- reader$read_next_batch()
    if (is.null(rb)) break
    batch_df <- dplyr::collect(rb)
    batch_df$id <- ifelse(is.na(batch_df$id), "", as.character(batch_df$id))
    batch_df$title <- ifelse(
      is.na(batch_df$title), "", as.character(batch_df$title)
    )
    batch_df$abstract <- ifelse(
      is.na(batch_df$abstract), "", as.character(batch_df$abstract)
    )

    prep <- do.call(text_preprocessor, c(list(df = batch_df), cleaner_args))
    if (!is.data.frame(prep)) {
      stop("`text_preprocessor` must return a data frame; got: ",
           paste(class(prep), collapse = "/"))
    }
    if (nrow(prep) == 0L) next

    if (isTRUE(dry_run)) {
      embedded_rows <- embedded_rows + nrow(prep)
      next
    }

    # Split prep$text into HTTP chunks.
    texts  <- prep$text
    starts <- seq.int(1L, length(texts), by = max_http_batch)
    chunks <- lapply(starts, function(s) {
      texts[s:min(length(texts), s + max_http_batch - 1L)]
    })

    # Dispatch — parallel only if it would actually help.
    t_http_start <- Sys.time()
    if (concurrency > 1L && length(chunks) > 1L) {
      mats <- furrr::future_map(
        chunks, do_embed, backend = backend,
        .options = furrr::furrr_options(seed = TRUE, globals = "do_embed")
      )
    } else {
      mats <- lapply(chunks, do_embed, backend = backend)
    }
    t_http_secs <- as.numeric(Sys.time() - t_http_start, units = "secs")

    emb <- do.call(rbind, mats)
    if (NCOL(emb) > 0L && is.null(colnames(emb))) {
      colnames(emb) <- paste0("V", seq_len(NCOL(emb)))
    }

    # Assemble the row group (mirrors embed_corpus column order).
    out_core <- data.frame(
      id         = prep$id,
      text_hash  = prep$text_hash,
      provider   = backend$provider,
      model_id   = model_id,
      created_at = as.character(Sys.time(), tz = "UTC"),
      stringsAsFactors = FALSE,
      check.names      = FALSE
    )
    if (isTRUE(save_text)) out_core$text <- prep$text
    extra_cols <- setdiff(names(prep), c("id", "text", "text_hash"))
    out <- cbind(
      out_core,
      prep[, extra_cols, drop = FALSE],
      as.data.frame(emb, check.names = FALSE)
    )

    shard_idx <- shard_idx + 1L
    shard_dir <- file.path(label_dir, sprintf("batch=%d", shard_idx))
    dir.create(shard_dir, recursive = TRUE, showWarnings = FALSE)
    arrow::write_parquet(
      out,
      file.path(shard_dir, sprintf("embeddings-%05d.parquet", shard_idx))
    )

    embedded_rows <- embedded_rows + nrow(out)
    if (verbose) {
      rate <- if (t_http_secs > 0) nrow(out) / t_http_secs else NA_real_
      message(sprintf(
        "  shard %d  rows=%s  http=%.2fs  rate=%s docs/s  cum=%s",
        shard_idx, format(nrow(out), big.mark = ","),
        t_http_secs,
        if (is.na(rate)) "?" else format(round(rate, 1), big.mark = ","),
        format(embedded_rows, big.mark = ",")
      ))
    }
  }

  elapsed <- as.numeric(Sys.time() - start_time, units = "secs")
  if (verbose) {
    rate <- if (elapsed > 0) embedded_rows / elapsed else NA_real_
    message(sprintf(
      "Done. embedded=%s rows in %d shards, %.1fs total (%s docs/s avg).",
      format(embedded_rows, big.mark = ","),
      shard_idx, elapsed,
      if (is.na(rate)) "?" else format(round(rate, 1), big.mark = ",")
    ))
  }

  invisible(model_dir)
}
