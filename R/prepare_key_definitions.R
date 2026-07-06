# Rough token estimate for embedding sizing. SPECTER2 truncates at 512
# tokens; ~4 characters per token is the usual rule of thumb for English
# text, so this is a cheap way to flag definitions whose abstract is likely
# to be truncated (an estimate, not the model tokenizer's exact count).
estimate_tokens <- function(x) {
  n <- nchar(x)
  n[is.na(x)] <- 0L
  as.integer(ceiling(n / 4))
}

# Whitespace-delimited word count.
count_words <- function(x) {
  x <- trimws(ifelse(is.na(x), "", x))
  vapply(strsplit(x, "\\s+"), function(w) sum(nzchar(w)), integer(1))
}

# SPECTER2 max sequence length — text beyond this is truncated at embed time.
SPECTER2_TOKEN_LIMIT <- 512L

prepare_key_definitions <- function(raw_csv) {
  raw <- utils::read.csv(
    raw_csv,
    colClasses = "character",
    fileEncoding = "UTF-8-BOM", # strip the BOM so the `ID` header parses cleanly
    stringsAsFactors = FALSE,
    check.names = FALSE
  ) |>
    dplyr::rename(
      id = ID,
      title = `Theory/framework/methodology`,
      abstract = `Literal definition`,
      primary_approach = `Primary approach`,
      secondary_approach = `Secondary approach`
    ) |>
    dplyr::mutate(
      dplyr::across(dplyr::everything(), trimws),
      # Combined `title [SEP] abstract` variant — the text actually sent in the
      # title_abstract embedding call. Mirrors preprocessor_title_abstract():
      # title capped at 200 chars (embeddings.title_cap_combined) + " [SEP] " +
      # abstract.
      .ta_text = paste0(
        substr(dplyr::coalesce(title, ""), 1, 200L),
        " [SEP] ",
        dplyr::coalesce(abstract, "")
      ),
      # Estimated tokens (~4 chars/token).
      title_tokens_est = estimate_tokens(title),
      abstract_tokens_est = estimate_tokens(abstract),
      title_abstract_tokens_est = estimate_tokens(.ta_text),
      # Estimated number of words to drop from the combined title_abstract
      # text so it fits within the 512-token limit; 0 when already within.
      # = words - floor(words * 512/estimated-tokens).
      .ta_words = count_words(.ta_text),
      shorten_title_abstract_by_words = as.integer(pmax(0L, .ta_words - floor(
        .ta_words *
          pmin(1, SPECTER2_TOKEN_LIMIT / pmax(title_abstract_tokens_est, 1L))
      )))
    ) |>
    dplyr::select(
      id, title, abstract,
      primary_approach, secondary_approach,
      title_tokens_est, abstract_tokens_est, title_abstract_tokens_est,
      shorten_title_abstract_by_words
    )

  message(sprintf(
    paste0(
      "[prepare_key_definitions] %d definitions | title_abstract (combined ",
      "embedding call) est. tokens: median %d, max %d | %d over %d (SPECTER2 ",
      "limit) → truncated | shorten by up to %d words"
    ),
    nrow(raw),
    as.integer(round(stats::median(raw$title_abstract_tokens_est))),
    max(raw$title_abstract_tokens_est),
    sum(raw$title_abstract_tokens_est > SPECTER2_TOKEN_LIMIT, na.rm = TRUE),
    SPECTER2_TOKEN_LIMIT,
    max(raw$shorten_title_abstract_by_words)
  ))

  out_dir <- "output/NXS_TCA_corpus/keypaper"
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  out_file <- file.path(out_dir, "key_works.parquet")
  arrow::write_parquet(raw, out_file)
  out_file
}
