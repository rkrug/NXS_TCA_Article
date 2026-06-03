get_key_works <- function(
  kp_tcac10_fn,
  project_folder,
  workers
) {
  unlink(
    file.path(
      project_folder,
      "keypaper"
    ),
    recursive = TRUE
  )

  kp <- readRDS(kp_tcac10_fn) |>
    unlist() |>
    unname()

  kp <- gsub(
    pattern = "https://doi.org/|https://www.doi.org/|http://dx.doi.org/",
    replacement = "",
    kp
  )

  ## fix wrong DOIs
  kp <- gsub(
    pattern = "https://hdl.handle.net/102.100.100/538672",
    replacement = "10.13140/RG.2.1.1974.0646",
    kp
  )
  kp <- gsub(
    pattern = "https://discovery.ucl.ac.uk/id/eprint/1437000",
    replacement = "",
    kp
  )

  kp <- kp[nzchar(kp, keepNA = FALSE)] |>
    trimws()

  openalexPro::pro_query(
    doi = kp
  ) |>
    openalexPro::pro_fetch(
      project_folder = project_folder,
      overwrite = TRUE,
      workers = workers
    )

  unlink(
    c(
      file.path(project_folder, "json"),
      file.path(project_folder, "jsonl")
    ),
    recursive = TRUE
  )

  file.rename(
    from = file.path(project_folder, "parquet"),
    to = file.path(project_folder, "keypaper")
  )
  return(file.path(project_folder, "keypaper"))
}
