get_count <- function(
  tfc_st,
  nature_st,
  types_filter,
  workers
) {
  fn_out <- file.path("output", "serch_strings", "count.rds")

  query <- list(
    tfc_complete = openalexPro::pro_query(
      title_and_abstract.search = tfc_st,
      type = NULL
    ),
    tfc_filtered = openalexPro::pro_query(
      title_and_abstract.search = tfc_st,
      type = types_filter
    ),
    nature_complete = openalexPro::pro_query(
      title_and_abstract.search = nature_st,
      type = NULL
    ),
    nature_filtered = openalexPro::pro_query(
      title_and_abstract.search = nature_st,
      type = types_filter
    ),
    tca_complete = openalexPro::pro_query(
      title_and_abstract.search = nature_st,
      type = NULL
    ),
    tca_filtered = openalexPro::pro_query(
      title_and_abstract.search = nature_st,
      type = types_filter
    )
  )

  dir.create(dirname(fn_out), recursive = TRUE, showWarnings = FALSE)
  openalexPro::pro_request(
    query,
    count_only = TRUE,
    workers = workers
  ) |>
    saveRDS(fn_out)

  return(fn_out)
}
