# Build the keypaper set from the four worksheets of
# `input/TCA and Nexus Definitions-1.xlsx`, each sheet mapped onto one unified
# schema and written to a hive partition `keyset=<sheet-name>`. The keypapers
# are the TCA/Nexus concept definitions themselves; downstream they are
# embedded (source=keypaper) and their inline citations are extracted to build
# the cited-literature `corpus` (see extract_definition_citations() /
# resolve_citations()).
#
# Unified schema (one row per definition):
#   id                  globally-unique key (Approaches get an `APPR:` prefix as
#                       collision insurance; Nexus uses its `Code`)
#   source_id           the sheet's own `ID` column
#   keyset              sheet name (also the hive partition)
#   title               short label of the concept
#   abstract            the definition text WITH inline citations stripped
#                       (this is what gets embedded)
#   abstract_raw        the original definition text (citations intact) — the
#                       source for citation extraction
#   category            sheet-specific grouping (Table code / Strategy /
#                       Category), NA where the sheet has none
#   code                Nexus response-option code, NA elsewhere
#   primary_approach    TCA_Annex only, NA elsewhere
#   secondary_approach  TCA_Annex only, NA elsewhere
#   plus advisory token-size estimates (see estimate_tokens()).

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

# Read one worksheet of an .xlsx into a data.frame via duckdb's `excel`
# extension (readxl/openxlsx are not installed in this project).
.read_xlsx_sheet <- function(path, sheet) {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "INSTALL excel; LOAD excel;")
  DBI::dbGetQuery(con, sprintf(
    "SELECT * FROM read_xlsx(%s, sheet = %s, all_varchar = true)",
    DBI::dbQuoteString(con, path),
    DBI::dbQuoteString(con, sheet)
  ))
}

# Per-sheet mapping onto the unified schema. Each returns the standard columns;
# `col()` pulls a source column if present, else NA (keeps the schema uniform
# across sheets that lack a column).
.map_sheet <- function(df, keyset) {
  col <- function(name) {
    if (name %in% names(df)) trimws(df[[name]]) else rep(NA_character_, nrow(df))
  }
  base <- switch(
    keyset,
    "TCA_Annex_3_3" = data.frame(
      id = col("ID"), source_id = col("ID"),
      title = col("Theory/framework/methodology"),
      abstract_raw = col("Literal definition"),
      category = col("Table code"), code = NA_character_,
      primary_approach = col("Primary approach"),
      secondary_approach = col("Secondary approach"),
      stringsAsFactors = FALSE
    ),
    "TCA_Approaches_3_2" = data.frame(
      id = paste0("APPR:", col("ID")), source_id = col("ID"),
      title = col("Approach"),
      abstract_raw = col("Text definition"),
      category = NA_character_, code = NA_character_,
      primary_approach = NA_character_, secondary_approach = NA_character_,
      stringsAsFactors = FALSE
    ),
    "TCA_Actions_Ch5" = data.frame(
      id = col("ID"), source_id = col("ID"),
      title = col("Action"),
      abstract_raw = col("Literal definition"),
      category = col("Strategy"), code = NA_character_,
      primary_approach = NA_character_, secondary_approach = NA_character_,
      stringsAsFactors = FALSE
    ),
    "Nexus_Response_Options" = data.frame(
      id = col("Code"), source_id = col("ID"),
      title = col("Response option"),
      abstract_raw = col("Textual definition"),
      category = col("Category"), code = col("Code"),
      primary_approach = NA_character_, secondary_approach = NA_character_,
      stringsAsFactors = FALSE
    ),
    stop("Unknown keyset: ", keyset)
  )
  base$keyset <- keyset
  # drop rows with no usable definition
  base[!is.na(base$id) & nzchar(base$id) &
         !is.na(base$abstract_raw) & nzchar(base$abstract_raw), , drop = FALSE]
}

KEYPAPER_SHEETS <- c(
  "TCA_Annex_3_3", "TCA_Approaches_3_2",
  "TCA_Actions_Ch5", "Nexus_Response_Options"
)

prepare_key_definitions <- function(raw_xlsx) {
  parts <- lapply(KEYPAPER_SHEETS, function(sheet) {
    .map_sheet(.read_xlsx_sheet(raw_xlsx, sheet), sheet)
  })
  raw <- do.call(rbind, parts)

  if (anyDuplicated(raw$id)) {
    dups <- unique(raw$id[duplicated(raw$id)])
    stop("Non-unique keypaper id(s) across sheets: ",
         paste(dups, collapse = ", "))
  }

  raw <- raw |>
    dplyr::mutate(
      # Embedded text = definition with inline citations stripped.
      abstract = vapply(abstract_raw, strip_citations, character(1),
                        USE.NAMES = FALSE),
      # Combined `title [SEP] abstract` variant — mirrors
      # preprocessor_title_abstract(): title capped at 200 chars + abstract.
      .ta_text = paste0(
        substr(dplyr::coalesce(title, ""), 1, 200L),
        " [SEP] ",
        dplyr::coalesce(abstract, "")
      ),
      title_tokens_est = estimate_tokens(title),
      abstract_tokens_est = estimate_tokens(abstract),
      title_abstract_tokens_est = estimate_tokens(.ta_text),
      .ta_words = count_words(.ta_text),
      shorten_title_abstract_by_words = as.integer(pmax(0L, .ta_words - floor(
        .ta_words *
          pmin(1, SPECTER2_TOKEN_LIMIT / pmax(title_abstract_tokens_est, 1L))
      )))
    ) |>
    dplyr::select(
      id, source_id, keyset, title, abstract, abstract_raw,
      category, code, primary_approach, secondary_approach,
      title_tokens_est, abstract_tokens_est, title_abstract_tokens_est,
      shorten_title_abstract_by_words
    )

  message(sprintf(
    paste0(
      "[prepare_key_definitions] %d definitions across %d keysets | ",
      "title_abstract est. tokens: median %d, max %d | %d over %d (SPECTER2 ",
      "limit) → truncated | shorten by up to %d words"
    ),
    nrow(raw), dplyr::n_distinct(raw$keyset),
    as.integer(round(stats::median(raw$title_abstract_tokens_est))),
    max(raw$title_abstract_tokens_est),
    sum(raw$title_abstract_tokens_est > SPECTER2_TOKEN_LIMIT, na.rm = TRUE),
    SPECTER2_TOKEN_LIMIT,
    max(raw$shorten_title_abstract_by_words)
  ))

  out_dir <- "output/NXS_TCA_corpus/keypaper"
  # Rebuild the hive root cleanly so stale keyset partitions never linger.
  if (dir.exists(out_dir)) unlink(out_dir, recursive = TRUE)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  arrow::write_dataset(
    raw, path = out_dir, partitioning = "keyset",
    format = "parquet", basename_template = "part-{i}.parquet"
  )
  out_dir
}
