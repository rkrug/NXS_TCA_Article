library(targets)

Sys.setenv(openalexPro.apikey = keyring::key_get("API_openalex"))

rl <- openalexPro::pro_rate_limit_status()
if (Sys.getenv("openalexPro.apikey", unset = "") == "") {
  stop("OpenAlex API Key not set!")
}
if (rl$rate_limit$daily_remaining_usd < 0.1) {
  warning("Daily limit below 0.1US$ - fail likely!")
}


lapply(list.files("R", pattern = "\\.R$", full.names = TRUE), source)

# Operational config — not tracked, changes do not invalidate targets
cfg <- yaml::read_yaml("config.yaml")
workers <- cfg$workers
emb_name <- cfg$active_embedding
emb_cfg <- cfg$embeddings[[emb_name]]
if (is.null(emb_cfg)) {
  stop(
    "active_embedding '",
    emb_name,
    "' not found under embeddings: in config.yaml"
  )
}
# Sys.setenv(OVC_API_TOKEN = keyring::key_get("API_openai"))  # only when provider == openai

tar_option_set(
  packages = c(
    "dplyr",
    "arrow",
    "openalexPro",
    "openalexSnapshot",
    "openalexVectorComp"
  ),
  format = "rds"
)

list(
  # Input file tracking -------------------------------------------------------

  tar_target(st_tfc_fn, "input/search terms/tfc_TCAC_2.0.txt", format = "file"),
  tar_target(
    st_nature_fn,
    "input/search terms/nature_TCAC_2.0.txt",
    format = "file"
  ),
  tar_target(
    kp_tcac10_fn,
    "input/key papers/key_papers_TCAC_1.0.rds",
    format = "file"
  ),
  tar_target(types_filter_fn, "input/openalex_types.csv", format = "file"),
  tar_target(ids_tcac10_fn, "input/TCAC_1.0/ids.parquet", format = "file"),

  # Search terms --------------------------------------------------------------

  tar_target(tfc_st, paste(readLines(st_tfc_fn), collapse = "\n")),
  tar_target(nature_st, paste(readLines(st_nature_fn), collapse = "\n")),
  tar_target(tca_st, paste0("(\n", nature_st, "\n)\nAND\n(\n", tfc_st, "\n)")),

  # Types filter --------------------------------------------------------------

  tar_target(types_filter, {
    read.csv(types_filter_fn) |>
      dplyr::filter(Included) |>
      dplyr::pull(Type)
  }),

  # Key papers ----------------------------------------------------------------

  tar_target(
    key_works,
    get_key_works(
      kp_tcac10_fn,
      project_folder = "output/TCAC_2.0/",
      workers = workers
    ),
    format = "file"
  ),

  # Count of matching works ---------------------------------------------------

  tar_target(
    count_st,
    get_count(tfc_st, nature_st, types_filter, workers = workers),
    format = "file"
  ),

  # TCAC 2.0: Get IDs ---------------------------------------------------------

  tar_target(
    ids_tcac20,
    get_tcac20_ids(
      st = tca_st,
      tf = types_filter,
      project_folder = "output/TCAC_2.0/",
      workers = workers
    ),
    format = "file"
  ),

  # TCAC 2.0: Extract corpus from snapshot ------------------------------------

  tar_target(
    corpus_tcac20,
    get_corpus_from_snapshot(
      ids_db = ids_tcac20,
      snapshot_dir = "input/snapshot",
      project_folder = "output/TCAC_2.0/",
      workers = workers
    ),
    format = "file"
  ),

  # TCAC 1.0: Extract corpus from snapshot ------------------------------------

  # tar_target(
  #   corpus_tcac10_db,
  #   get_corpus_from_snapshot(
  #     ids_db = ids_tcac10_fn,
  #     snapshot_dir = "input/snapshot",
  #     project_folder = "output/TCAC_1.0/",
  #     workers = workers
  #   ),
  #   format = "file"
  # ),

  # Shared pilot subset (first emb_cfg$pilot_n rows of corpus extract) -------

  tar_target(
    pilot_corpus_tcac20,
    make_pilot_subset(
      corpus_path = corpus_tcac20,
      out_dir = file.path(
        "output/TCAC_2.0",
        paste0("pilot_n", emb_cfg$pilot_n)
      ),
      n = emb_cfg$pilot_n
    ),
    format = "file"
  ),

  # TCAC 2.0 corpus embeddings → source=corpus partition ---------------------
  # All three variants (title / abstract / title_abstract) embedded in one
  # call and written into the unified database partitioned by (source, variant).

  tar_target(
    emb_tcac20,
    embed_works(
      corpus_path = pilot_corpus_tcac20,
      out_dir = "output/TCAC_2.0/embeddings",
      source = "corpus",
      config_name = emb_name,
      cfg = emb_cfg
    ),
    format = "file"
  ),

  # Keypaper embeddings → source=keypaper partition in same config ----------

  tar_target(
    emb_keypapers,
    embed_works(
      corpus_path = key_works,
      out_dir = "output/TCAC_2.0/embeddings",
      source = "keypaper",
      config_name = emb_name,
      cfg = emb_cfg
    ),
    format = "file"
  ),

  # Scoring: one target per variant, reading the unified database ------------

  # tar_target(
  #   scores_tcac20_title,
  #   score_keypapers(
  #     corpus_emb_dir    = emb_tcac20,
  #     reference_emb_dir = emb_keypapers,
  #     variant           = "title",
  #     out_dir           = "output/TCAC_2.0/scores"
  #   ),
  #   format = "file"
  # ),
  # tar_target(
  #   scores_tcac20_abstract,
  #   score_keypapers(
  #     corpus_emb_dir    = emb_tcac20,
  #     reference_emb_dir = emb_keypapers,
  #     variant           = "abstract",
  #     out_dir           = "output/TCAC_2.0/scores"
  #   ),
  #   format = "file"
  # ),
  # tar_target(
  #   scores_tcac20_title_abstract,
  #   score_keypapers(
  #     corpus_emb_dir    = emb_tcac20,
  #     reference_emb_dir = emb_keypapers,
  #     variant           = "title_abstract",
  #     out_dir           = "output/TCAC_2.0/scores"
  #   ),
  #   format = "file"
  # )

  # --- DISABLED: TCAC 1.0 embedding & scoring -------------------------------
  # Re-enable when TCAC 1.0 processing is needed. Pattern is identical:
  # add a `pilot_corpus_tcac10` (or skip pilot), then `emb_tcac10` writing
  # into output/TCAC_1.0/embeddings with source = "corpus", then 3 score
  # targets pointing at that database + the keypapers embedded there too.

  NULL
)
