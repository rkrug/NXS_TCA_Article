#' convert character vector to compact search term
#'
st_compact <- function(x) {
  x |>
    paste0(collapse = " ") |>
    gsub(pattern = "\n", replacement = " ") |>
    gsub(pattern = "\\*", replacement = "") |>
    gsub(pattern = "\\s+", replacement = " ") |>
    gsub(pattern = "\\( ", replacement = "(") |>
    gsub(pattern = " )", replacement = ")")
}
