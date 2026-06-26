check_keypapers_in_corpus <- function(key_works, corpus_tcac20) {
  kp <- arrow::open_dataset(key_works) |>
    dplyr::select(id, doi, title, citation) |>
    dplyr::collect() |>
    dplyr::rename(
      keypaper_id       = id,
      keypaper_doi      = doi,
      keypaper_title    = title,
      keypaper_citation = citation
    )

  corpus_ids <- arrow::open_dataset(corpus_tcac20) |>
    dplyr::select(id) |>
    dplyr::collect()

  kp |>
    dplyr::mutate(in_corpus = keypaper_id %in% corpus_ids$id) |>
    dplyr::arrange(dplyr::desc(in_corpus), keypaper_citation)
}
