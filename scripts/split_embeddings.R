#!/usr/bin/env Rscript
# Split single oversized part-0.parquet files in each embedding leaf into
# ~1 GB chunks via duckdb COPY ... TO ... (FILE_SIZE_BYTES ...).
#
# Run once after the initial embed_works pipeline produced monolithic
# files. The pipeline itself now emits multi-file leaves natively; this
# script is only for pre-existing single-file leaves.
#
# Usage:
#   Rscript scripts/split_embeddings.R
#
# Defaults to splitting both `source=corpus` variants `title` and
# `title_abstract` (the big ones). Pass --include / --variants to widen.
#
# Safety: writes into a sibling `.parts.tmp/` dir, verifies row count,
# only then swaps in. On row-count mismatch leaves everything alone for
# inspection.

suppressPackageStartupMessages({
  library(duckdb)
  library(DBI)
})

# ---- knobs ---------------------------------------------------------------
target_bytes_per_file <- 1e9 # ~1 GB / file
row_group_size <- 50000 # row group size inside each file
emb_root <- "output/TCAC_2.0/embeddings/config=SPECTER2_runpod"
sources <- c("corpus") # keypapers are tiny; skip
variants <- c("title", "title_abstract", "abstract")

# ---- helpers -------------------------------------------------------------
split_one <- function(leaf_dir, src_label) {
  src_file <- file.path(leaf_dir, "part-0.parquet")
  if (!file.exists(src_file)) {
    message(sprintf("  [%s] skip: no part-0.parquet", src_label))
    return(invisible(NULL))
  }
  tmp_dir <- file.path(leaf_dir, ".parts.tmp")
  if (dir.exists(tmp_dir)) {
    unlink(tmp_dir, recursive = TRUE)
  }
  dir.create(tmp_dir, recursive = TRUE)

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(
    try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE),
    add = TRUE
  )
  try(DBI::dbExecute(con, "PRAGMA enable_progress_bar"), silent = TRUE)
  try(DBI::dbExecute(con, "PRAGMA progress_bar_time = 1000"), silent = TRUE)

  src_quoted <- gsub("'", "''", src_file, fixed = TRUE)
  tmp_quoted <- gsub("'", "''", tmp_dir, fixed = TRUE)

  copy_sql <- sprintf(
    "COPY (SELECT * FROM read_parquet('%s'))
     TO '%s' (
       FORMAT PARQUET,
       ROW_GROUP_SIZE %d,
       FILE_SIZE_BYTES %d,
       FILENAME_PATTERN 'part-{i}',
       COMPRESSION SNAPPY,
       OVERWRITE_OR_IGNORE
     )",
    src_quoted,
    tmp_quoted,
    as.integer(row_group_size),
    as.integer(target_bytes_per_file)
  )
  message(sprintf(
    "  [%s] COPY → %s (target %s GB/file)",
    src_label,
    tmp_dir,
    format(target_bytes_per_file / 1e9, digits = 2)
  ))
  DBI::dbExecute(con, copy_sql)

  src_rows <- as.integer(
    DBI::dbGetQuery(
      con,
      sprintf(
        "SELECT COUNT(*)::BIGINT AS n FROM read_parquet('%s')",
        src_quoted
      )
    )$n
  )
  new_rows <- as.integer(
    DBI::dbGetQuery(
      con,
      sprintf(
        "SELECT COUNT(*)::BIGINT AS n FROM read_parquet('%s/*.parquet')",
        tmp_quoted
      )
    )$n
  )
  DBI::dbDisconnect(con, shutdown = TRUE)

  new_parts <- list.files(
    tmp_dir,
    pattern = "^part-.*[.]parquet$",
    full.names = TRUE
  )
  file_sizes_mb <- round(file.size(new_parts) / 1e6, 1)

  message(sprintf(
    "  [%s] orig=%s rows   new=%s rows across %d files (sizes MB: %s)",
    src_label,
    format(src_rows, big.mark = ","),
    format(new_rows, big.mark = ","),
    length(new_parts),
    paste(file_sizes_mb, collapse = ", ")
  ))

  if (src_rows != new_rows) {
    message(sprintf(
      "  [%s] ROW COUNT MISMATCH — leaving %s in place for inspection",
      src_label,
      tmp_dir
    ))
    return(invisible(NULL))
  }
  if (length(new_parts) == 0L) {
    message(sprintf(
      "  [%s] COPY produced no files — leaving things alone",
      src_label
    ))
    return(invisible(NULL))
  }

  # swap in
  file.remove(src_file)
  for (p in new_parts) {
    file.rename(p, file.path(leaf_dir, basename(p)))
  }
  unlink(tmp_dir, recursive = TRUE)
  message(sprintf(
    "  [%s] OK — split into %d files",
    src_label,
    length(new_parts)
  ))
  invisible(NULL)
}

# ---- run -----------------------------------------------------------------
for (s in sources) {
  for (v in variants) {
    leaf <- file.path(emb_root, paste0("source=", s), paste0("variant=", v))
    if (!dir.exists(leaf)) {
      next
    }
    label <- sprintf("%s/%s", s, v)
    message(sprintf("[%s] leaf = %s", label, leaf))
    split_one(leaf, label)
  }
}
message("done.")
