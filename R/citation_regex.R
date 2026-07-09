# Regex-based inline-citation extraction and stripping for the TCA/Nexus
# concept definitions. Deterministic (no LLM/API) — the definitions are
# citation-dense in mixed styles: parenthetical `(Kabeer, 1999)`, multi-cite
# `(Kabeer, 1999; Manlosa, 2022)`, `(K. Brown & Westaway, 2011)`,
# `(Tscharntke et al., 2005)`, and narrative `Olsson et al (2004)`,
# `Andrachuk et al. (2018)`, `Kabeer (1999)`.
#
# Two entry points, both used by the pipeline:
#   find_citations(text)  -> data.frame(raw, author_key, year)  (one row per
#                            (author, year) token; used by
#                            extract_definition_citations()).
#   strip_citations(text) -> text with year-bearing parenthetical groups
#                            removed (the embedded keypaper `abstract`; used by
#                            prepare_key_definitions()).
#
# `author_key` is the normalised FIRST surname of a citation (lower-case,
# diacritics folded, initials/particles dropped) — the join key used by
# resolve_citations() against the assessment's author metadata.

# 4-digit publication year, 1600–2099, optional disambiguation letter (2020a).
.CITE_YEAR <- "(1[6-9][0-9]{2}|20[0-9]{2})[a-z]?"

# Normalise a raw surname token to a match key: transliterate to ASCII,
# lower-case, keep letters only.
normalize_author_key <- function(x) {
  x <- iconv(x, from = "UTF-8", to = "ASCII//TRANSLIT")
  x[is.na(x)] <- ""
  x <- tolower(x)
  gsub("[^a-z]", "", x)
}

# From an author phrase preceding a year (e.g. "K. Brown & Westaway",
# Leading citation qualifiers that are NOT part of the author name and must be
# stripped before taking the surname — otherwise "(e.g. Kawaka et al., 2017)"
# yields author "e.g." and "(…; also: Babí Almenar et al., 2021)" yields "also".
.CITE_QUALIFIERS <- paste0(
  "^\\s*(?:",
  "e\\.?\\s*g\\.?|i\\.?\\s*e\\.?|cf\\.?|c\\.?\\s*f\\.?|viz\\.?|",
  "see\\s+also|see|but\\s+see|also|following|reviewed\\s+in|sensu|",
  "based\\s+on|adapted\\s+from|modified\\s+from|following\\s+the\\s+work\\s+of",
  ")\\b[\\s.,:;]*"
)

# Nobiliary / patronymic surname particles that belong WITH the following name
# (so "van Delden" is one surname, not "van"). Matched case-insensitively.
.SURNAME_PARTICLES <- c(
  "van", "von", "der", "den", "de", "del", "della", "dela", "di", "da",
  "das", "dos", "du", "la", "le", "les", "lo", "el", "al", "bin", "ibn",
  "ten", "ter", "st", "abu", "ben"
)

# Strip any run of leading qualifiers (handles "cf. also …", "e.g., see …").
.strip_leading_qualifiers <- function(s) {
  repeat {
    s2 <- sub(.CITE_QUALIFIERS, "", s, ignore.case = TRUE, perl = TRUE)
    s2 <- sub("^[[:space:].,:;]+", "", s2, perl = TRUE)
    if (identical(s2, s)) break
    s <- s2
  }
  s
}

# "Manuel-Navarrete & Pelling", "Tscharntke et al."), return the normalised
# first surname. Strips leading qualifiers ("e.g.", "also:", "see"), leading
# initials ("K.", "J. R.") and the "et al" tail, keeps hyphenated surnames whole.
.first_surname_key <- function(author_phrase) {
  s <- .strip_leading_qualifiers(trimws(author_phrase))
  # cut at the first author separator so we only look at the first author
  s <- strsplit(s, "\\s*(&|,| and | et al\\.?)\\s*",
                perl = TRUE)[[1]][1]
  s <- trimws(s)
  if (is.na(s) || !nzchar(s)) {
    return(NA_character_)
  }
  # drop leading initials like "K." / "J. R." / "J.R."
  toks <- strsplit(s, "\\s+")[[1]]
  toks <- toks[nzchar(toks)]
  is_initial <- grepl("^[A-Z]\\.?$", toks) | grepl("^([A-Z]\\.){1,3}$", toks)
  keep <- toks[!is_initial]
  if (!length(keep)) {
    keep <- toks[length(toks)]
  }
  # Absorb leading nobiliary/patronymic particles into the surname so
  # "van Delden" -> "vandelden" (not "van"), "de Vries" -> "devries",
  # "van der Berg" -> "vanderberg".
  i <- 1L
  parts <- character(0)
  while (i < length(keep) && tolower(keep[i]) %in% .SURNAME_PARTICLES) {
    parts <- c(parts, keep[i])
    i <- i + 1L
  }
  parts <- c(parts, keep[i]) # the head surname token
  key <- normalize_author_key(paste(parts, collapse = " "))
  if (!nzchar(key)) NA_character_ else key
}

# Extract every (author_key, year) citation token from one text string.
find_citations <- function(text) {
  empty <- data.frame(
    raw = character(0), author_key = character(0), year = integer(0),
    stringsAsFactors = FALSE
  )
  if (is.na(text) || !nzchar(text)) {
    return(empty)
  }

  rows <- list()

  ## 1. Narrative citations: `Surname (year)`, `Surname et al. (year)`,
  ##    `A & B (year)`, `A and B (year)`. The author phrase is capitalised
  ##    names, optionally joined by &/and and an "et al" tail, immediately
  ##    before a parenthesised year.
  # optional leading lowercase particle(s) so "van Delden (2021)" is captured
  # whole (not just "Delden"); capitalised particles fall under [A-Z] anyway.
  part_pre <- paste0("(?:(?:", paste(.SURNAME_PARTICLES, collapse = "|"),
                     ")\\s+)*")
  nar_name <- paste0(part_pre, "[A-Z][A-Za-z'’.-]+")
  nar_author <- paste0(
    nar_name,                                   # first surname (+ particle)
    "(?:\\s+(?:et\\s+al\\.?|&|and)\\s+",
    nar_name, ")*",                             # &/and/et-al continuations
    "(?:\\s+et\\s+al\\.?)?"
  )
  nar_re <- paste0("(", nar_author, ")\\s*\\(\\s*", .CITE_YEAR, "\\s*\\)")
  m <- gregexpr(nar_re, text, perl = TRUE)[[1]]
  if (m[1] != -1L) {
    starts <- attr(m, "capture.start")
    lens <- attr(m, "capture.length")
    full_raw <- regmatches(text, gregexpr(nar_re, text, perl = TRUE))[[1]]
    for (i in seq_along(full_raw)) {
      author_phrase <- substr(text, starts[i, 1], starts[i, 1] + lens[i, 1] - 1)
      year_str <- substr(text, starts[i, 2], starts[i, 2] + lens[i, 2] - 1)
      rows[[length(rows) + 1]] <- data.frame(
        raw = full_raw[i],
        author_key = .first_surname_key(author_phrase),
        year = as.integer(sub("[a-z]$", "", year_str)),
        stringsAsFactors = FALSE
      )
    }
  }

  ## 2. Parenthetical citations: any `(...)` group that contains a year.
  ##    Split multi-cites on ';'. A chunk with no author text before the year
  ##    (i.e. the paren holds only a year) is the tail of a narrative citation
  ##    already captured in step 1 — skip it.
  paren <- regmatches(text, gregexpr("\\([^()]*\\)", text, perl = TRUE))[[1]]
  paren <- paren[grepl(.CITE_YEAR, paren, perl = TRUE)]
  for (grp in paren) {
    inner <- sub("^\\(", "", sub("\\)$", "", grp))
    for (chunk in strsplit(inner, ";")[[1]]) {
      chunk <- trimws(chunk)
      yrs <- regmatches(chunk, gregexpr(.CITE_YEAR, chunk, perl = TRUE))[[1]]
      if (!length(yrs)) next
      author_part <- trimws(sub(paste0(.CITE_YEAR, ".*$"), "", chunk,
                                perl = TRUE))
      author_part <- trimws(gsub("[,;]+$", "", author_part))
      if (!nzchar(author_part)) next # narrative tail — handled in step 1
      key <- .first_surname_key(author_part)
      for (y in yrs) {
        rows[[length(rows) + 1]] <- data.frame(
          raw = grp,
          author_key = key,
          year = as.integer(sub("[a-z]$", "", y)),
          stringsAsFactors = FALSE
        )
      }
    }
  }

  if (!length(rows)) {
    return(empty)
  }
  out <- do.call(rbind, rows)
  out <- out[!is.na(out$author_key) & !is.na(out$year), , drop = FALSE]
  out <- unique(out)
  rownames(out) <- NULL
  out
}

# Remove year-bearing parenthetical groups from a definition (both
# `(Author, year)` citations and the `(year)` tail of narrative citations).
# Least-destructive to sentence grammar: narrative author names remain as
# sentence subjects, only the citation apparatus is dropped. Whitespace and
# stranded punctuation are tidied afterwards.
strip_citations <- function(text) {
  if (is.na(text) || !nzchar(text)) {
    return(text)
  }
  year_paren <- paste0("\\([^()]*", .CITE_YEAR, "[^()]*\\)")
  out <- gsub(year_paren, "", text, perl = TRUE)
  out <- gsub("\\s+([,.;:])", "\\1", out, perl = TRUE) # space before punct
  out <- gsub("\\(\\s*[;,]?\\s*\\)", "", out, perl = TRUE) # empty parens
  out <- gsub("[ \t]{2,}", " ", out, perl = TRUE)
  trimws(out)
}

# Write a citations table (must have a `keyset` column) to a hive dataset
# partitioned by keyset, rebuilding `out_dir` cleanly. Used for both the
# extracted and resolved citation datasets (which live under
# citations_extracted/method=<m>/ and citations_resolved/method=<m>/). Handles
# the empty case (writes a single flat part-0.parquet so the dir is still a
# readable dataset). Returns out_dir.
write_citations_dataset <- function(df, out_dir) {
  if (dir.exists(out_dir)) unlink(out_dir, recursive = TRUE)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  if (nrow(df) > 0L) {
    arrow::write_dataset(
      df, path = out_dir, partitioning = "keyset",
      format = "parquet", basename_template = "part-{i}.parquet"
    )
  } else {
    arrow::write_parquet(df, file.path(out_dir, "part-0.parquet"))
  }
  out_dir
}
