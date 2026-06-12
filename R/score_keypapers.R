score_keypapers <- function(
  corpus_emb_dir,
  reference_emb_dir,
  variant,
  out_dir,
  method = c("linear", "exponential"),
  alpha = 1
) {
  method <- match.arg(method)

  # Both paths look like <embeddings>/config=<NAME>/source=<X>/
  config_dir_corpus <- dirname(corpus_emb_dir)
  config_dir_ref    <- dirname(reference_emb_dir)
  if (!identical(config_dir_corpus, config_dir_ref)) {
    stop(
      "corpus and reference embeddings must live under the same config dir.\n",
      "  corpus:    ", config_dir_corpus, "\n",
      "  reference: ", config_dir_ref
    )
  }
  embeddings_db <- config_dir_corpus
  config_name   <- sub("^config=", "", basename(embeddings_db))

  ds <- arrow::open_dataset(
    embeddings_db,
    factory_options = list(exclude_invalid_files = TRUE)
  )

  variant_filter <- variant
  ref <- ds |>
    dplyr::filter(source == "keypaper", variant == variant_filter) |>
    dplyr::select(id, dplyr::starts_with("V")) |>
    dplyr::collect()

  if (nrow(ref) == 0L) stop("No keypaper embeddings for variant: ", variant)

  vcols <- grep("^V[0-9]+$", names(ref), value = TRUE)
  vcols <- vcols[order(as.integer(sub("^V", "", vcols)))]

  normalize_rows <- function(m) {
    n <- sqrt(rowSums(m * m))
    n[n == 0] <- 1
    m / n
  }

  R  <- normalize_rows(as.matrix(ref[, vcols, drop = FALSE]))
  Rt <- t(R)
  ref_ids <- as.character(ref$id)
  rm(R, ref); gc()

  # Stream the corpus side: open each parquet file under
  # source=corpus/variant=<variant>/ separately to keep peak memory bounded.
  # Each embed_works batch file is ~50-100k rows, so a chunk's matmul against
  # ~10^2 keypapers stays in the low-GB range.
  corpus_dir <- file.path(
    embeddings_db, "source=corpus", paste0("variant=", variant)
  )
  if (!dir.exists(corpus_dir)) {
    stop("No corpus embeddings directory for variant: ", variant,
         " (looked under ", corpus_dir, ")")
  }
  corpus_files <- list.files(
    corpus_dir, pattern = "\\.parquet$", full.names = TRUE, recursive = TRUE
  )
  if (length(corpus_files) == 0L) {
    stop("No corpus parquet files for variant: ", variant)
  }

  out_file <- file.path(
    out_dir,
    paste0("config=", config_name),
    paste0("variant=", variant),
    "pairwise-cosine.parquet"
  )
  dir.create(dirname(out_file), recursive = TRUE, showWarnings = FALSE)

  chunks <- vector("list", length(corpus_files))
  for (i in seq_along(corpus_files)) {
    ch <- arrow::read_parquet(
      corpus_files[[i]], col_select = c("id", dplyr::all_of(vcols))
    )
    C  <- normalize_rows(as.matrix(ch[, vcols, drop = FALSE]))
    sims <- C %*% Rt
    if (method == "exponential") {
      score <- exp(-alpha * (1 - sims))
    } else {
      score <- sims
    }
    chunk_out <- as.data.frame(score, stringsAsFactors = FALSE,
                               check.names = FALSE)
    colnames(chunk_out) <- ref_ids
    chunk_out <- cbind(
      data.frame(id = as.character(ch$id), stringsAsFactors = FALSE),
      chunk_out
    )
    chunks[[i]] <- chunk_out
    rm(ch, C, sims, score, chunk_out); gc()
  }
  out <- dplyr::bind_rows(chunks)
  rm(chunks); gc()
  arrow::write_parquet(out, out_file)

  out_file
}
