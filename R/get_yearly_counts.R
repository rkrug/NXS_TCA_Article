# Yearly counts of works on OpenAlex for the universe + each search-term
# bucket. Mirrors the TCAC 1.0 oa_count.rds structure but is built per
# openalexPro (httr2-based) since pro_count itself doesn't return
# group_by buckets.

get_yearly_counts <- function(tfc_st, nature_st, tca_st) {
  fn_out <- file.path("output", "search_strings", "yearly_counts.rds")

  buckets <- list(
    list(label = "openalex_universe", search = NULL),
    list(label = "nature",                search = nature_st),
    list(label = "transformative_change", search = tfc_st),
    list(label = "tca",                   search = tca_st)
  )

  parts <- lapply(buckets, function(b) {
    args <- list(group_by = "publication_year")
    if (!is.null(b$search)) {
      args$title_and_abstract.search <- b$search
    }
    url <- withCallingHandlers(
      do.call(openalexPro::pro_query, args),
      warning = function(w) {
        if (grepl("title_and_abstract\\.search.*deprecated",
                  conditionMessage(w))) {
          invokeRestart("muffleWarning")
        }
      }
    )

    req <- httr2::request(url) |>
      httr2::req_user_agent(
        paste0("openalexPro/", utils::packageVersion("openalexPro"))
      )
    api_key <- openalexPro::pro_api_key()
    if (!is.null(api_key) && nzchar(api_key)) {
      req <- httr2::req_url_query(req, api_key = api_key)
    }
    resp  <- httr2::req_perform(req)
    data  <- httr2::resp_body_json(resp)
    groups <- data$group_by

    if (length(groups) == 0L) {
      return(tibble::tibble(
        label = b$label,
        publication_year = integer(0),
        count = integer(0)
      ))
    }
    tibble::tibble(
      label = b$label,
      publication_year = vapply(
        groups,
        function(x) suppressWarnings(as.integer(x$key)), integer(1)
      ),
      count = vapply(groups, function(x) as.integer(x$count), integer(1))
    ) |>
      dplyr::filter(!is.na(publication_year)) |>
      dplyr::arrange(publication_year) |>
      dplyr::mutate(
        p     = count / sum(count),
        p_cum = cumsum(p)
      )
  })

  result <- dplyr::bind_rows(parts)
  dir.create(dirname(fn_out), recursive = TRUE, showWarnings = FALSE)
  saveRDS(result, fn_out)
  fn_out
}
