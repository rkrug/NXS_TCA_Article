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
cfg <- yaml::read_yaml("input/config.yaml")
workers <- cfg$workers
emb_name <- cfg$embeddings$active
emb_cfg <- cfg$embeddings$configs[[emb_name]]
if (is.null(emb_cfg)) {
  stop(
    "embeddings.active '",
    emb_name,
    "' not found under embeddings.configs in config.yaml"
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
    kp_raw_fn,
    "input/key papers/key_papers.csv",
    format = "file"
  ),
  tar_target(types_filter_fn, "input/openalex_types.csv", format = "file"),

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
    prepare_key_works(kp_raw_fn),
    format = "file"
  ),

  # Count of matching works ---------------------------------------------------

  tar_target(
    count_st,
    get_count(tfc_st, nature_st, tca_st, types_filter, workers = workers),
    format = "file"
  ),

  # Yearly counts on OpenAlex for the universe + each search bucket --------
  tar_target(
    yearly_counts,
    get_yearly_counts(tfc_st, nature_st, tca_st),
    format = "file"
  ),

  # TCAC 2.0 corpus — STATIC INPUT (fork) -------------------------------------
  # Frozen clone of the upstream TCAC 2.0 corpus, moved into input/ and never
  # re-extracted here. The upstream `TCAC 2.0` repo owns corpus generation;
  # this fork only consumes it. (Upstream: ids_tcac20 -> get_corpus_from_snapshot.)

  tar_target(
    corpus_tcac20,
    "input/corpus",
    format = "file"
  ),

  # TCAC 2.0 corpus embeddings — STATIC INPUT (fork) -------------------------
  # Frozen clones of the upstream SPECTER2 corpus embeddings, moved into
  # input/embeddings and never recomputed here. One file target per variant,
  # laid out as config=<emb_name>/source=corpus/variant=<v> so downstream
  # dirname() resolution is identical to the upstream producer shape.
  # (Upstream: embed_works(source="corpus") into output/TCAC_2.0/embeddings.)

  tar_target(
    emb_tcac20_title,
    file.path(
      "input/embeddings",
      paste0("config=", emb_name),
      "source=corpus",
      "variant=title"
    ),
    format = "file"
  ),
  tar_target(
    emb_tcac20_abstract,
    file.path(
      "input/embeddings",
      paste0("config=", emb_name),
      "source=corpus",
      "variant=abstract"
    ),
    format = "file"
  ),
  tar_target(
    emb_tcac20_title_abstract,
    file.path(
      "input/embeddings",
      paste0("config=", emb_name),
      "source=corpus",
      "variant=title_abstract"
    ),
    format = "file"
  ),

  # Keypaper embeddings → source=keypaper, one target per variant ------------

  tar_target(
    emb_keypapers_title,
    embed_works(
      corpus_path = key_works,
      out_dir = "input/embeddings",
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
      out_dir = "input/embeddings",
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
      out_dir = "input/embeddings",
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
  tar_target(config_file, "input/config.yaml", format = "file"),
  tar_target(
    viz_cfg,
    {
      v <- yaml::read_yaml(config_file)$viz
      if (is.null(v)) {
        stop("viz: block missing from config.yaml")
      }
      v
    }
  ),
  if (!is.null(cfg$bertopic$active_local)) {
    tar_target(
      bertopic_local_cfg,
      {
        b <- yaml::read_yaml(config_file)$bertopic
        cfg <- b$configs[[b$active_local]]
        if (is.null(cfg)) {
          stop(
            "bertopic.active_local '",
            b$active_local,
            "' not found under bertopic.configs in config.yaml"
          )
        }
        cfg
      }
    )
  },
  tar_target(
    bertopic_runpod_cfg,
    {
      y <- yaml::read_yaml(config_file)
      b <- y$bertopic
      cfg <- b$configs[[b$active_runpod]]
      if (is.null(cfg)) {
        stop(
          "bertopic.active_runpod '",
          b$active_runpod,
          "' not found under bertopic.configs in config.yaml"
        )
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
  if (!is.null(cfg$bertopic$active_local)) {
    tar_target(
      topics_tcac20_local,
      run_bertopic_local(
        corpus_emb_dir = dirname(emb_tcac20_title_abstract),
        reference_emb_dir = dirname(emb_keypapers_title_abstract),
        out_dir = "output/TCAC_2.0/topics",
        cfg = bertopic_local_cfg,
        run_name = yaml::read_yaml(config_file)$bertopic$active_local,
        fallback_corpus = emb_tcac20_title,
        fallback_ref = emb_keypapers_title
      ),
      format = "file"
    )
  },

  # The RunPod pod reads embeddings straight from R2 (no rsync upload) — see
  # run_bertopic_runpod()'s "Translate local emb dirs -> s3:// URIs" step.
  # Corpus embeddings are frozen/static and already mirrored to R2 once;
  # keypaper embeddings change whenever the keypaper set changes and must be
  # re-pushed, or the pod silently scores against a stale set. This target
  # depends on all three emb_keypapers_* so it re-syncs whenever any of them
  # change, and topics_tcac20_runpod takes it as a dep token below so the
  # sync always happens before dispatch.
  tar_target(
    emb_keypapers_r2_synced,
    sync_keypaper_embeddings_to_r2(
      emb_keypapers_title,
      emb_keypapers_abstract,
      emb_keypapers_title_abstract,
      r2_cfg = bertopic_runpod_cfg$r2
    ),
    format = "file"
  ),

  # Path B — RunPod GPU full-fit via cuml. SSH/rsync orchestrated by the
  # R wrapper; needs a pod up from the docker/bertopic-runpod image.
  tar_target(
    topics_tcac20_runpod,
    run_bertopic_runpod(
      corpus_emb_dir = dirname(emb_tcac20_title_abstract),
      reference_emb_dir = dirname(emb_keypapers_title_abstract),
      out_dir = "output/TCAC_2.0/topics",
      cfg = bertopic_runpod_cfg,
      run_name = yaml::read_yaml(config_file)$bertopic$active_runpod,
      fallback_corpus = emb_tcac20_title,
      fallback_ref = emb_keypapers_title,
      keypaper_r2_synced = emb_keypapers_r2_synced
    ),
    format = "file"
  ),

  # NOTE: the previous topics_tcac20 alias target tried to switch
  # between Path A (topics_tcac20_local) and Path B (topics_tcac20_runpod)
  # via bertopic.active_for_viz. targets' static dependency analysis
  # treated BOTH referenced targets as deps regardless of which active
  # config was selected, so switching active_for_viz to default_runpod
  # still dispatched Path A. With Path B now the production path, the
  # viz layer references topics_tcac20_runpod directly. Re-introduce
  # an alias mechanism only if comparison-across-runs viz is needed
  # later (see TODO_NamedKeypaperSets.md for the keypaper-set
  # comparison pattern).

  # --- Visualisation layer ---------------------------------------------------
  # Data + figure objects (qs2-serialised) for the report. Each figure target
  # also writes a static artifact to output/figures/ for quick viewing.
  # NOTE: viz_embeddings (loaded all six leaves as one tibble) was removed
  # because it OOM'd at full corpus scale. Each consumer now reads only
  # the columns it needs via arrow pushdown. See TODO_Visualisations.md §1.
  tar_target(
    viz_scores_long,
    read_scores_long(
      scores_tcac20_title,
      scores_tcac20_abstract,
      scores_tcac20_title_abstract
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_metadata,
    viz_metadata_table(emb_tcac20_title),
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
    viz_score_dist_data,
    build_viz_score_dist_data(viz_scores_long),
    format = qs2_format()
  ),
  tar_target(
    viz_score_dist_fig,
    build_viz_score_dist_fig(viz_score_dist_data),
    format = qs2_format()
  ),
  tar_target(
    viz_score_ecdf_data,
    build_viz_score_ecdf_data(viz_scores_long),
    format = qs2_format()
  ),
  tar_target(
    viz_score_ecdf_fig,
    build_viz_score_ecdf_fig(viz_score_ecdf_data),
    format = qs2_format()
  ),

  # ---- Embedding-report extras ---------------------------------------------
  tar_target(
    viz_top_matches_per_kp,
    build_viz_top_matches_per_kp_data(
      scores_tcac20_title_abstract = scores_tcac20_title_abstract,
      key_works = key_works,
      corpus_tcac20 = corpus_tcac20
    ),
    format = qs2_format()
  ),
  tar_target(
    tbl_top_matches_per_kp,
    build_tbl_top_matches_per_kp_widget(viz_top_matches_per_kp),
    format = qs2_format()
  ),
  tar_target(
    viz_text_length_data,
    build_viz_text_length_data(
      corpus_tcac20 = corpus_tcac20,
      title_cap_combined = emb_cfg$title_cap_combined %||% 200L,
      sep_token = emb_cfg$sep_token %||% "[SEP]"
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_text_length_fig,
    build_viz_text_length_fig(viz_text_length_data),
    format = qs2_format()
  ),
  tar_target(
    viz_keypaper_self_sim_data,
    build_viz_keypaper_self_sim_data(emb_keypapers_title_abstract),
    format = qs2_format()
  ),
  tar_target(
    viz_keypaper_self_sim_fig,
    build_viz_keypaper_self_sim_fig(viz_keypaper_self_sim_data),
    format = qs2_format()
  ),
  tar_target(
    viz_score_year_data,
    build_viz_score_year_data(viz_scores_long, corpus_tcac20),
    format = qs2_format()
  ),
  tar_target(
    viz_score_year_fig,
    build_viz_score_year_fig(viz_score_year_data),
    format = qs2_format()
  ),
  tar_target(
    viz_type_counts,
    build_viz_type_counts(corpus_tcac20, min_pct = 0.5),
    format = qs2_format()
  ),
  tar_target(
    viz_type_count_fig,
    build_viz_type_count_fig(viz_type_counts),
    format = qs2_format()
  ),
  tar_target(
    viz_type_score_stats,
    build_viz_type_score_stats(viz_scores_long, corpus_tcac20, min_pct = 0.5),
    format = qs2_format()
  ),
  tar_target(
    viz_type_score_heatmap_fig,
    build_viz_type_score_heatmap_fig(viz_type_score_stats),
    format = qs2_format()
  ),
  tar_target(
    viz_type_score_box_fig,
    build_viz_type_score_box_fig(viz_type_score_stats),
    format = qs2_format()
  ),
  tar_target(
    viz_language_counts,
    build_viz_language_counts(corpus_tcac20, min_pct = 0.5),
    format = qs2_format()
  ),
  tar_target(
    viz_language_fig,
    build_viz_language_fig(viz_language_counts),
    format = qs2_format()
  ),
  tar_target(
    viz_truncation_stats,
    build_viz_truncation_stats(
      corpus_tcac20,
      title_cap_combined = emb_cfg$title_cap_combined %||% 200L,
      sep_token = emb_cfg$sep_token %||% "[SEP]"
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_keypaper_score_dist_data,
    build_viz_keypaper_score_dist_data(
      scores_tcac20_title_abstract,
      key_works
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_keypaper_score_dist_fig,
    build_viz_keypaper_score_dist_fig(viz_keypaper_score_dist_data),
    format = qs2_format()
  ),
  tar_target(
    viz_emb_norm_data,
    build_viz_emb_norm_data(
      emb_tcac20_title = emb_tcac20_title,
      emb_tcac20_abstract = emb_tcac20_abstract,
      emb_tcac20_title_abstract = emb_tcac20_title_abstract,
      emb_keypapers_title = emb_keypapers_title,
      emb_keypapers_abstract = emb_keypapers_abstract,
      emb_keypapers_title_abstract = emb_keypapers_title_abstract
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_emb_norm_fig,
    build_viz_emb_norm_fig(viz_emb_norm_data),
    format = qs2_format()
  ),
  tar_target(
    viz_citation_score_data,
    build_viz_citation_score_data(viz_scores_long, corpus_tcac20),
    format = qs2_format()
  ),
  tar_target(
    viz_citation_score_fig,
    build_viz_citation_score_fig(viz_citation_score_data),
    format = qs2_format()
  ),
  tar_target(
    viz_top_bottom,
    viz_top_bottom_tables(viz_scores_long, corpus_tcac20),
    format = qs2_format()
  ),
  tar_target(
    viz_agree_data,
    viz_variant_agree_data(viz_scores_long),
    format = qs2_format()
  ),
  tar_target(
    viz_agree_fig,
    build_viz_agree_fig(viz_agree_data),
    format = qs2_format()
  ),
  tar_target(
    viz_threshold_fig,
    build_viz_threshold_fig(viz_scores_long),
    format = qs2_format()
  ),
  tar_target(
    viz_umap_coords_df,
    viz_umap_coords(
      emb_tcac20_title_abstract,
      emb_keypapers_title_abstract,
      viz_cfg = viz_cfg
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_umap_join,
    viz_umap_data(
      umap_coords = viz_umap_coords_df,
      emb_tcac20_title = emb_tcac20_title,
      emb_keypapers_title = emb_keypapers_title,
      scores_tcac20_title_abstract = scores_tcac20_title_abstract,
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
    viz_umap_work_max(viz_scores_long, viz_umap_join),
    format = qs2_format()
  ),
  tar_target(
    viz_umap_contour_grid,
    viz_umap_contour(viz_umap_coords_df, viz_umap_join$emb_corpus),
    format = qs2_format()
  ),
  tar_target(
    viz_umap_fig,
    build_viz_umap_fig(
      emb_corpus = viz_umap_join$emb_corpus,
      emb_keypaper = viz_umap_kp,
      contour = viz_umap_contour_grid,
      best_kp_df = viz_umap_bestkp,
      work_max = viz_umap_workmax
    ),
    format = qs2_format()
  ),
  tar_target(
    tbl_topics_data,
    build_tbl_topics_data(topics_tcac20_runpod, emb_tcac20_title),
    format = qs2_format()
  ),
  tar_target(
    tbl_topics,
    tbl_topics_widget(tbl_topics_data),
    format = qs2_format()
  ),
  tar_target(
    viz_topics_fig,
    build_viz_topics_fig(
      topics_tcac20 = topics_tcac20_runpod,
      emb_corpus = viz_umap_join$emb_corpus,
      emb_keypaper = viz_umap_kp
    ),
    format = qs2_format()
  ),

  # Render the embeddings report. Re-builds whenever any score parquet,
  # the embeddings dataset, or the .qmd itself changes.
  tarchetypes::tar_quarto(
    report_embeddings,
    path = "Reimaging TFC Embedding Report.qmd",
    quiet = TRUE
  ),

  # Render the Topic Modelling Report. Re-builds whenever any of its tar_read()
  # targets (search terms, count_st, yearly_counts, corpus_tcac20,
  # key_works, assess_*_in_tca) or the .qmd itself changes.
  tarchetypes::tar_quarto(
    report_topic_modelling,
    path = "Reimaging TFC Topic Modelling Report.qmd",
    quiet = TRUE
  ),

  NULL
)
