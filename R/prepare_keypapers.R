prepare_keypapers <- function(
  kp_tcac10
) {
  kp_path <- file.path("output", "keyworks")

  kp <- readRDS(kp_tcac10) |>
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

  unlink(kp_path, recursive = TRUE)
  openalexPro::pro_query(
    doi = kp
  ) |>
    openalexPro::pro_fetch(
      project_folder = kp_path,
      overwrite = TRUE
    )

  return(kp_path)
}
