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
  cor <- ds |>
    dplyr::filter(source == "corpus", variant == variant_filter) |>
    dplyr::select(id, dplyr::starts_with("V")) |>
    dplyr::collect()

  if (nrow(ref) == 0L) stop("No keypaper embeddings for variant: ", variant)
  if (nrow(cor) == 0L) stop("No corpus embeddings for variant: ",    variant)

  vcols <- grep("^V[0-9]+$", names(ref), value = TRUE)
  vcols <- vcols[order(as.integer(sub("^V", "", vcols)))]

  normalize_rows <- function(m) {
    n <- sqrt(rowSums(m * m))
    n[n == 0] <- 1
    m / n
  }

  R <- normalize_rows(as.matrix(ref[, vcols, drop = FALSE]))
  C <- normalize_rows(as.matrix(cor[, vcols, drop = FALSE]))

  sims <- C %*% t(R)
  dist <- 1 - sims

  if (method == "exponential") {
    score <- exp(-alpha * dist)
  } else {
    score <- 1 - dist
  }

  out <- as.data.frame(score, stringsAsFactors = FALSE, check.names = FALSE)
  colnames(out) <- as.character(ref$id)
  out <- cbind(
    data.frame(id = as.character(cor$id), stringsAsFactors = FALSE),
    out
  )

  out_file <- file.path(
    out_dir,
    paste0("config=", config_name),
    paste0("variant=", variant),
    "pairwise-cosine.parquet"
  )
  dir.create(dirname(out_file), recursive = TRUE, showWarnings = FALSE)
  arrow::write_parquet(out, out_file)

  out_file
}
