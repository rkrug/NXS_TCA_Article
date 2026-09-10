# Resolves OpenAlex ids for a Zotero-derived set of DOIs via the live API.
# These fed get_corpus_from_snapshot() (since retired -- corpus_chapter is
# now a frozen static input, see CLAUDE.md) and still feed resolve_citations().
#
# The Zotero dataset is hive-partitioned by chapter (assessment=<label>/
# chapter=<c>/…). We iterate those chapter partitions and resolve each
# chapter's DOIs independently, writing the ids out chapter-partitioned too
# (ids/chapter=<c>/…). A work tagged with several chapters is therefore
# resolved once per chapter and appears under each — intentional
# duplication, carried downstream into the corpus.
get_ids_from_dois <- function(
  zotero_path,
  project_folder,
  workers,
  dest_dir = file.path(project_folder, "ids")
) {
  unlink(dest_dir, recursive = TRUE, force = TRUE)

  zds <- arrow::open_dataset(zotero_path)
  chapters <- zds |>
    dplyr::distinct(chapter) |>
    dplyr::collect() |>
    dplyr::pull(chapter)
  chapters <- sort(chapters)

  scratch <- file.path(project_folder, "_ids_scratch")

  for (ch in chapters) {
    dois_raw <- zds |>
      dplyr::filter(chapter == ch) |>
      dplyr::select(doi) |>
      dplyr::collect() |>
      dplyr::pull(doi)

    dois <- openalexPro::extract_doi(
      dois_raw,
      non_doi_value = "",
      normalize = TRUE,
      what = "doi"
    )
    n_missing <- sum(!nzchar(dois))
    dois <- unique(dois[nzchar(dois)])
    message(
      "[get_ids_from_dois] chapter '", ch, "': ", length(dois),
      " resolvable DOI(s); ", n_missing, " item(s) dropped (missing/invalid DOI)."
    )
    if (length(dois) == 0L) {
      next
    }

    unlink(scratch, recursive = TRUE, force = TRUE)
    query <- openalexPro::pro_query(entity = "works", doi = dois, select = c("id", "doi"))
    openalexPro::pro_fetch(
      query,
      pages = NULL,
      project_folder = scratch,
      api_key = keyring::key_get("API_openalex"),
      workers = workers,
      progress = TRUE,
      delete_input = TRUE,
      overwrite = TRUE
    )

    # Stamp the chapter and append to the chapter-partitioned ids dataset.
    arrow::open_dataset(file.path(scratch, "parquet")) |>
      dplyr::mutate(chapter = ch) |>
      arrow::write_dataset(
        dest_dir,
        partitioning = "chapter",
        existing_data_behavior = "delete_matching"
      )
  }

  unlink(scratch, recursive = TRUE, force = TRUE)
  dest_dir
}
