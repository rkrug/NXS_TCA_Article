# LLM-based inline-citation extraction — an alternative to the deterministic
# regex parser (R/citation_regex.R / extract_definition_citations.R). Uses an
# OpenRouter chat model to read each concept definition and return its in-text
# citations. Emits the SAME schema as the regex extractor
#   keyset, keypaper_id, source_id, raw_citation, author_key, year, cite_seq
# so it feeds resolve_citations() unchanged and is directly comparable in the
# Citation Method Comparison report.
#
# Config: input/config.yaml `citations.llm` (api_key_keyring, base_url, model,
# temperature, max_retries). The API key is read fresh from the system keyring.
# Output: output/NXS_TCA_corpus/citations/extracted_llm/part-0.parquet.

# System/user instruction — deterministic, JSON-only, no reference lists.
.LLM_CITE_PROMPT <- paste(
  "You extract in-text academic citations from a passage of text.",
  "Return ONLY a JSON object of the form",
  '{"citations": [{"raw": "...", "author": "...", "year": 1234}, ...]}',
  "with one element per DISTINCT in-text citation, covering both",
  "parenthetical citations like (Smith, 2020) or (A & B, 2011; C et al., 2019)",
  "and narrative ones like Smith (2020) or Jones et al. (2019).",
  "`raw` = the citation text as it appears; `author` = the FIRST author's",
  "surname only (drop initials, 'et al.', '&'); `year` = the 4-digit year as",
  "an integer. Split multi-citation parentheses into separate elements.",
  "Do NOT include reference-list entries, footnote numbers, figure/table",
  "callouts, or non-citation parentheticals. If there are none, return",
  '{"citations": []}. Output raw JSON only — no markdown, no commentary.'
)

# One OpenRouter chat completion; returns the assistant message text.
.openrouter_chat <- function(text, llm_cfg, api_key) {
  body <- list(
    model = llm_cfg$model,
    temperature = llm_cfg$temperature %||% 0,
    messages = list(
      list(role = "system", content = .LLM_CITE_PROMPT),
      list(role = "user", content = paste0("TEXT:\n", text))
    )
  )
  resp <- httr2::request(llm_cfg$base_url) |>
    httr2::req_headers(
      Authorization = paste("Bearer", api_key),
      "Content-Type" = "application/json",
      # OpenRouter attribution headers (optional but recommended)
      "HTTP-Referer" = "https://github.com/rkrug/NXS_TCA_Article",
      "X-Title" = "NXS TCA Article"
    ) |>
    httr2::req_body_json(body) |>
    # Fail fast on a hung socket instead of stalling the whole target.
    httr2::req_timeout(llm_cfg$timeout %||% 90L) |>
    httr2::req_retry(max_tries = llm_cfg$max_retries %||% 3L) |>
    httr2::req_perform()
  parsed <- httr2::resp_body_json(resp)
  parsed$choices[[1]]$message$content
}

# Parse the model's reply (tolerant of ```json fences / stray prose) into a
# data.frame(raw, author, year).
.parse_llm_citations <- function(txt) {
  empty <- data.frame(raw = character(0), author = character(0),
                      year = integer(0), stringsAsFactors = FALSE)
  if (is.null(txt) || is.na(txt) || !nzchar(txt)) {
    return(empty)
  }
  # strip markdown fences, then parse. Try the whole reply first; if that
  # fails, isolate the outermost JSON object with a DOTALL regex ((?s) so `.`
  # matches newlines — the model often returns pretty-printed, multi-line JSON).
  s <- trimws(gsub("```json|```", "", txt))
  obj <- tryCatch(jsonlite::fromJSON(s, simplifyDataFrame = TRUE),
                  error = function(e) NULL)
  if (is.null(obj)) {
    m <- regmatches(s, regexpr("(?s)\\{.*\\}", s, perl = TRUE))
    if (!length(m)) {
      return(empty)
    }
    obj <- tryCatch(jsonlite::fromJSON(m, simplifyDataFrame = TRUE),
                    error = function(e) NULL)
  }
  cites <- obj$citations
  if (is.null(cites) || length(cites) == 0L) {
    return(empty)
  }
  cites <- as.data.frame(cites, stringsAsFactors = FALSE)
  # tolerate missing columns
  for (col in c("raw", "author", "year")) {
    if (is.null(cites[[col]])) cites[[col]] <- NA
  }
  data.frame(
    raw = as.character(cites$raw),
    author = as.character(cites$author),
    year = suppressWarnings(as.integer(cites$year)),
    stringsAsFactors = FALSE
  )
}

extract_definition_citations_llm <- function(key_works_dir,
                                              llm_cfg,
                                              out_dir = file.path(
                                                "output/NXS_TCA_corpus",
                                                "citations_extracted",
                                                "method=llm"
                                              )) {
  empty_out <- data.frame(
    keyset = character(0), keypaper_id = character(0),
    source_id = character(0), raw_citation = character(0),
    author_key = character(0), year = integer(0), cite_seq = integer(0),
    stringsAsFactors = FALSE
  )

  api_key <- keyring::key_get(llm_cfg$api_key_keyring)

  kp <- arrow::open_dataset(key_works_dir) |>
    dplyr::select(keyset, id, source_id, abstract_raw) |>
    dplyr::collect()
  n <- nrow(kp)

  # Write one shard parquet per definition into a SCRATCH dir (outside the
  # dataset tree, so it never pollutes open_dataset() and an interrupted run
  # leaves nothing inside citations_extracted/). Progress is observable live via
  # `ls <shard_dir> | wc -l`. Consolidated into the keyset-partitioned dataset
  # at the end; out_dir is only (re)written then, so a crash keeps the previous
  # good output intact.
  shard_dir <- file.path("output/NXS_TCA_corpus", "_scratch",
                         "citations_llm_shards")
  if (dir.exists(shard_dir)) unlink(shard_dir, recursive = TRUE)
  dir.create(shard_dir, recursive = TRUE, showWarnings = FALSE)

  workers <- as.integer(llm_cfg$workers %||% 1L)
  message(sprintf(
    paste0("[llm] extracting citations from %d definitions via %s ",
           "(%d worker%s; watch %s) ..."),
    n, llm_cfg$model, workers, if (workers == 1L) "" else "s", shard_dir
  ))

  # Extract one definition → write its shard; returns #citations, or a value
  # tagged with an `err` attribute on failure (counted afterwards).
  extract_one <- function(i) {
    txt <- kp$abstract_raw[i]
    if (is.na(txt) || !nzchar(txt)) {
      return(0L)
    }
    reply <- tryCatch(
      .openrouter_chat(txt, llm_cfg, api_key),
      error = function(e) structure(NA_character_, err = conditionMessage(e))
    )
    if (length(reply) != 1L || is.na(reply)) {
      return(structure(-1L, err = attr(reply, "err") %||% "empty reply"))
    }
    cites <- .parse_llm_citations(reply)
    if (nrow(cites)) {
      key <- normalize_author_key(sub("\\s+.*$", "", trimws(cites$author)))
      keep <- nzchar(key) & !is.na(cites$year)
      cites <- cites[keep, , drop = FALSE]
      key <- key[keep]
    }
    if (nrow(cites)) {
      df <- data.frame(
        keyset = kp$keyset[i], keypaper_id = kp$id[i],
        source_id = kp$source_id[i], raw_citation = cites$raw,
        author_key = key, year = cites$year,
        cite_seq = seq_len(nrow(cites)), stringsAsFactors = FALSE
      )
      arrow::write_parquet(df, file.path(shard_dir,
                                         sprintf("def-%04d.parquet", i)))
    }
    nrow(cites)
  }

  if (workers > 1L) {
    # Parallel: calls are network-bound, so N sessions ~= N× throughput. Each
    # writes its own shard (distinct filename → no contention); progress is the
    # live shard count under shard_dir, plus furrr's progress bar.
    oplan <- future::plan(future::multisession, workers = workers)
    on.exit(future::plan(oplan), add = TRUE)
    res <- furrr::future_map(
      seq_len(n), extract_one,
      .options = furrr::furrr_options(
        seed = TRUE,
        packages = c("httr2", "jsonlite", "arrow"),
        globals = c(".openrouter_chat", ".parse_llm_citations",
                    "normalize_author_key", ".LLM_CITE_PROMPT",
                    "kp", "llm_cfg", "api_key", "shard_dir")
      ),
      .progress = TRUE
    )
  } else {
    t0 <- Sys.time()
    res <- lapply(seq_len(n), function(i) {
      r <- extract_one(i)
      tag <- if (identical(as.integer(r), -1L)) {
        paste0("ERROR: ", attr(r, "err"))
      } else {
        sprintf("%d citations", r)
      }
      message(sprintf("[llm] %d/%d %s — %s (%.0fs elapsed)", i, n, kp$id[i],
                      tag, as.numeric(difftime(Sys.time(), t0, units = "secs"))))
      r
    })
  }
  n_fail <- sum(vapply(res, function(x) identical(as.integer(x), -1L),
                       logical(1)))

  shards <- list.files(shard_dir, pattern = "\\.parquet$", full.names = TRUE)
  out <- if (length(shards)) {
    arrow::open_dataset(shard_dir) |> dplyr::collect()
  } else {
    empty_out
  }
  # Consolidate the scratch shards into the clean keyset-partitioned dataset,
  # then remove the scratch dir.
  write_citations_dataset(out, out_dir)
  unlink(shard_dir, recursive = TRUE)

  message(sprintf(
    paste0("[extract_definition_citations_llm] %s | %d citation tokens from ",
           "%d definitions (%d with ≥1 citation) | %d failed"),
    llm_cfg$model, nrow(out), n,
    dplyr::n_distinct(out$keypaper_id), n_fail
  ))
  out_dir
}
