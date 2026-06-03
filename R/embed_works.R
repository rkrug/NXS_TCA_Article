embed_works <- function(
  corpus_path,
  cfg,
  n = NULL,
  project_folder = NULL,
  label_override = NULL
) {
  if (is.null(project_folder)) {
    project_folder <- dirname(corpus_path)
  }

  corpus_name <- basename(corpus_path)

  backend <- openalexVectorComp::backend_specter2_tei(
    host = cfg$host,
    port = cfg$port,
    model = cfg$model
  )

  if (is.null(n)) {
    effective_corpus <- corpus_name
    label <- label_override %||% "corpus"
  } else {
    effective_corpus <- paste0(corpus_name, "__pilot_n", n)
    label <- label_override %||% paste0("pilot_n", n)

    dst <- file.path(project_folder, effective_corpus)
    unlink(dst, recursive = TRUE)
    dir.create(dst, recursive = TRUE, showWarnings = FALSE)

    arrow::open_dataset(corpus_path) |>
      dplyr::select(id, title, abstract) |>
      head(n) |>
      dplyr::collect() |>
      arrow::write_parquet(file.path(dst, "part_0.parquet"))
  }

  model_dir <- openalexVectorComp::embed_corpus(
    project_folder = project_folder,
    backend = backend,
    corpus_name = effective_corpus,
    label = label,
    batch_size = cfg$batch_size,
    verbose = FALSE
  )

  label_part <- gsub("/", "_", label, fixed = TRUE)
  file.path(model_dir, paste0("label=", label_part))
}

`%||%` <- function(x, y) if (is.null(x)) y else x
