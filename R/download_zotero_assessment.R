# Flatten one Zotero API item into one or more rows.
#
# Chapter tags (Zotero tags matching `chapter_pattern`, e.g. "Chapter 1")
# become an extra hive-partition column. An item tagged with several
# chapters is emitted once per chapter (intentional duplication — the
# `chapter=` partition is a view onto the item, not a unique key); an item
# with no chapter tag gets a single row with chapter = "No Chapter". All
# tags (chapter and otherwise) are also preserved verbatim in a `tags`
# column, semicolon-joined, for downstream use.
zotero_item_to_row <- function(item, assessment_id, chapter_pattern = "^Chapter") {
  d <- item$data
  creators <- if (!is.null(d$creators)) d$creators else list()

  get_last_name <- function(c) {
    if (!is.null(c$lastName) && nchar(c$lastName) > 0) {
      c$lastName
    } else if (!is.null(c$name) && nchar(c$name) > 0) {
      c$name
    } else {
      NA_character_
    }
  }

  first_author <- if (length(creators) > 0) {
    get_last_name(creators[[1]])
  } else {
    NA_character_
  }
  authors <- if (length(creators) > 0) {
    parts <- vapply(creators, get_last_name, character(1))
    paste(parts[!is.na(parts)], collapse = "; ")
  } else {
    NA_character_
  }

  year_str <- if (!is.null(d$date) && nchar(d$date) > 0) {
    m <- regmatches(d$date, regexpr("[12][0-9]{3}", d$date))
    if (length(m) == 1L) m else NA_character_
  } else {
    NA_character_
  }

  chr <- function(x) {
    if (is.null(x) || length(x) == 0L) NA_character_ else as.character(x[[1L]])
  }

  # All tags on the item (verbatim), plus the chapter tags used for
  # partitioning.
  tag_strings <- if (length(d$tags) > 0) {
    vapply(d$tags, function(t) chr(t$tag), character(1))
  } else {
    character(0)
  }
  tag_strings <- tag_strings[!is.na(tag_strings) & nzchar(tag_strings)]

  chapters <- grep(chapter_pattern, tag_strings, value = TRUE, ignore.case = TRUE)
  if (length(chapters) == 0L) {
    chapters <- "No Chapter"
  }

  base <- data.frame(
    key = chr(d$key),
    item_type = chr(d$itemType),
    title = chr(d$title),
    authors = if (!is.na(authors) && nchar(authors) > 0) {
      authors
    } else {
      NA_character_
    },
    first_author = first_author,
    year = year_str,
    doi = chr(d$DOI),
    abstract = chr(d$abstractNote),
    tags = if (length(tag_strings) > 0) {
      paste(tag_strings, collapse = "; ")
    } else {
      NA_character_
    },
    zotero_url = paste0(
      "https://www.zotero.org/groups/",
      assessment_id,
      "/items/",
      chr(d$key)
    ),
    stringsAsFactors = FALSE
  )

  # One row per chapter (duplicates the item across chapters it belongs to).
  out <- base[rep(1L, length(chapters)), , drop = FALSE]
  out$chapter <- chapters
  rownames(out) <- NULL
  out
}

# Download all top-level items from a Zotero group library (public or
# private). `api_key` is only needed for private groups (e.g. the NXS
# assessment literature group) — pass NULL/"" for public groups (e.g. TCA).
download_zotero_assessment <- function(
  assessment_id,
  assessment_label,
  api_key = NULL,
  output_root = "output/NXS_TCA_corpus/zotero",
  chapter_pattern = "^Chapter"
) {
  output_path <- file.path(output_root, paste0("assessment=", assessment_label))
  base_url <- paste0("https://api.zotero.org/groups/", assessment_id, "/items/top")

  req <- httr2::request(base_url)
  if (!is.null(api_key) && nzchar(api_key)) {
    req <- httr2::req_headers(req, `Zotero-API-Key` = api_key)
  }

  resp0 <- req |>
    httr2::req_url_query(limit = 1, format = "json") |>
    httr2::req_perform()
  total <- as.integer(httr2::resp_header(resp0, "Total-Results"))
  if (is.na(total) || total == 0L) {
    stop("Zotero group ", assessment_id, ": Total-Results header missing or zero")
  }
  message("Zotero group ", assessment_id, " (", assessment_label, "): ", total, " top-level items")

  limit <- 100
  starts <- seq(0, total - 1, by = limit)

  if (dir.exists(output_path)) {
    unlink(output_path, recursive = TRUE, force = TRUE)
  }
  dir.create(output_path, showWarnings = FALSE, recursive = TRUE)

  # Accumulate all pages, then write once. Partitioning by chapter alone
  # rules out the incremental per-page write (a later page's `delete_matching`
  # would wipe an earlier page's rows for the same chapter), and a Zotero
  # library is small enough to hold in memory.
  page_frames <- vector("list", length(starts))
  for (i in seq_along(starts)) {
    start <- starts[[i]]
    message(
      "  Fetching items ", start + 1L, "-", min(start + limit, total), " of ", total
    )

    resp <- req |>
      httr2::req_url_query(limit = limit, start = start, format = "json") |>
      httr2::req_throttle(rate = 5) |>
      httr2::req_perform()

    items <- jsonlite::fromJSON(
      httr2::resp_body_string(resp),
      simplifyVector = FALSE
    )
    if (!length(items)) {
      next
    }
    page_frames[[i]] <- dplyr::bind_rows(lapply(
      items, zotero_item_to_row,
      assessment_id = assessment_id, chapter_pattern = chapter_pattern
    ))
  }

  combined <- as.data.frame(dplyr::bind_rows(page_frames))

  # De-duplicate within each chapter (keep the per-chapter copies of a
  # multi-chapter item, but collapse any repeat of the same item inside one
  # chapter).
  before <- nrow(combined)
  combined <- dplyr::distinct(combined, chapter, key, .keep_all = TRUE)
  n_dupes <- before - nrow(combined)
  if (n_dupes > 0L) {
    message("  Removed ", n_dupes, " within-chapter duplicate row(s)")
  }

  arrow::write_dataset(
    dataset = combined,
    path = output_path,
    format = "parquet",
    partitioning = "chapter",
    existing_data_behavior = "delete_matching"
  )

  message(
    "Wrote ", nrow(combined), " rows to ", output_path,
    " across ", dplyr::n_distinct(combined$chapter), " chapter partition(s)"
  )

  output_path
}
