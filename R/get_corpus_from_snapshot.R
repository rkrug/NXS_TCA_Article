get_corpus_from_snapshot <- function(
  ids_db,
  snapshot_dir,
  project_folder,
  workers
) {
  # Fork safety guard: this fork reuses the frozen (read-only) TCAC 2.0
  # corpus clone and must never regenerate it. If the corpus dir exists and
  # is not writable, treat it as an intentionally frozen artefact — reuse it
  # as-is and skip snapshot extraction entirely (never wipe it). A genuine
  # rebuild is still possible: `chmod -R u+w` the dir first, and this guard
  # steps aside so the normal destructive extraction runs.
  corpus_dir <- file.path(project_folder, "corpus")
  if (dir.exists(corpus_dir) && file.access(corpus_dir, mode = 2L) != 0L) {
    message(
      "[get_corpus_from_snapshot] '", corpus_dir, "' is read-only (frozen ",
      "in this fork) — reusing the existing clone, skipping snapshot ",
      "extraction. `chmod -R u+w` it to force a rebuild."
    )
    return(corpus_dir)
  }

  unlink(
    corpus_dir,
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
