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
emb_cfg <- cfg$embedding
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

  # Key-paper embeddings (reference set) --------------------------------------
  # Co-located under output/TCAC_2.0/embeddings/ so distance_reference_cosine()
  # can read corpus + reference from the same embeddings dataset.

  # tar_target(
  #   emb_keyworks,
  #   embed_works(
  #     corpus_path = file.path(key_works),
  #     cfg = emb_cfg,
  #     project_folder = "output/TCAC_2.0",
  #     label_override = "keyworks"
  #   ),
  #   format = "file"
  # ),

  # TCAC 2.0 embeddings — pilot via n=1000, full via n=NULL -------------------

  # tar_target(
  #   emb_tcac20,
  #   embed_works(
  #     corpus_path = corpus_tcac20,
  #     cfg = emb_cfg,
  #     n = 1000
  #   ),
  #   format = "file"
  # ),

  # TCAC 2.0 scoring against key-paper reference set --------------------------

  # tar_target(
  #   scores_tcac20,
  #   score_keypapers(
  #     corpus_emb_dir = emb_tcac20,
  #     reference_emb_dir = emb_keyworks
  #   ),
  #   format = "file"
  # )

  # --- DISABLED: TCAC 1.0 embedding & scoring -------------------------------
  # Re-enable when TCAC 1.0 processing is needed. Uses the same pattern.
  #
  # , tar_target(
  #     emb_tcac10,
  #     embed_works(
  #       corpus_path = corpus_tcac10_db,
  #       cfg         = emb_cfg,
  #       n           = NULL
  #     ),
  #     format = "file"
  #   )
  # , tar_target(
  #     scores_tcac10,
  #     score_keypapers(
  #       corpus_emb_dir    = emb_tcac10,
  #       reference_emb_dir = emb_keyworks    # also needs co-location in TCAC_1.0
  #     ),
  #     format = "file"
  #   )
  NULL
)
