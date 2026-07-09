# Derive the cited-corpus embeddings (source=corpus) by filtering the already
# computed chapter-corpus embeddings (source=corpus_chapter) down to the works
# actually cited in the definitions. The cited corpus is a strict subset of
# corpus_chapter and shares the same SPECTER2 config, so its embeddings are
# identical to the corresponding corpus_chapter rows — no TEI re-embedding
# needed. One variant per call; deduplicated to one row per work id.
#
# Writes:
#   <out_dir>/config=<config_name>/source=<source>/variant=<variant>/part-0.parquet
# and returns that variant directory (format = "file" target, wire-compatible
# with the emb_corpus_chapter_* combiner handles).

derive_source_embeddings <- function(chapter_variant_dir,
                                     cited_corpus_dir,
                                     config_name,
                                     variant,
                                     source = "corpus",
                                     out_dir = "output/NXS_TCA_corpus/embeddings") {
  leaf_dir <- file.path(
    out_dir,
    paste0("config=", config_name),
    paste0("source=", source),
    paste0("variant=", variant)
  )
  if (dir.exists(leaf_dir)) unlink(leaf_dir, recursive = TRUE)
  dir.create(leaf_dir, recursive = TRUE, showWarnings = FALSE)
  out_file <- file.path(leaf_dir, "part-0.parquet")

  emb_glob <- file.path(chapter_variant_dir, "**", "*.parquet")
  cited_glob <- file.path(cited_corpus_dir, "**", "*.parquet")

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  # One row per cited work id: pick any (identical) embedding row for that id.
  # hive_partitioning = false so the assessment=/chapter= path segments do not
  # become spurious columns — the derived flat corpus embeddings keep only the
  # native embedding schema (id, V*, provenance).
  DBI::dbExecute(con, sprintf(
    "COPY (
       SELECT * EXCLUDE (rn) FROM (
         SELECT e.*, row_number() OVER (PARTITION BY e.id) AS rn
         FROM read_parquet(%s, hive_partitioning = false,
                           union_by_name = true) e
         WHERE e.id IN (SELECT id FROM read_parquet(%s))
       ) WHERE rn = 1
     ) TO %s (FORMAT PARQUET)",
    DBI::dbQuoteString(con, emb_glob),
    DBI::dbQuoteString(con, cited_glob),
    DBI::dbQuoteString(con, out_file)
  ))

  n <- DBI::dbGetQuery(con, sprintf(
    "SELECT count(*) n FROM read_parquet(%s)",
    DBI::dbQuoteString(con, out_file)
  ))$n
  message(sprintf(
    "[derive_source_embeddings] source=%s variant=%s: %d cited-work embeddings",
    source, variant, n
  ))
  leaf_dir
}
