#' Assess a search term by counting hits per sub-term
#'
#' Splits a multi-line search-term string into its sub-terms (one per
#' line, OR-joined in the combined query), and counts how many works
#' each sub-term contributes individually — optionally AND-combined
#' with another search term so the assessment is "how many works does
#' each sub-term bring into the TCA corpus".
#'
#' Sequential by design: many small OpenAlex count queries are
#' dominated by HTTP round-trip latency, not CPU; parallelising via
#' future::multisession adds 5–10 s of startup with little benefit and
#' breaks message-based progress under targets' callr capture.
#'
#' @param st The search-term string (one sub-term per line).
#' @param AND_term Optional second search-term string; results are
#'   counted under `(AND_term) AND (sub_term)`.
#' @param remove Regex to strip from each line (default trims a trailing ` OR`).
#' @param excl_others If TRUE, count each sub-term excluding hits the
#'   other sub-terms already cover: `(this) NOT (others OR'd)`.
#'
#' @return A tibble with columns `term` and `count`.
assess_search_term <- function(
  st,
  AND_term = NULL,
  remove = "^OR ",
  excl_others = FALSE
) {
  if (length(st) == 1L && grepl("\n", st)) {
    sub_terms <- strsplit(st, "\n", fixed = TRUE)[[1]]
  } else {
    sub_terms <- st
  }
  sub_terms <- gsub(pattern = remove, replacement = "", sub_terms)
  sub_terms <- trimws(sub_terms)
  sub_terms <- sub_terms[nzchar(sub_terms)]

  build_search <- function(x) {
    if (excl_others) {
      excl <- setdiff(sub_terms, x)
      searchterm <- paste0(
        "(",
        x,
        ") NOT (",
        paste(excl, collapse = " OR "),
        ")"
      )
    } else {
      searchterm <- x
    }
    if (!is.null(AND_term)) {
      searchterm <- paste0("(", AND_term, ") AND (", searchterm, ")")
    }
    st_compact(searchterm)
  }
  searches <- vapply(sub_terms, build_search, character(1))

  n_total <- length(searches)
  message(sprintf(
    "assess_search_term: %d sub-terms (sequential)",
    n_total
  ))

  counts <- integer(n_total)
  t0 <- Sys.time()
  for (i in seq_along(searches)) {
    url <- withCallingHandlers(
      openalexPro::pro_query(
        title_and_abstract.search = searches[[i]]
      ),
      warning = function(w) {
        if (
          grepl("title_and_abstract\\.search.*deprecated", conditionMessage(w))
        ) {
          invokeRestart("muffleWarning")
        }
      }
    )
    res <- openalexPro::pro_count(url)
    counts[[i]] <- as.integer(res$count)
    message(sprintf(
      "  [%3d/%d] %s -> %s",
      i,
      n_total,
      substr(sub_terms[[i]], 1, 60),
      format(counts[[i]], big.mark = ",")
    ))
  }
  message(sprintf(
    "assess_search_term: done in %s",
    format(round(difftime(Sys.time(), t0, units = "secs"), 1))
  ))

  tibble::tibble(term = sub_terms, count = counts)
}
