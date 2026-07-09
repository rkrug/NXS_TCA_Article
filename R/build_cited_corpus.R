# Build the new `corpus` = the works actually cited inside the definitions.
#
# Takes the resolved-citation table (resolve_citations()) and selects the
# matching records out of `corpus_chapter` (they are guaranteed to be present —
# resolution only accepts matches confirmed in corpus_chapter). Deduplicated to
# one row per work (a work cited by several definitions / keysets appears once),
# same schema as corpus_chapter, written FLAT (no assessment/chapter hive) so
# the embedding layer treats it as a single source=corpus partition.
#
# Output: output/NXS_TCA_corpus/corpus/part-0.parquet ; returns the dir.

build_cited_corpus <- function(resolved_dir,
                               corpus_chapter_dir,
                               out_dir = "output/NXS_TCA_corpus/corpus") {
  if (normalizePath(out_dir, mustWork = FALSE) ==
        normalizePath(corpus_chapter_dir, mustWork = FALSE)) {
    stop("build_cited_corpus(): out_dir must differ from corpus_chapter_dir ",
         "(would wipe the source corpus).")
  }
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  resolved_glob <- file.path(resolved_dir, "**", "*.parquet")
  corpus_glob <- file.path(corpus_chapter_dir, "**", "*.parquet")

  matched <- DBI::dbGetQuery(con, sprintf(
    "SELECT DISTINCT matched_id FROM read_parquet(%s)
       WHERE matched_id IS NOT NULL",
    DBI::dbQuoteString(con, resolved_glob)
  ))

  if (dir.exists(out_dir)) unlink(out_dir, recursive = TRUE)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  out_file <- file.path(out_dir, "part-0.parquet")

  # Dedup corpus_chapter to one row per id (it is duplicated across chapters),
  # keep only cited ids, drop the hive-partition columns so the flat corpus
  # schema matches what embed_works expects from a single-source dataset.
  DBI::dbExecute(con, sprintf(
    "COPY (
       SELECT * EXCLUDE (assessment, chapter, rn) FROM (
         SELECT *, row_number() OVER (PARTITION BY id ORDER BY chapter) AS rn
         FROM read_parquet(%s, hive_partitioning = true)
         WHERE id IN (SELECT matched_id FROM read_parquet(%s)
                        WHERE matched_id IS NOT NULL)
       ) WHERE rn = 1
     ) TO %s (FORMAT PARQUET)",
    DBI::dbQuoteString(con, corpus_glob),
    DBI::dbQuoteString(con, resolved_glob),
    DBI::dbQuoteString(con, out_file)
  ))

  n <- DBI::dbGetQuery(con, sprintf(
    "SELECT count(*) n FROM read_parquet(%s)",
    DBI::dbQuoteString(con, out_file)
  ))$n
  message(sprintf(
    "[build_cited_corpus] %d distinct cited works (of %d resolved citations)",
    n, nrow(matched)
  ))
  out_dir
}
