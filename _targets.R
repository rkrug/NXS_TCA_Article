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
    "openalexVectorComp",
    "future",
    "furrr"
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

  # TCAC 2.0 corpus embeddings → source=corpus, one target per variant -------
  # Each owns its own (config, source, variant) leaf partition; independent
  # invalidation. embed_works() has a skip guard: existing parquet rows in the
  # leaf → return without TEI, so prior runs are registered without rebuild.

  tar_target(
    emb_tcac20_title,
    embed_works(
      corpus_path = pilot_corpus_tcac20,
      out_dir = "output/TCAC_2.0/embeddings",
      source = "corpus",
      config_name = emb_name,
      cfg = emb_cfg,
      variant_name = "title",
      preprocessor = variant_preprocessor("title", emb_cfg)$prep,
      preprocessor_args = variant_preprocessor("title", emb_cfg)$args
    ),
    format = "file"
  ),
  tar_target(
    emb_tcac20_abstract,
    embed_works(
      corpus_path = pilot_corpus_tcac20,
      out_dir = "output/TCAC_2.0/embeddings",
      source = "corpus",
      config_name = emb_name,
      cfg = emb_cfg,
      variant_name = "abstract",
      preprocessor = variant_preprocessor("abstract", emb_cfg)$prep,
      preprocessor_args = variant_preprocessor("abstract", emb_cfg)$args
    ),
    format = "file"
  ),
  tar_target(
    emb_tcac20_title_abstract,
    embed_works(
      corpus_path = pilot_corpus_tcac20,
      out_dir = "output/TCAC_2.0/embeddings",
      source = "corpus",
      config_name = emb_name,
      cfg = emb_cfg,
      variant_name = "title_abstract",
      preprocessor = variant_preprocessor("title_abstract", emb_cfg)$prep,
      preprocessor_args = variant_preprocessor("title_abstract", emb_cfg)$args
    ),
    format = "file"
  ),

  # Keypaper embeddings → source=keypaper, one target per variant ------------

  tar_target(
    emb_keypapers_title,
    embed_works(
      corpus_path = key_works,
      out_dir = "output/TCAC_2.0/embeddings",
      source = "keypaper",
      config_name = emb_name,
      cfg = emb_cfg,
      variant_name = "title",
      preprocessor = variant_preprocessor("title", emb_cfg)$prep,
      preprocessor_args = variant_preprocessor("title", emb_cfg)$args
    ),
    format = "file"
  ),
  tar_target(
    emb_keypapers_abstract,
    embed_works(
      corpus_path = key_works,
      out_dir = "output/TCAC_2.0/embeddings",
      source = "keypaper",
      config_name = emb_name,
      cfg = emb_cfg,
      variant_name = "abstract",
      preprocessor = variant_preprocessor("abstract", emb_cfg)$prep,
      preprocessor_args = variant_preprocessor("abstract", emb_cfg)$args
    ),
    format = "file"
  ),
  tar_target(
    emb_keypapers_title_abstract,
    embed_works(
      corpus_path = key_works,
      out_dir = "output/TCAC_2.0/embeddings",
      source = "keypaper",
      config_name = emb_name,
      cfg = emb_cfg,
      variant_name = "title_abstract",
      preprocessor = variant_preprocessor("title_abstract", emb_cfg)$prep,
      preprocessor_args = variant_preprocessor("title_abstract", emb_cfg)$args
    ),
    format = "file"
  ),

  # Scoring: one target per variant. dirname() of the variant target gives the
  # source-level dir; score_keypapers walks up once more to find the shared
  # config root, so this is wire-compatible with the previous shape.

  tar_target(
    scores_tcac20_title,
    score_keypapers(
      corpus_emb_dir = dirname(emb_tcac20_title),
      reference_emb_dir = dirname(emb_keypapers_title),
      variant = "title",
      out_dir = "output/TCAC_2.0/scores"
    ),
    format = "file"
  ),
  tar_target(
    scores_tcac20_abstract,
    score_keypapers(
      corpus_emb_dir = dirname(emb_tcac20_abstract),
      reference_emb_dir = dirname(emb_keypapers_abstract),
      variant = "abstract",
      out_dir = "output/TCAC_2.0/scores"
    ),
    format = "file"
  ),
  tar_target(
    scores_tcac20_title_abstract,
    score_keypapers(
      corpus_emb_dir = dirname(emb_tcac20_title_abstract),
      reference_emb_dir = dirname(emb_keypapers_title_abstract),
      variant = "title_abstract",
      out_dir = "output/TCAC_2.0/scores"
    ),
    format = "file"
  ),

  # Track config.yaml as a file dep, then expose individual bertopic configs
  # so each named run becomes its own DAG node. Downstream targets depend on
  # the subset of the config they care about, so changes to unrelated
  # sections (workers, embedding params) do not invalidate them.
  tar_target(config_file, "config.yaml", format = "file"),
  tar_target(
    bertopic_local_cfg,
    {
      b <- yaml::read_yaml(config_file)$bertopic
      cfg <- b$configs[[b$active_local]]
      if (is.null(cfg)) {
        stop("bertopic.active_local '", b$active_local,
             "' not found under bertopic.configs in config.yaml")
      }
      cfg
    }
  ),
  tar_target(
    bertopic_runpod_cfg,
    {
      y   <- yaml::read_yaml(config_file)
      b   <- y$bertopic
      cfg <- b$configs[[b$active_runpod]]
      if (is.null(cfg)) {
        stop("bertopic.active_runpod '", b$active_runpod,
             "' not found under bertopic.configs in config.yaml")
      }
      # Phase 1: embeddings live in R2. Merge r2 block into the cfg so the
      # wrapper can translate local emb paths -> s3:// URIs without a
      # second config target.
      cfg$r2 <- y$r2
      cfg
    }
  ),

  # Path A — local CPU sample-fit + transfer. Self-contained on the laptop.
  # corpus_emb_dir / reference_emb_dir resolve to the source-level dir via
  # dirname() of the primary variant target; the Python script discovers
  # variant=… partitions inside. fallback_* args are dep tokens so the
  # fallback variant targets are also DAG dependencies.
  tar_target(
    topics_tcac20_local,
    run_bertopic_local(
      corpus_emb_dir    = dirname(emb_tcac20_title_abstract),
      reference_emb_dir = dirname(emb_keypapers_title_abstract),
      out_dir           = "output/TCAC_2.0/topics",
      cfg               = bertopic_local_cfg,
      run_name          = yaml::read_yaml(config_file)$bertopic$active_local,
      fallback_corpus   = emb_tcac20_title,
      fallback_ref      = emb_keypapers_title
    ),
    format = "file"
  ),

  # Path B — RunPod GPU full-fit via cuml. SSH/rsync orchestrated by the
  # R wrapper; needs a pod up from the docker/bertopic-runpod image.
  tar_target(
    topics_tcac20_runpod,
    run_bertopic_runpod(
      corpus_emb_dir    = dirname(emb_tcac20_title_abstract),
      reference_emb_dir = dirname(emb_keypapers_title_abstract),
      out_dir           = "output/TCAC_2.0/topics",
      cfg               = bertopic_runpod_cfg,
      run_name          = yaml::read_yaml(config_file)$bertopic$active_runpod,
      fallback_corpus   = emb_tcac20_title,
      fallback_ref      = emb_keypapers_title
    ),
    format = "file"
  ),

  # Alias for the viz layer so existing viz_topics_* targets don't need
  # rewiring. Reads bertopic.active_for_viz to pick which run feeds the
  # report. Side-by-side comparison viz is future work.
  tar_target(
    topics_tcac20,
    {
      b    <- yaml::read_yaml(config_file)$bertopic
      pick <- b$active_for_viz
      if (pick == b$active_local) {
        topics_tcac20_local
      } else if (pick == b$active_runpod) {
        topics_tcac20_runpod
      } else {
        stop(
          "bertopic.active_for_viz ('", pick,
          "') must equal bertopic.active_local ('", b$active_local,
          "') or bertopic.active_runpod ('", b$active_runpod, "')."
        )
      }
    },
    format = "file"
  ),

  # --- Visualisation layer ---------------------------------------------------
  # Data + figure objects (qs2-serialised) for the report. Each figure target
  # also writes a static artifact to output/figures/ for quick viewing.
  tar_target(
    viz_embeddings,
    {
      # Force deps on every variant target so any change invalidates viz.
      .deps <- list(
        emb_tcac20_title,
        emb_tcac20_abstract,
        emb_tcac20_title_abstract,
        emb_keypapers_title,
        emb_keypapers_abstract,
        emb_keypapers_title_abstract
      )
      # All six leaves share the same config dir two levels up.
      read_embeddings(dirname(dirname(emb_tcac20_title)))
    },
    format = qs2_format()
  ),
  tar_target(
    viz_scores_long,
    read_scores_long(scores_tcac20_title_abstract),
    format = qs2_format()
  ),
  tar_target(
    viz_metadata,
    viz_metadata_table(viz_embeddings),
    format = qs2_format()
  ),
  tar_target(
    viz_score_summary_tbl,
    viz_score_summary(viz_scores_long),
    format = qs2_format()
  ),
  tar_target(
    viz_score_quantiles_tbl,
    viz_score_quantiles(viz_scores_long),
    format = qs2_format()
  ),
  tar_target(
    fig_score_dist,
    viz_score_dist_fig(viz_scores_long),
    format = qs2_format()
  ),
  tar_target(
    viz_top_bottom,
    viz_top_bottom_tables(viz_embeddings, scores_tcac20_title_abstract),
    format = qs2_format()
  ),
  tar_target(
    viz_agree_data,
    viz_variant_agree_data(viz_scores_long),
    format = qs2_format()
  ),
  tar_target(
    fig_agree,
    viz_variant_agree_fig(viz_agree_data),
    format = qs2_format()
  ),
  tar_target(
    fig_threshold,
    viz_threshold_fig(viz_scores_long),
    format = qs2_format()
  ),
  tar_target(
    viz_umap_coords_df,
    viz_umap_coords(viz_embeddings, variant = "title_abstract"),
    format = qs2_format()
  ),
  tar_target(
    viz_umap_join,
    viz_umap_data(
      umap_coords = viz_umap_coords_df,
      embeddings = viz_embeddings,
      scores_long = viz_scores_long,
      corpus_tcac20 = corpus_tcac20,
      key_works = key_works
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_umap_bestkp,
    viz_umap_best_kp(viz_umap_join, scores_tcac20_title_abstract),
    format = qs2_format()
  ),
  tar_target(
    viz_umap_kp,
    viz_umap_keypaper(viz_umap_join, viz_umap_bestkp),
    format = qs2_format()
  ),
  tar_target(
    viz_umap_workmax,
    viz_umap_work_max(viz_scores_long),
    format = qs2_format()
  ),
  tar_target(
    viz_umap_contour_grid,
    viz_umap_contour(viz_umap_coords_df, viz_umap_join$emb_corpus),
    format = qs2_format()
  ),
  tar_target(
    fig_umap,
    viz_umap_fig(
      emb_corpus = viz_umap_join$emb_corpus,
      emb_keypaper = viz_umap_kp,
      contour = viz_umap_contour_grid,
      best_kp_df = viz_umap_bestkp,
      work_max = viz_umap_workmax
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_topics_tbl_data,
    viz_topics_table_data(topics_tcac20, viz_embeddings),
    format = qs2_format()
  ),
  tar_target(
    fig_topics_tbl,
    viz_topics_table(viz_topics_tbl_data),
    format = qs2_format()
  ),
  tar_target(
    fig_topics,
    viz_topics_fig(
      topics_tcac20 = topics_tcac20,
      emb_corpus = viz_umap_join$emb_corpus,
      emb_keypaper = viz_umap_kp
    ),
    format = qs2_format()
  ),

  # Render the vectorisation report. Re-builds whenever any score parquet,
  # the embeddings dataset, or the .qmd itself changes.
  tarchetypes::tar_quarto(
    report_vectorisation,
    path = "TCAC 2.0 Vectorisation.qmd",
    quiet = TRUE
  ),

  NULL
)
