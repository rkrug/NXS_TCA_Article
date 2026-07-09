# Resolve extracted inline citations to works in the *matching assessment's*
# reference library, in two passes (per the locked design):
#
#   Pass 1 (strict): citation first-author surname == the work's first-author
#     surname AND exact publication year.
#   Pass 2 (loose):  for anything still unresolved — fuzzy surname (small edit
#     distance, initials/"et al" already dropped by the extractor) against ANY
#     author of the work, year within ±1.
#
# The reference library is each assessment's Zotero group (which already carries
# `first_author` + the full `authors` surname list + `year`), mapped to its
# OpenAlex/`zotero:` corpus id via DOI (→ `ids`) or the `zotero:<KEY>` fallback,
# and confirmed present in `corpus_chapter`. keyset→assessment: TCA_* → tca,
# Nexus_Response_Options → nxs.
#
# EVERY extracted citation is written out — resolved rows carry `matched_id`
# and `match_pass ∈ {strict, loose}`; unresolved rows are kept with
# `matched_id = NA` and `match_pass = "unmatched"` so they can be verified by
# hand. Output: output/NXS_TCA_corpus/citations/resolved/part-0.parquet.

# keyset (sheet) → assessment reference library.
keyset_assessment <- function(keyset) {
  ifelse(keyset == "Nexus_Response_Options", "nxs", "tca")
}

# Bare, lower-case DOI (strip scheme/host, trim).
.norm_doi <- function(x) {
  x <- tolower(trimws(ifelse(is.na(x), "", x)))
  x <- sub("^https?://(dx\\.)?doi\\.org/", "", x)
  x <- sub("^doi:", "", x)
  trimws(x)
}

# Build a per-assessment reference index from the Zotero rows, mapped to a
# corpus_chapter id and confirmed present there. Returns a data.frame with one
# row per (corpus_id, author, year), plus `is_first` flagging the lead author.
.build_ref_index <- function(zotero_root, ids_root, corpus_chapter_dir) {
  z <- arrow::open_dataset(zotero_root) |>
    dplyr::select(key, first_author, authors, year, doi, assessment) |>
    dplyr::collect() |>
    dplyr::distinct(assessment, key, .keep_all = TRUE)

  ids <- arrow::open_dataset(ids_root) |>
    dplyr::select(id, doi) |>
    dplyr::collect()
  ids$ndoi <- .norm_doi(ids$doi)
  ids <- ids[nzchar(ids$ndoi) & !is.na(ids$id), c("ndoi", "id")]
  ids <- ids[!duplicated(ids$ndoi), ]
  doi2id <- stats::setNames(ids$id, ids$ndoi)

  corpus_ids <- arrow::open_dataset(corpus_chapter_dir) |>
    dplyr::select(id) |>
    dplyr::collect()
  corpus_set <- unique(corpus_ids$id)

  # corpus_id per Zotero item: prefer the DOI→OpenAlex id, else zotero:<KEY>;
  # only keep it if that id actually exists in corpus_chapter.
  oa_id <- unname(doi2id[.norm_doi(z$doi)])
  zot_id <- paste0("zotero:", z$key)
  corpus_id <- ifelse(!is.na(oa_id) & oa_id %in% corpus_set, oa_id,
                      ifelse(zot_id %in% corpus_set, zot_id, NA_character_))
  z$corpus_id <- corpus_id
  z <- z[!is.na(z$corpus_id), , drop = FALSE]
  z$year_int <- suppressWarnings(as.integer(sub("[^0-9].*$", "", z$year)))

  # explode authors → one row per (corpus_id, author_key, year), is_first flag
  rows <- lapply(seq_len(nrow(z)), function(i) {
    auth <- z$authors[i]
    auth_list <- if (is.na(auth) || !nzchar(auth)) {
      z$first_author[i]
    } else {
      trimws(strsplit(auth, ";")[[1]])
    }
    auth_list <- auth_list[nzchar(auth_list)]
    if (!length(auth_list)) {
      return(NULL)
    }
    # Key each reference surname with the SAME logic as the citation side
    # (.first_surname_key: absorbs particles so "van Delden" -> "vandelden",
    # drops initials) so the two sides are comparable.
    keys <- vapply(auth_list, function(a) {
      k <- .first_surname_key(a)
      if (is.na(k) || !nzchar(k)) normalize_author_key(a) else k
    }, character(1), USE.NAMES = FALSE)
    data.frame(
      assessment = z$assessment[i],
      corpus_id = z$corpus_id[i],
      author_key = keys,
      year = z$year_int[i],
      is_first = c(TRUE, rep(FALSE, length(keys) - 1L)),
      stringsAsFactors = FALSE
    )
  })
  idx <- do.call(rbind, rows)
  idx <- idx[!is.na(idx$author_key) & nzchar(idx$author_key) &
               !is.na(idx$year), , drop = FALSE]
  unique(idx)
}

resolve_citations <- function(citations_extracted_dir,
                              zotero_root,
                              ids_root,
                              corpus_chapter_dir,
                              out_dir = file.path(
                                "output/NXS_TCA_corpus",
                                "citations_resolved", "method=regex"
                              ),
                              loose_max_dist = 2L,
                              loose_year_window = 1L) {
  cites <- arrow::open_dataset(citations_extracted_dir) |> dplyr::collect()
  cites$assessment <- keyset_assessment(cites$keyset)
  cites$row_id <- seq_len(nrow(cites))

  idx <- .build_ref_index(zotero_root, ids_root, corpus_chapter_dir)

  cites$matched_id <- NA_character_
  cites$match_pass <- "unmatched"
  cites$match_score <- NA_real_

  ## Pass 1 — strict: first-author surname + exact year.
  ref_first <- idx[idx$is_first, c("assessment", "author_key", "year",
                                   "corpus_id")]
  ref_first <- ref_first[!duplicated(
    ref_first[c("assessment", "author_key", "year")]
  ), ]
  key_of <- function(a, k, y) paste(a, k, y, sep = "\r")
  first_lookup <- stats::setNames(
    ref_first$corpus_id,
    key_of(ref_first$assessment, ref_first$author_key, ref_first$year)
  )
  hit <- unname(first_lookup[key_of(cites$assessment, cites$author_key,
                                    cites$year)])
  strict <- !is.na(hit)
  cites$matched_id[strict] <- hit[strict]
  cites$match_pass[strict] <- "strict"
  cites$match_score[strict] <- 1

  ## Pass 2 — loose: fuzzy surname (edit distance) against ANY author, year ±1.
  todo <- which(cites$match_pass == "unmatched")
  # index refs by (assessment, year) for a quick window filter
  for (r in todo) {
    a <- cites$assessment[r]
    y <- cites$year[r]
    k <- cites$author_key[r]
    cand <- idx[idx$assessment == a &
                  abs(idx$year - y) <= loose_year_window, , drop = FALSE]
    if (!nrow(cand)) next
    d <- utils::adist(k, cand$author_key)[1, ]
    # accept small absolute edit distance, scaled to the shorter surname
    ok <- d <= pmin(loose_max_dist, floor(nchar(cand$author_key) / 3) + 1L)
    if (!any(ok)) next
    best <- which(ok)[which.min(d[ok])]
    cites$matched_id[r] <- cand$corpus_id[best]
    cites$match_pass[r] <- "loose"
    cites$match_score[r] <- round(
      1 - d[best] / max(nchar(k), nchar(cand$author_key[best]), 1L), 3
    )
  }

  n <- nrow(cites)
  tab <- table(factor(cites$match_pass,
                      levels = c("strict", "loose", "unmatched")))
  message(sprintf(
    paste0(
      "[resolve_citations] %d citations | strict %d, loose %d, unmatched %d ",
      "(resolved %.1f%%) | %d distinct works cited"
    ),
    n, tab[["strict"]], tab[["loose"]], tab[["unmatched"]],
    100 * (n - tab[["unmatched"]]) / max(n, 1),
    dplyr::n_distinct(cites$matched_id[!is.na(cites$matched_id)])
  ))

  out <- cites[, c("keyset", "keypaper_id", "source_id", "assessment",
                   "raw_citation", "author_key", "year", "cite_seq",
                   "matched_id", "match_pass", "match_score")]
  write_citations_dataset(out, out_dir)
}
