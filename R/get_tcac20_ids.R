get_tcac20_ids <- function(
  st,
  tf,
  project_folder,
  workers
) {
  unlink(
    file.path(project_folder, "ids"),
    recursive = TRUE,
    force = TRUE
  )

  queries <- lapply(
    tf,
    function(type) {
      suppressWarnings(
        openalexPro::pro_query(
          title_and_abstract.search = st_compact(st),
          type = type,
          select = c("id", "relevance_score")
        )
      )
    }
  )
  names(queries) <- tf

  result <- queries |>
    openalexPro::pro_fetch(
      pages = NULL,
      project_folder = project_folder,
      api_key = keyring::key_get("API_openalex"),
      workers = workers,
      progress = TRUE,
      delete_input = TRUE,
      overwrite = TRUE
    )

  file.rename(
    from = file.path(project_folder, "parquet"),
    to = file.path(project_folder, "ids")
  )

  return(file.path(project_folder, "ids"))
}
