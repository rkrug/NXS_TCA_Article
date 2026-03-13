get_corpus_from_snapshot <- function(
  ids_db,
  snapshot_dir,
  corpus_dir
) {
  ids <- arrow::open_dataset(ids_db) |>
    dplyr::select("id") |>
    dplyr::collect() |>
    dplyr::pull(id)

  # sel_dir <- file.path("output", "TCAC_1.0", "selected_ids")

  unlink(corpus_dir, recursive = TRUE)

  cd <- openalexPro::lookup_by_id(
    index_file = file.path(snapshot_dir, "works_id_idx.parquet"),
    id = ids,
    output = corpus_dir,
    workers = 4
  )

  return(cd)
}
