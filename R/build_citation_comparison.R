# Compare the two citation-identification methods — regex vs LLM (OpenRouter).
# Both extractors emit the same schema and are resolved the same way, so the
# resolved tables are directly comparable. Without hand-labelled ground truth,
# "better" is judged by: how much each finds (recall proxy), how much they
# agree (found by both = high confidence), and what fraction of what each finds
# actually resolves to a real work in the assessment library (precision proxy —
# a hallucinated or mis-parsed citation is unlikely to resolve).
#
# A citation is keyed across methods by (keypaper_id, author_key, year).

.read_resolved <- function(resolved_dir, method) {
  arrow::open_dataset(resolved_dir) |>
    dplyr::select(keyset, keypaper_id, raw_citation, author_key, year,
                  matched_id, match_pass) |>
    dplyr::collect() |>
    dplyr::mutate(method = method)
}

# Per-method headline metrics.
citation_comparison_summary <- function(resolved_regex_dir,
                                         resolved_llm_dir) {
  both <- dplyr::bind_rows(
    .read_resolved(resolved_regex_dir, "regex"),
    .read_resolved(resolved_llm_dir, "llm")
  )
  both |>
    dplyr::group_by(method) |>
    dplyr::summarise(
      citations = dplyr::n(),
      strict = sum(match_pass == "strict"),
      loose = sum(match_pass == "loose"),
      unmatched = sum(match_pass == "unmatched"),
      `resolved %` = round(100 * (strict + loose) / citations, 1),
      distinct_works = dplyr::n_distinct(matched_id[!is.na(matched_id)]),
      .groups = "drop"
    )
}

# Agreement at the (keypaper_id, author_key, year) level, per keyset:
# how many citation tokens are found by both methods, regex-only, llm-only.
citation_comparison_overlap <- function(resolved_regex_dir,
                                         resolved_llm_dir) {
  r <- .read_resolved(resolved_regex_dir, "regex") |>
    dplyr::distinct(keyset, keypaper_id, author_key, year) |>
    dplyr::mutate(in_regex = TRUE)
  l <- .read_resolved(resolved_llm_dir, "llm") |>
    dplyr::distinct(keyset, keypaper_id, author_key, year) |>
    dplyr::mutate(in_llm = TRUE)
  j <- dplyr::full_join(
    r, l,
    by = c("keyset", "keypaper_id", "author_key", "year")
  ) |>
    dplyr::mutate(
      in_regex = !is.na(in_regex),
      in_llm = !is.na(in_llm),
      agreement = dplyr::case_when(
        in_regex & in_llm ~ "both",
        in_regex ~ "regex only",
        TRUE ~ "llm only"
      )
    )
  j |>
    dplyr::count(keyset, agreement, name = "n")
}

build_citation_overlap_fig <- function(overlap_data,
                                       figures_dir = "output/figures") {
  overlap_data$agreement <- factor(
    overlap_data$agreement, levels = c("regex only", "both", "llm only")
  )
  p <- ggplot2::ggplot(
    overlap_data,
    ggplot2::aes(x = keyset, y = n, fill = agreement)
  ) +
    ggplot2::geom_col(position = "stack") +
    ggplot2::scale_fill_manual(values = c(
      "regex only" = "#2563eb", "both" = "#6b7280", "llm only" = "#16a34a"
    )) +
    ggplot2::labs(
      x = NULL, y = "distinct (author, year) citations",
      fill = "found by",
      title = "Citation extraction agreement: regex vs LLM, per keyset"
    ) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(
      axis.text.x = ggplot2::element_text(angle = 25, hjust = 1)
    )
  save_ggplot_png(p, "citation_method_overlap", figures_dir,
                  width = 9, height = 5.5)
  p
}

# Citations worth REVIEWING: those where the two methods disagree (found by
# only one) OR that stayed UNMATCHED (resolved by neither method that found
# them). Keyed by (keypaper_id, author_key, year). Returns the actual citation
# text as seen, which method(s) found it, the best resolution pass, and whether
# it resolved. Rows found by BOTH methods AND resolved are omitted — there is
# nothing to review there.
citation_comparison_review <- function(resolved_regex_dir,
                                        resolved_llm_dir) {
  key_cols <- c("keyset", "keypaper_id", "author_key", "year")
  pass_rank <- c("strict", "loose", "unmatched")
  both <- dplyr::bind_rows(
    .read_resolved(resolved_regex_dir, "regex"),
    .read_resolved(resolved_llm_dir, "llm")
  )
  both |>
    dplyr::group_by(dplyr::across(dplyr::all_of(key_cols))) |>
    dplyr::summarise(
      found_by = {
        m <- sort(unique(method))
        if (length(m) == 2L) "both" else paste(m, "only")
      },
      resolved = any(!is.na(matched_id)),
      # best (lowest-rank) resolution pass across the methods that found it
      pass = pass_rank[min(match(match_pass, pass_rank))],
      raw_citation = dplyr::first(raw_citation),
      .groups = "drop"
    ) |>
    dplyr::filter(found_by != "both" | !resolved) |>
    dplyr::arrange(dplyr::desc(found_by != "both"), !resolved,
                   keyset, keypaper_id, author_key, year) |>
    dplyr::select(found_by, resolved, pass, keyset, keypaper_id,
                  raw_citation, author_key, year)
}
