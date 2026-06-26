#' Compare the TCAC 1.0 and TCAC 2.0 corpora
#'
#' Reads both corpus parquets + the keypaper parquet, then computes
#' three comparison views the Corpus Report can render:
#'
#' - `type_counts`: row per OpenAlex work type with counts in each
#'   corpus and the diff (TCAC 2.0 − TCAC 1.0).
#' - `keypaper_presence`: one row per keypaper with two booleans
#'   (`in_tcac_1.0`, `in_tcac_2.0`) — does the keypaper id appear in
#'   each corpus.
#' - `yearly_status`: per (publication_year, status) the work count,
#'   where status is one of `"both"`, `"removed (only in TCAC 1.0)"`,
#'   `"added (only in TCAC 2.0)"`.
#'
#' Designed to be called inline from the QMD (so no `tar_target` is
#' needed). Loading both corpora into memory once is fine — only id +
#' publication_year + type are collected.
compare_corpora <- function(corpus_tcac10_path,
                            corpus_tcac20_path,
                            key_works_path) {
  ids_10 <- arrow::open_dataset(corpus_tcac10_path) |>
    dplyr::select(id, publication_year, type) |>
    dplyr::collect()
  ids_20 <- arrow::open_dataset(corpus_tcac20_path) |>
    dplyr::select(id, publication_year, type) |>
    dplyr::collect()
  kp <- arrow::open_dataset(key_works_path) |>
    dplyr::select(id, title, citation) |>
    dplyr::collect()

  type_counts <- dplyr::full_join(
    ids_10 |> dplyr::count(type, name = "tcac_1.0"),
    ids_20 |> dplyr::count(type, name = "tcac_2.0"),
    by = "type"
  ) |>
    dplyr::mutate(
      `tcac_1.0` = tidyr::replace_na(`tcac_1.0`, 0L),
      `tcac_2.0` = tidyr::replace_na(`tcac_2.0`, 0L),
      diff       = `tcac_2.0` - `tcac_1.0`
    ) |>
    dplyr::arrange(dplyr::desc(`tcac_2.0`))

  keypaper_presence <- kp |>
    dplyr::mutate(
      in_tcac10 = id %in% ids_10$id,
      in_tcac20 = id %in% ids_20$id
    ) |>
    dplyr::arrange(
      dplyr::desc(in_tcac20),
      dplyr::desc(in_tcac10),
      citation
    )

  # Per-id presence + year (take the year from whichever corpus has it;
  # they should match where both have it).
  presence <- dplyr::full_join(
    ids_10 |>
      dplyr::distinct(id, publication_year) |>
      dplyr::rename(year_10 = publication_year) |>
      dplyr::mutate(in_10 = TRUE),
    ids_20 |>
      dplyr::distinct(id, publication_year) |>
      dplyr::rename(year_20 = publication_year) |>
      dplyr::mutate(in_20 = TRUE),
    by = "id"
  ) |>
    dplyr::mutate(
      in_10            = !is.na(in_10) & in_10,
      in_20            = !is.na(in_20) & in_20,
      publication_year = dplyr::coalesce(year_20, year_10),
      status = dplyr::case_when(
        in_10 & in_20 ~ "both",
        in_10        ~ "removed (only in TCAC 1.0)",
        in_20        ~ "added (only in TCAC 2.0)"
      )
    )

  yearly_status <- presence |>
    dplyr::filter(!is.na(publication_year), publication_year >= 1900) |>
    dplyr::count(publication_year, status)

  list(
    type_counts       = type_counts,
    keypaper_presence = keypaper_presence,
    yearly_status     = yearly_status,
    n_tcac10          = nrow(ids_10),
    n_tcac20          = nrow(ids_20)
  )
}
