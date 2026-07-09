# Extract every inline citation token from the keypaper definitions.
#
# Reads the keypaper dataset (produced by prepare_key_definitions(), one row
# per definition with the citation-bearing `abstract_raw`), runs the shared
# regex parser (R/citation_regex.R) over each definition, and writes a long
# table — one row per (definition, citation token):
#
#   keyset, keypaper_id, source_id, raw_citation, author_key, year, cite_seq
#
# `cite_seq` is the 1-based order of the citation within the definition (handy
# for debugging / de-duplication). Output:
#   output/NXS_TCA_corpus/citations/extracted/part-0.parquet
# Returns the `extracted/` directory path (format = "file" target).

extract_definition_citations <- function(key_works_dir,
                                          out_dir = file.path(
                                            "output/NXS_TCA_corpus",
                                            "citations_extracted",
                                            "method=regex"
                                          )) {
  kp <- arrow::open_dataset(key_works_dir) |>
    dplyr::select(keyset, id, source_id, abstract_raw) |>
    dplyr::collect()

  rows <- lapply(seq_len(nrow(kp)), function(i) {
    cites <- find_citations(kp$abstract_raw[i])
    if (!nrow(cites)) {
      return(NULL)
    }
    data.frame(
      keyset = kp$keyset[i],
      keypaper_id = kp$id[i],
      source_id = kp$source_id[i],
      raw_citation = cites$raw,
      author_key = cites$author_key,
      year = cites$year,
      cite_seq = seq_len(nrow(cites)),
      stringsAsFactors = FALSE
    )
  })
  out <- do.call(rbind, rows)
  if (is.null(out)) {
    out <- data.frame(
      keyset = character(0), keypaper_id = character(0),
      source_id = character(0), raw_citation = character(0),
      author_key = character(0), year = integer(0), cite_seq = integer(0),
      stringsAsFactors = FALSE
    )
  }

  message(sprintf(
    paste0(
      "[extract_definition_citations] %d citation tokens from %d definitions ",
      "(%d with ≥1 citation) | per keyset: %s"
    ),
    nrow(out), nrow(kp), dplyr::n_distinct(out$keypaper_id),
    paste(sprintf(
      "%s=%d",
      names(table(out$keyset)), as.integer(table(out$keyset))
    ), collapse = ", ")
  ))

  write_citations_dataset(out, out_dir)
}
