slugify <- function(x) {
  s <- tolower(trimws(x))
  s <- gsub("[^a-z0-9]+", "-", s)
  s <- gsub("^-+|-+$", "", s)
  s
}

prepare_key_works <- function(raw_csv) {
  raw <- utils::read.csv(
    raw_csv,
    colClasses = "character",
    encoding = "UTF-8",
    stringsAsFactors = FALSE
  )
  names(raw)[1:4] <- c("title", "abstract", "link", "type")

  df <- raw |>
    dplyr::mutate(dplyr::across(dplyr::everything(), trimws)) |>
    dplyr::filter(
      nzchar(abstract, keepNA = FALSE) |
        nzchar(link, keepNA = FALSE) |
        nzchar(type, keepNA = FALSE)
    ) |>
    dplyr::mutate(
      type = dplyr::na_if(tolower(type), ""),
      abstract = dplyr::na_if(abstract, ""),
      link = dplyr::na_if(link, ""),
      id = paste0("kp-", slugify(title))
    )

  df$id <- make.unique(df$id, sep = "-")

  out <- df |>
    dplyr::select(id, title, abstract, link, type)

  out_dir <- "output/TCAC_2.0/keypaper"
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  out_file <- file.path(out_dir, "key_works.parquet")
  arrow::write_parquet(out, out_file)

  out_file
}
