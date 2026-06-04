preprocessor_title <- function(df, ...) {
  title_clean    <- vapply(df$title,    clean_title,    character(1))
  abstract_clean <- vapply(df$abstract, clean_abstract, character(1))
  keep <- !is.na(title_clean)
  out <- data.frame(
    id             = df$id[keep],
    title_clean    = title_clean[keep],
    abstract_clean = abstract_clean[keep],
    text           = title_clean[keep],
    stringsAsFactors = FALSE
  )
  out$text_hash <- vapply(
    out$text,
    function(t) digest::digest(t, algo = "xxhash64"),
    character(1)
  )
  out
}

preprocessor_abstract <- function(df, ...) {
  title_clean    <- vapply(df$title,    clean_title,    character(1))
  abstract_clean <- vapply(df$abstract, clean_abstract, character(1))
  keep <- !is.na(abstract_clean)
  out <- data.frame(
    id             = df$id[keep],
    title_clean    = title_clean[keep],
    abstract_clean = abstract_clean[keep],
    text           = abstract_clean[keep],
    stringsAsFactors = FALSE
  )
  out$text_hash <- vapply(
    out$text,
    function(t) digest::digest(t, algo = "xxhash64"),
    character(1)
  )
  out
}

preprocessor_title_abstract <- function(df, sep = "[SEP]", title_cap = 200, ...) {
  title_clean    <- vapply(df$title,    clean_title,    character(1))
  abstract_clean <- vapply(df$abstract, clean_abstract, character(1))
  keep <- !is.na(title_clean) & !is.na(abstract_clean)
  t_kept <- substr(title_clean[keep], 1, title_cap)
  a_kept <- abstract_clean[keep]
  out <- data.frame(
    id             = df$id[keep],
    title_clean    = title_clean[keep],
    abstract_clean = a_kept,
    text           = paste0(t_kept, " ", sep, " ", a_kept),
    stringsAsFactors = FALSE
  )
  out$text_hash <- vapply(
    out$text,
    function(t) digest::digest(t, algo = "xxhash64"),
    character(1)
  )
  out
}
