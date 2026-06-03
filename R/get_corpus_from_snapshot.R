get_corpus_from_snapshot <- function(
  ids_db,
  snapshot_dir,
  project_folder,
  workers
) {
  unlink(
    file.path(project_folder, "corpus"),
    recursive = TRUE,
    force = TRUE
  )

  ids <- arrow::open_dataset(ids_db) |>
    dplyr::select("id") |>
    dplyr::collect() |>
    dplyr::pull(id)

  cd <- openalexSnapshot::lookup_by_id(
    root_dir = snapshot_dir,
    ids = ids,
    project_dir = project_folder,
    data_sets = "works",
    workers = workers
  )

  file.rename(
    from = file.path(project_folder, "snapshot_extract_works"),
    to = file.path(project_folder, "corpus")
  )

  return(file.path(project_folder, "corpus"))
}
