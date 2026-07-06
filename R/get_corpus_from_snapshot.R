# Build corpus records for the unmatched Zotero items in one chapter: items
# whose DOI did not resolve to an OpenAlex work (or that have no DOI) but that
# have BOTH a title and an abstract in Zotero. id = "zotero:<KEY>". Columns are
# restricted to the OpenAlex extract's columns (`oa_cols`) we can reasonably
# fill from Zotero, plus a `record_source` marker. Returns NULL if none.
build_zotero_fallback <- function(zotero_path, ids_ds, ch, oa_cols) {
  z <- arrow::open_dataset(zotero_path) |>
    dplyr::filter(chapter == ch) |>
    dplyr::select(dplyr::any_of(c(
      "key", "title", "abstract", "doi", "item_type", "year"
    ))) |>
    dplyr::collect()
  if (nrow(z) == 0L) {
    return(NULL)
  }

  # Which Zotero DOIs actually resolved to an OpenAlex work in this chapter.
  z$doi_norm <- openalexPro::extract_doi(
    z$doi, non_doi_value = "", normalize = TRUE, what = "doi"
  )
  matched <- ids_ds |>
    dplyr::filter(chapter == ch) |>
    dplyr::select("doi") |>
    dplyr::collect() |>
    dplyr::pull(doi)
  matched_norm <- openalexPro::extract_doi(
    matched, non_doi_value = "", normalize = TRUE, what = "doi"
  )
  matched_norm <- unique(matched_norm[nzchar(matched_norm)])

  is_matched <- nzchar(z$doi_norm) & z$doi_norm %in% matched_norm
  has_text <- !is.na(z$title) & nzchar(trimws(z$title)) &
    !is.na(z$abstract) & nzchar(trimws(z$abstract))
  z <- z[!is_matched & has_text, , drop = FALSE]
  if (nrow(z) == 0L) {
    return(NULL)
  }

  fb <- data.frame(
    id = paste0("zotero:", z$key),
    title = z$title,
    abstract = z$abstract,
    stringsAsFactors = FALSE
  )
  # Fill additional OpenAlex columns from Zotero where we reasonably can.
  if ("doi" %in% oa_cols) {
    fb$doi <- z$doi_norm
  }
  if ("type" %in% oa_cols) {
    fb$type <- z$item_type
  }
  if ("publication_year" %in% oa_cols) {
    fb$publication_year <- suppressWarnings(as.integer(z$year))
  }
  fb$record_source <- "zotero"

  # Never introduce a column the OpenAlex extract lacks (besides the new
  # record_source), so the two sides union into one clean schema.
  keep <- intersect(names(fb), c(oa_cols, "record_source"))
  fb[, keep, drop = FALSE]
}

get_corpus_from_snapshot <- function(
  ids_db,
  snapshot_dir,
  project_folder,
  workers,
  zotero_path = NULL,
  dest_dir = file.path(project_folder, "corpus")
) {
  # Safety guard: if `dest_dir` already exists and is not writable, treat it
  # as an intentionally frozen artefact — reuse it as-is and skip snapshot
  # extraction entirely (never wipe it). A genuine rebuild is still
  # possible: `chmod -R u+w` the dir first, and this guard steps aside so
  # the normal destructive extraction runs.
  if (dir.exists(dest_dir) && file.access(dest_dir, mode = 2L) != 0L) {
    message(
      "[get_corpus_from_snapshot] '", dest_dir, "' is read-only — reusing ",
      "the existing contents, skipping snapshot extraction. ",
      "`chmod -R u+w` it to force a rebuild."
    )
    return(dest_dir)
  }

  # Zotero fallback (unmatched works with title+abstract) is merged in via
  # duckdb's UNION ALL BY NAME — every chapter is routed through the same
  # duckdb→arrow path so all partitions share one column schema.
  use_fallback <- !is.null(zotero_path)
  if (use_fallback) {
    for (pkg in c("duckdb", "DBI")) {
      if (!requireNamespace(pkg, quietly = TRUE)) {
        stop("Package '", pkg, "' is required for the Zotero fallback in ",
             "get_corpus_from_snapshot(). Install it or pass zotero_path = NULL.")
      }
    }
  }

  unlink(dest_dir, recursive = TRUE, force = TRUE)

  # ids_db is hive-partitioned by chapter (see get_ids_from_dois()). Extract
  # each chapter's works from the snapshot independently and write the corpus
  # chapter-partitioned too (dest_dir/chapter=<c>/…). A work belonging to
  # several chapters is extracted once per chapter and duplicated across the
  # corresponding partitions — intentional at this stage.
  ids_ds <- arrow::open_dataset(ids_db)
  chapters <- ids_ds |>
    dplyr::distinct(chapter) |>
    dplyr::collect() |>
    dplyr::pull(chapter)
  chapters <- sort(chapters)

  scratch <- file.path(project_folder, "_corpus_scratch")

  for (ch in chapters) {
    ids <- ids_ds |>
      dplyr::filter(chapter == ch) |>
      dplyr::select("id") |>
      dplyr::distinct() |>
      dplyr::collect() |>
      dplyr::pull(id)
    if (length(ids) == 0L) {
      next
    }
    message("[get_corpus_from_snapshot] chapter '", ch, "': ", length(ids), " works")

    unlink(scratch, recursive = TRUE, force = TRUE)
    openalexSnapshot::lookup_by_id(
      root_dir = snapshot_dir,
      ids = ids,
      project_dir = scratch,
      data_sets = "works",
      workers = workers
    )
    extract_dir <- file.path(scratch, "snapshot_extract_works")

    if (!use_fallback) {
      # No Zotero fallback: tag provenance and write directly via arrow.
      arrow::open_dataset(extract_dir) |>
        dplyr::mutate(chapter = ch, record_source = "openalex") |>
        arrow::write_dataset(
          dest_dir,
          partitioning = "chapter",
          existing_data_behavior = "delete_matching"
        )
      next
    }

    oa_cols <- names(arrow::open_dataset(extract_dir))
    fb <- build_zotero_fallback(zotero_path, ids_ds, ch, oa_cols)

    extract_files <- list.files(
      extract_dir, pattern = "\\.parquet$", recursive = TRUE, full.names = TRUE
    )
    if (length(extract_files) == 0L) {
      next
    }
    files_sql <- paste(sprintf("'%s'", extract_files), collapse = ", ")

    if (is.null(fb)) {
      select_sql <- sprintf(
        "SELECT *, 'openalex' AS record_source FROM read_parquet([%s])",
        files_sql
      )
    } else {
      message("  + ", nrow(fb), " unmatched Zotero fallback record(s)")
      fb_path <- file.path(scratch, "zotero_fallback.parquet")
      arrow::write_parquet(fb, fb_path)
      select_sql <- sprintf(
        "SELECT *, 'openalex' AS record_source FROM read_parquet([%s])
         UNION ALL BY NAME
         SELECT * FROM read_parquet('%s')",
        files_sql, fb_path
      )
    }

    # duckdb streams the union and null-fills columns the fallback lacks;
    # write to a single flat parquet, then let arrow do the chapter-
    # partitioned write (same encoding as the rest of the pipeline).
    combined_file <- file.path(scratch, "combined.parquet")
    con <- DBI::dbConnect(duckdb::duckdb())
    DBI::dbExecute(con, sprintf(
      "COPY (%s) TO '%s' (FORMAT PARQUET)", select_sql, combined_file
    ))
    DBI::dbDisconnect(con, shutdown = TRUE)

    arrow::open_dataset(combined_file) |>
      dplyr::mutate(chapter = ch) |>
      arrow::write_dataset(
        dest_dir,
        partitioning = "chapter",
        existing_data_behavior = "delete_matching"
      )
  }

  unlink(scratch, recursive = TRUE, force = TRUE)
  return(dest_dir)
}
