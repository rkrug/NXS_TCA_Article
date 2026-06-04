clean_text <- function(x, strip_abstract_prefix = FALSE) {
  if (is.null(x) || length(x) != 1L || is.na(x) || !nzchar(x)) {
    return(NA_character_)
  }
  x <- tryCatch(
    xml2::xml_text(xml2::read_html(paste0("<x>", x, "</x>"))),
    error = function(e) x
  )
  if (strip_abstract_prefix) {
    x <- sub(
      "^\\s*(abstract|summary)\\s*[:—\\-.]?\\s+",
      "",
      x,
      ignore.case = TRUE,
      perl = TRUE
    )
  }
  x <- gsub("\\$([^$]+)\\$", "\\1", x, perl = TRUE)
  x <- gsub("\\\\[a-zA-Z]+\\{([^}]*)\\}", "\\1", x, perl = TRUE)
  x <- gsub("\\\\[a-zA-Z]+", " ", x, perl = TRUE)
  x <- stringr::str_squish(x)
  if (nzchar(x)) x else NA_character_
}

clean_title    <- function(x) clean_text(x, strip_abstract_prefix = FALSE)
clean_abstract <- function(x) clean_text(x, strip_abstract_prefix = TRUE)
