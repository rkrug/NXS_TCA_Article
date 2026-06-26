# Resume the consolidation step of embed_works() for a corpus variant
# whose scratch shards under .raw/ are intact but the leaf
# parts (and/or .embed_complete marker) are missing.
#
# Use when an embed run finished the TEI stage but crashed during the
# duckdb COPY (e.g. disk-full). The script runs only the consolidation
# step + writes the marker, matching the logic in R/embed_works.R.
#
# Run from the project root, passing the variant name. Defaults to
# `abstract` for backwards-compatibility with the original use case.
#
#   Rscript scripts/consolidate_abstract_leaf.R abstract
#   Rscript scripts/consolidate_abstract_leaf.R title
#   Rscript scripts/consolidate_abstract_leaf.R title_abstract

library(DBI)
library(duckdb)

args <- commandArgs(trailingOnly = TRUE)
variant_name <- if (length(args) >= 1L) args[[1]] else "abstract"
config_name  <- if (length(args) >= 2L) args[[2]] else "SPECTER2_runpod"
source_name  <- if (length(args) >= 3L) args[[3]] else "corpus"

out_root <- "output/TCAC_2.0/embeddings"
cat(sprintf("[%s|%s|%s] consolidating from .raw scratch shards\n",
            config_name, source_name, variant_name))

scratch_project <- file.path(out_root, ".raw", config_name, source_name, variant_name)
if (!dir.exists(scratch_project)) {
  stop("scratch dir does not exist: ", scratch_project)
}

# Discover the model_id partition (there should be exactly one)
model_dirs <- list.dirs(
  file.path(scratch_project, "embeddings"),
  recursive = FALSE
)
model_dirs <- model_dirs[grepl("model_id=", basename(model_dirs))]
if (length(model_dirs) != 1L) {
  stop("expected exactly one model_id= subdir under embeddings/, found: ",
       length(model_dirs))
}
raw_label_dir <- file.path(model_dirs[[1]], paste0("label=", variant_name))
if (!dir.exists(raw_label_dir)) {
  stop("scratch label dir does not exist: ", raw_label_dir)
}

leaf_dir <- file.path(
  out_root,
  paste0("config=", config_name),
  paste0("source=", source_name),
  paste0("variant=", variant_name)
)
tmp_dir <- file.path(leaf_dir, ".parts.tmp")

n_shards <- length(list.files(raw_label_dir, pattern = "[.]parquet$", recursive = TRUE))
if (n_shards == 0L) stop("no scratch parquets found under ", raw_label_dir)
cat(sprintf("scratch shards found: %d under %s\n", n_shards, raw_label_dir))

# Clean any stale state in the leaf so we get a clean consolidation
if (dir.exists(tmp_dir)) unlink(tmp_dir, recursive = TRUE)
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(leaf_dir, recursive = TRUE, showWarnings = FALSE)
old_parts <- list.files(leaf_dir, pattern = "^part-.*[.]parquet$", full.names = TRUE)
if (length(old_parts)) file.remove(old_parts)
old_marker <- file.path(leaf_dir, ".embed_complete")
if (file.exists(old_marker)) file.remove(old_marker)

shards_glob <- file.path(raw_label_dir, "batch=*", "embeddings-*.parquet")
cat("glob:", shards_glob, "\n")

con <- dbConnect(duckdb::duckdb())
on.exit(try(dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
try(dbExecute(con, "PRAGMA enable_progress_bar"), silent = TRUE)
try(dbExecute(con, "PRAGMA progress_bar_time = 1000"), silent = TRUE)

copy_sql <- sprintf(
  "COPY (
     SELECT * EXCLUDE (filename),
            CAST(regexp_extract(filename, '-(\\d+)\\.parquet$', 1) AS INTEGER) AS batch
     FROM read_parquet('%s', filename = true)
   ) TO '%s' (
     FORMAT PARQUET,
     ROW_GROUP_SIZE 50000,
     FILE_SIZE_BYTES 1000000000,
     FILENAME_PATTERN 'part-{i}',
     COMPRESSION SNAPPY,
     OVERWRITE_OR_IGNORE
   )",
  shards_glob, tmp_dir
)
dbExecute(con, copy_sql)

n_written <- as.integer(dbGetQuery(con, sprintf(
  "SELECT COUNT(*)::BIGINT AS n FROM read_parquet('%s/*.parquet')", tmp_dir
))$n)
cat("rows written:", format(n_written, big.mark = ","), "\n")
dbDisconnect(con, shutdown = TRUE)

# Move parts from tmp into the leaf, drop the tmp dir
new_parts <- list.files(tmp_dir, pattern = "^part-.*[.]parquet$", full.names = TRUE)
if (!length(new_parts)) stop("duckdb COPY produced no parquet files under ", tmp_dir)
for (p in new_parts) file.rename(p, file.path(leaf_dir, basename(p)))
unlink(tmp_dir, recursive = TRUE)
cat("moved", length(new_parts), "parquet files into", leaf_dir, "\n")

# Write the completion marker (matches write_embed_marker in R/embed_works.R)
marker_path <- file.path(leaf_dir, ".embed_complete")
writeLines(as.character(n_written), marker_path)
cat("marker:", marker_path, "->", n_written, "\n")

# Verify via arrow
n_read <- arrow::open_dataset(leaf_dir) |>
  dplyr::summarise(n = dplyr::n()) |>
  dplyr::collect()
cat("arrow sees:", format(n_read$n, big.mark = ","), "rows\n")
if (n_read$n != n_written) {
  warning(sprintf(
    "row count mismatch: duckdb wrote %s, arrow reads %s",
    n_written, n_read$n
  ))
}

cat("\nIf the row count is what you expect, reclaim disk by removing the scratch tree:\n")
cat(sprintf("  unlink(%s, recursive = TRUE)\n", deparse(scratch_project)))
