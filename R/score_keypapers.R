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

# ----------------------------------------------------------------------------
# Combined, hive-partitioned keypaper scoring.
#
# Produces ONE scores dataset from the title_abstract corpus embeddings,
# supplemented by the title embeddings for works that have no abstract (and
# were therefore dropped by preprocessor_title_abstract). Output mirrors the
# embedding hive layout:
#   <out_dir>/config=<name>/assessment=<a>/chapter=<c>/pairwise-cosine.parquet
# so the scores carry the same config/assessment/chapter partitioning as the
# corpus embeddings.
#
# Corpus side, per work:
#   * has abstract -> its title_abstract embedding, scored against the keypaper
#                     title_abstract reference.
#   * no abstract  -> its title embedding (fallback), scored against the
#                     keypaper reference named by `fallback_ref`:
#                       "title"          -> like-for-like (title vs title)
#                       "title_abstract" -> always the title_abstract ref.
#
# The keypaper columns are identical across both row groups (same keypaper id
# set, same order), so the per-work rows concatenate into one table.
#
# corpus_ta_dir / corpus_title_dir are the `variant=` dirs of the corpus
# embeddings (…/source=corpus/variant=title_abstract and …/variant=title);
# ref_ta_dir / ref_title_dir the keypaper counterparts. Passing them as
# explicit args (rather than scanning the config dir) keeps the targets DAG
# edges honest.
# ----------------------------------------------------------------------------
score_keypapers_combined <- function(
  corpus_ta_dir,
  corpus_title_dir,
  ref_ta_dir,
  ref_title_dir,
  out_dir,
  config_name = NULL,
  fallback_ref = c("title", "title_abstract"),
  method = c("linear", "exponential"),
  alpha = 1
) {
  fallback_ref <- match.arg(fallback_ref)
  method       <- match.arg(method)
  `%||%` <- function(x, y) if (is.null(x)) y else x

  if (is.null(config_name)) {
    # corpus_ta_dir = <config>/source=corpus/variant=title_abstract
    config_name <- sub("^config=", "", basename(dirname(dirname(corpus_ta_dir))))
  }

  # ---- keypaper references, aligned to one common keypaper id order -------
  read_ref <- function(dir) {
    arrow::open_dataset(dir, factory_options = list(exclude_invalid_files = TRUE)) |>
      dplyr::select(id, dplyr::starts_with("V")) |>
      dplyr::collect()
  }
  ref_ta <- read_ref(ref_ta_dir)
  ref_tt <- read_ref(ref_title_dir)
  if (nrow(ref_ta) == 0L) stop("No title_abstract keypaper embeddings under ", ref_ta_dir)
  if (nrow(ref_tt) == 0L) stop("No title keypaper embeddings under ", ref_title_dir)

  vcols <- grep("^V[0-9]+$", names(ref_ta), value = TRUE)
  vcols <- vcols[order(as.integer(sub("^V", "", vcols)))]

  ref_ids <- as.character(ref_ta$id)            # canonical column order = ta order
  miss <- setdiff(ref_ids, as.character(ref_tt$id))
  if (length(miss)) {
    stop("Keypaper(s) present in the title_abstract reference but missing from ",
         "the title reference (cannot align score columns): ",
         paste(miss, collapse = ", "))
  }
  R_ta <- .normalize_rows(as.matrix(ref_ta[, vcols, drop = FALSE]))
  idx  <- match(ref_ids, as.character(ref_tt$id))   # align title ref to ta order
  R_tt <- .normalize_rows(as.matrix(ref_tt[idx, vcols, drop = FALSE]))
  Rt_ta       <- t(R_ta)
  Rt_fallback <- if (fallback_ref == "title_abstract") Rt_ta else t(R_tt)
  rm(ref_ta, ref_tt, R_ta, R_tt); gc()

  score_block <- function(ch, Rt) {
    C    <- .normalize_rows(as.matrix(ch[, vcols, drop = FALSE]))
    sims <- C %*% Rt
    score <- if (method == "exponential") exp(-alpha * (1 - sims)) else sims
    df <- as.data.frame(score, stringsAsFactors = FALSE, check.names = FALSE)
    colnames(df) <- ref_ids
    cbind(data.frame(id = as.character(ch$id), stringsAsFactors = FALSE), df)
  }

  # ---- group corpus embedding parquets by their assessment/chapter path ---
  group_by_partition <- function(variant_dir) {
    if (!dir.exists(variant_dir)) return(list())
    base  <- normalizePath(variant_dir, mustWork = TRUE)
    files <- list.files(base, pattern = "\\.parquet$",
                        recursive = TRUE, full.names = TRUE)
    if (!length(files)) return(list())
    rel <- dirname(substring(normalizePath(files), nchar(base) + 2L))
    rel[rel == "."] <- ""
    split(files, rel)
  }
  ta_parts <- group_by_partition(corpus_ta_dir)
  tt_parts <- group_by_partition(corpus_title_dir)
  all_rels <- sort(unique(c(names(ta_parts), names(tt_parts))))
  if (!length(all_rels)) {
    stop("No corpus embedding parquet files under ", corpus_ta_dir,
         " or ", corpus_title_dir)
  }

  root <- file.path(out_dir, paste0("config=", config_name))
  unlink(root, recursive = TRUE)   # rebuild cleanly each run

  read_block <- function(f) {
    arrow::read_parquet(f, col_select = c("id", dplyr::all_of(vcols)))
  }

  n_total <- 0L
  for (rel in all_rels) {
    # primary: title_abstract-scored rows (works that have an abstract)
    ta_rows <- list(); ta_ids <- character(0)
    for (f in ta_parts[[rel]] %||% character(0)) {
      ch <- read_block(f)
      ta_ids <- c(ta_ids, as.character(ch$id))
      ta_rows[[length(ta_rows) + 1L]] <- score_block(ch, Rt_ta)
      rm(ch)
    }
    # fallback: title works with no title_abstract row (i.e. no abstract)
    fb_rows <- list()
    for (f in tt_parts[[rel]] %||% character(0)) {
      ch <- read_block(f)
      ch <- ch[!as.character(ch$id) %in% ta_ids, , drop = FALSE]
      if (nrow(ch)) fb_rows[[length(fb_rows) + 1L]] <- score_block(ch, Rt_fallback)
      rm(ch)
    }
    out <- dplyr::bind_rows(c(ta_rows, fb_rows))
    if (!nrow(out)) next
    out_path <- file.path(root, rel, "pairwise-cosine.parquet")
    dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
    arrow::write_parquet(out, out_path)
    n_total <- n_total + nrow(out)
    rm(out, ta_rows, fb_rows); gc()
  }

  message(sprintf(
    "score_keypapers_combined [%s, fallback_ref=%s]: wrote %s rows across %d partition(s) to %s",
    config_name, fallback_ref, format(n_total, big.mark = ","),
    length(all_rels), root
  ))
  root
}

# Row-wise L2 normalisation shared by the scoring functions.
.normalize_rows <- function(m) {
  n <- sqrt(rowSums(m * m))
  n[n == 0] <- 1
  m / n
}
