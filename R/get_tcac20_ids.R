get_tcac20_ids <- function(
  st,
  tf,
  project_folder
) {
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
      workers = 6
    )
  return(result)
}
