make_pilot_subset <- function(corpus_path, out_dir, n) {
  if (is.null(n)) return(corpus_path)
  unlink(out_dir, recursive = TRUE)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  arrow::open_dataset(corpus_path) |>
    dplyr::select(id, title, abstract) |>
    head(n) |>
    dplyr::collect() |>
    arrow::write_parquet(file.path(out_dir, "part_0.parquet"))
  out_dir
}
