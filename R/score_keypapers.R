score_keypapers <- function(
  corpus_emb_dir,
  reference_emb_dir,
  method = c("linear", "exponential"),
  alpha = 1,
  max_cells = 1e9
) {
  method <- match.arg(method)

  model_dir_corpus <- dirname(corpus_emb_dir)
  model_dir_ref    <- dirname(reference_emb_dir)
  if (!identical(model_dir_corpus, model_dir_ref)) {
    stop(
      "corpus and reference embeddings must live under the same model directory.\n",
      "  corpus:    ", model_dir_corpus, "\n",
      "  reference: ", model_dir_ref
    )
  }

  emb_root        <- dirname(model_dir_corpus)
  project_dir     <- dirname(emb_root)
  embeddings_dir  <- basename(model_dir_corpus)
  corpus_label    <- sub("^label=", "", basename(corpus_emb_dir))
  reference_label <- sub("^label=", "", basename(reference_emb_dir))

  openalexVectorComp::distance_reference_cosine(
    project_dir     = project_dir,
    embeddings_dir  = embeddings_dir,
    corpus_label    = corpus_label,
    reference_label = reference_label,
    max_cells       = max_cells,
    verbose         = FALSE
  )

  dist_pq <- file.path(
    project_dir,
    "distance_reference_cosine",
    embeddings_dir,
    paste0("corpus_label=", gsub("/", "_", corpus_label, fixed = TRUE)),
    paste0("reference_label=", gsub("/", "_", reference_label, fixed = TRUE)),
    "pairwise-cosine.parquet"
  )

  openalexVectorComp::score_reference_cosine(
    distance_parquet = dist_pq,
    method           = method,
    alpha            = alpha,
    verbose          = FALSE
  )

  sub(
    "distance_reference_cosine",
    "score_reference_cosine",
    dist_pq,
    fixed = TRUE
  )
}
