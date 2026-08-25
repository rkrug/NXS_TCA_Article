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

# Config is read here and specific values are hoisted into narrow globals.
# IMPORTANT: reference these narrow globals (not `cfg$...`) inside target
# commands. A target whose command mentions `cfg` takes a dependency on the
# WHOLE config object, so any edit to config.yaml (even an unrelated one like
# the embedding host) invalidates it. The zotero/ids/corpus download chain is
# expensive, so its inputs are pinned to dedicated scalars below.
cfg <- yaml::read_yaml("input/config.yaml")
workers <- cfg$workers
emb_name <- cfg$embeddings$active
emb_cfg_full <- cfg$embeddings$configs[[emb_name]]
if (is.null(emb_cfg_full)) {
  stop(
    "embeddings.active '",
    emb_name,
    "' not found under embeddings.configs in config.yaml"
  )
}
# Connection + throughput fields are dropped from the *tracked* embedding
# config, so changing the TEI host (every new pod) or tuning batch/concurrency
# does NOT invalidate already-computed embeddings. embed_works() reads these
# fresh from config.yaml at runtime. Only value-affecting fields (model,
# sep_token, title_cap_combined, pilot_n) remain tracked in emb_cfg.
emb_volatile <- c(
  "host",
  "port",
  "scheme",
  "auth_token_keyring",
  "batch_size",
  "max_batch_size",
  "concurrency",
  "max_batch_tokens",
  "max_concurrent"
)
emb_cfg <- emb_cfg_full[setdiff(names(emb_cfg_full), emb_volatile)]
# Zotero download inputs — pinned so unrelated config.yaml edits don't
# re-trigger the (slow) group downloads.
zotero_tca_id <- cfg$zotero$assessments$tca$id
zotero_nxs_id <- cfg$zotero$assessments$nxs$id
zotero_keyring <- cfg$zotero$api_key_keyring
# Citation extraction: which method feeds the production `corpus` (regex | llm),
# and the OpenRouter LLM config for the alternative extractor. Hoisted so the
# LLM connection details don't drag the whole cfg into target hashes.
citations_active <- cfg$citations$active %||% "regex"
citations_llm_cfg <- cfg$citations$llm
# emb_name (above) is baked into the rendered report filenames. tar_quarto's
# output_file is evaluated eagerly at pipeline-construction time, so it must be
# a plain script variable (not a target).
# Sys.setenv(OVC_API_TOKEN = keyring::key_get("API_openai"))  # only when provider == openai

tar_option_set(
  packages = c(
    "dplyr",
    "arrow",
    "openalexPro",
    "openalexSnapshot",
    "openalexVectorComp",
    "future",
    "furrr",
    "httr2",
    "jsonlite"
  ),
  format = "rds"
)

list(
  # Input file tracking -------------------------------------------------------

  tar_target(
    kd_raw_fn,
    "input/TCA and Nexus Definitions-1.xlsx",
    format = "file"
  ),
  # Key papers ----------------------------------------------------------------

  tar_target(
    key_works,
    prepare_key_definitions(kd_raw_fn),
    format = "file"
  ),

  # Zotero assessment libraries ------------------------------------------------
  # Two curated IPBES Zotero groups define the corpus membership: the TCA
  # assessment group (public) and the NXS assessment literature group
  # (private — needs a Zotero API key with group access).

  tar_target(
    zotero_tca,
    download_zotero_assessment(
      assessment_id = zotero_tca_id,
      assessment_label = "tca",
      api_key = NULL,
      output_root = "output/NXS_TCA_corpus/zotero"
    ),
    format = "file"
  ),
  tar_target(
    zotero_nxs,
    download_zotero_assessment(
      assessment_id = zotero_nxs_id,
      assessment_label = "nxs",
      api_key = keyring::key_get(zotero_keyring),
      output_root = "output/NXS_TCA_corpus/zotero"
    ),
    format = "file"
  ),

  # Match Zotero items to OpenAlex ids via DOI ---------------------------------

  tar_target(
    ids_tca,
    get_ids_from_dois(
      zotero_tca,
      project_folder = "output/NXS_TCA_corpus/_scratch/tca",
      workers = workers,
      dest_dir = "output/NXS_TCA_corpus/ids/assessment=tca"
    ),
    format = "file"
  ),
  tar_target(
    ids_nxs,
    get_ids_from_dois(
      zotero_nxs,
      project_folder = "output/NXS_TCA_corpus/_scratch/nxs",
      workers = workers,
      dest_dir = "output/NXS_TCA_corpus/ids/assessment=nxs"
    ),
    format = "file"
  ),

  # Extract full records from the local OpenAlex snapshot, hive-partitioned
  # by assessment (assessment=tca / assessment=nxs) under one corpus root ----

  tar_target(
    corpus_chapter_tca,
    get_corpus_from_snapshot(
      ids_db = ids_tca,
      snapshot_dir = "input/snapshot",
      project_folder = "output/NXS_TCA_corpus/_scratch/tca",
      workers = workers,
      zotero_path = zotero_tca,
      dest_dir = "output/NXS_TCA_corpus/corpus_chapter/assessment=tca"
    ),
    format = "file"
  ),
  tar_target(
    corpus_chapter_nxs,
    get_corpus_from_snapshot(
      ids_db = ids_nxs,
      snapshot_dir = "input/snapshot",
      project_folder = "output/NXS_TCA_corpus/_scratch/nxs",
      workers = workers,
      zotero_path = zotero_nxs,
      dest_dir = "output/NXS_TCA_corpus/corpus_chapter/assessment=nxs"
    ),
    format = "file"
  ),

  # Combined corpus_chapter dataset — the full assessment reference libraries
  # (both assessment branches must exist before the shared hive root is
  # considered ready). This is the former `corpus`; renamed to `corpus_chapter`
  # now that the new `corpus` target holds the works CITED in the definitions.
  # Downstream chapter<->keypaper analysis reads this root (assessment=tca /
  # assessment=nxs partitions).

  tar_target(
    corpus_chapter,
    {
      force(corpus_chapter_tca)
      force(corpus_chapter_nxs)
      dirname(corpus_chapter_tca)
    },
    format = "file"
  ),

  # Citations named inside the definitions -----------------------------------
  # Extract every inline (author, year) token from the keypaper definitions and
  # resolve each to a work in the MATCHING assessment's reference library (two
  # passes: strict then loose; unresolved kept for verification). These feed the
  # Stage-2 citation-overlap linkage. See R/extract_definition_citations.R /
  # resolve_citations.R.

  # Two extraction methods, both built every run: `regex` (deterministic) and
  # `llm` (OpenRouter). Both feed the same resolve_citations() and are compared
  # in the Citation Method Comparison report.
  tar_target(
    key_citations,
    extract_definition_citations(key_works),
    format = "file"
  ),
  tar_target(
    key_citations_llm,
    extract_definition_citations_llm(key_works, citations_llm_cfg),
    format = "file"
  ),
  tar_target(
    citations_resolved,
    resolve_citations(
      citations_extracted_dir = key_citations,
      zotero_root = dirname(zotero_tca),
      ids_root = dirname(ids_tca),
      corpus_chapter_dir = corpus_chapter,
      out_dir = "output/NXS_TCA_corpus/citations_resolved/method=regex"
    ),
    format = "file"
  ),
  tar_target(
    citations_resolved_llm,
    resolve_citations(
      citations_extracted_dir = key_citations_llm,
      zotero_root = dirname(zotero_tca),
      ids_root = dirname(ids_tca),
      corpus_chapter_dir = corpus_chapter,
      out_dir = "output/NXS_TCA_corpus/citations_resolved/method=llm"
    ),
    format = "file"
  ),
  # The resolved citations that feed the production corpus + linkage, selected
  # by citations.active in config.yaml (regex | llm). Resolved HERE, at
  # pipeline-construction time, rather than inside the target's own command --
  # `targets` detects a target's dependencies by static analysis of its
  # command, so branching inside tar_target() would make BOTH
  # key_citations_llm/citations_resolved_llm and their regex counterparts
  # unconditional dependencies (forcing live OpenRouter calls any time
  # anything downstream, like link_stage2, needs to rebuild -- even with
  # citations.active: regex). Branching here instead means only the ACTIVE
  # method's upstream is a real dependency of citations_resolved_active; the
  # inactive method's targets still get built separately, but only when
  # something that actually needs them (report_citation_comparison) requires
  # it.
  if (identical(citations_active, "llm")) {
    tar_target(citations_resolved_active, citations_resolved_llm, format = "file")
  } else {
    tar_target(citations_resolved_active, citations_resolved, format = "file")
  },
  tar_target(
    emb_keypapers_title_abstract,
    embed_works(
      corpus_path = key_works,
      out_dir = "output/NXS_TCA_corpus/embeddings",
      source = "keypaper",
      config_name = emb_name,
      cfg = emb_cfg,
      variant_name = "title_abstract",
      preprocessor = variant_preprocessor("title_abstract", emb_cfg)$prep,
      preprocessor_args = variant_preprocessor("title_abstract", emb_cfg)$args
    ),
    format = "file"
  ),
  tar_target(
    viz_keypaper_self_sim_data,
    build_viz_keypaper_self_sim_data(emb_keypapers_title_abstract, key_works),
    format = qs2_format()
  ),
  tar_target(
    viz_keypaper_self_sim_fig,
    build_viz_keypaper_self_sim_fig(viz_keypaper_self_sim_data),
    format = qs2_format()
  ),

  # ---- Keyset linkage (keypaper <-> keypaper) -----------------------------
  # How the concept definitions link across key-sets, especially TCA Approaches
  # -> TCA Action. Stage 1: definition-embedding similarity. Stage 2: overlap of
  # the cited literature (no embeddings). (Stage 3 — cited-literature embedding
  # similarity — was removed; it needed the full-corpus embeddings.) See
  # R/build_linkage.R.
  tar_target(
    link_stage1,
    build_link_stage1_data(emb_keypapers_title_abstract, key_works),
    format = qs2_format()
  ),
  tar_target(
    link_stage2,
    build_link_stage2_data(citations_resolved_active, key_works),
    format = qs2_format()
  ),
  # Static ggplot Sankeys, TCA Approaches -> TCA Action, the two kept signal
  # stages (definition embedding / citation overlap). The key_works set was
  # trimmed to just the Approaches and Actions keysets, so the other pair this
  # was originally built for (TCA Action -> Nexus Response Option) no longer
  # applies. Stage 1 shows top 5 targets per node with links coloured by
  # similarity; stage 2 (citation-overlap Jaccard, not an embedding signal)
  # stays top 3, uncoloured.
  tar_target(
    viz_sankey_appr_act_stage1_ggplot_fig,
    build_sankey_fig_ggplot(
      link_stage1,
      key_works,
      value_col = "sim",
      source_keyset = "TCA_Approaches_3_2",
      target_keyset = "TCA_Actions_Ch5",
      top_n = 5,
      color_by_value = TRUE,
      name = "sankey_appr_act_stage1_definition_embedding_ggplot"
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_sankey_appr_act_stage2_ggplot_fig,
    build_sankey_fig_ggplot(
      link_stage2,
      key_works,
      value_col = "jaccard",
      source_keyset = "TCA_Approaches_3_2",
      target_keyset = "TCA_Actions_Ch5",
      name = "sankey_appr_act_stage2_citation_overlap_ggplot"
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_keyset_matrix_stage1_fig,
    build_keyset_matrix_fig(
      link_stage1,
      value_col = "sim",
      name = "keyset_matrix_stage1",
      key_works = key_works
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_keyset_matrix_stage2_fig,
    build_keyset_matrix_fig(
      link_stage2,
      value_col = "jaccard",
      name = "keyset_matrix_stage2",
      key_works = key_works
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_pair_heatmap_appr_act_stage1_fig,
    build_pair_heatmap_fig(
      link_stage1,
      key_works,
      value_col = "sim",
      source_keyset = "TCA_Approaches_3_2",
      target_keyset = "TCA_Actions_Ch5",
      name = "pair_heatmap_appr_act_stage1"
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_pair_heatmap_appr_act_stage2_fig,
    build_pair_heatmap_fig(
      link_stage2,
      key_works,
      value_col = "jaccard",
      source_keyset = "TCA_Approaches_3_2",
      target_keyset = "TCA_Actions_Ch5",
      name = "pair_heatmap_appr_act_stage2"
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_pair_heatmap_appr_act_combined_fig,
    build_pair_heatmap_combined_fig(
      link_stage1,
      link_stage2,
      key_works,
      source_keyset = "TCA_Approaches_3_2",
      target_keyset = "TCA_Actions_Ch5",
      name = "pair_heatmap_appr_act_combined"
    ),
    format = qs2_format()
  ),

  # ---- Citation method comparison (regex vs LLM) --------------------------
  tar_target(
    viz_citation_summary_tbl,
    citation_comparison_summary(citations_resolved, citations_resolved_llm),
    format = qs2_format()
  ),
  tar_target(
    viz_citation_overlap_data,
    citation_comparison_overlap(citations_resolved, citations_resolved_llm),
    format = qs2_format()
  ),
  tar_target(
    viz_citation_overlap_fig,
    build_citation_overlap_fig(viz_citation_overlap_data),
    format = qs2_format()
  ),
  tar_target(
    viz_citation_review,
    citation_comparison_review(citations_resolved, citations_resolved_llm),
    format = qs2_format()
  ),
  # Render the Chapter Analysis Report (chapter <-> keypaper similarity).
  tarchetypes::tar_quarto(
    render_report_analysis,
    path = "NXS TCS Article Chapter Analysis Report.qmd",
    output_file = paste0(
      "NXS TCS Article Chapter Analysis Report - ",
      emb_name,
      ".html"
    ),
    quiet = TRUE
  ),

  # Render the Citation Method Comparison Report (regex vs LLM extraction).
  tarchetypes::tar_quarto(
    render_report_citation_comparison,
    path = "NXS TCS Article Citation Method Comparison Report.qmd",
    output_file = paste0(
      "NXS TCS Article Citation Method Comparison Report - ",
      emb_name,
      ".html"
    ),
    quiet = TRUE
  ),
  tar_target(
    report_analysis,
    {
      src <- render_report_analysis[grepl("\\.html$", render_report_analysis)]
      if (length(src) != 1) {
        stop(
          "Expected exactly one rendered .html among ",
          "render_report_analysis's tracked files, got: ",
          paste(render_report_analysis, collapse = ", ")
        )
      }
      dest_dir <- "output/reports"
      dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
      dest <- file.path(dest_dir, basename(src))
      if (!file.copy(src, dest, overwrite = TRUE)) {
        stop("Could not copy ", src, " to ", dest)
      }
      dest
    },
    format = "file"
  ),
  tar_target(
    report_citation_comparison,
    {
      src <- render_report_citation_comparison[grepl(
        "\\.html$",
        render_report_citation_comparison
      )]
      if (length(src) != 1) {
        stop(
          "Expected exactly one rendered .html among ",
          "render_report_citation_comparison's tracked files, got: ",
          paste(render_report_citation_comparison, collapse = ", ")
        )
      }
      dest_dir <- "output/reports"
      dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
      dest <- file.path(dest_dir, basename(src))
      if (!file.copy(src, dest, overwrite = TRUE)) {
        stop("Could not copy ", src, " to ", dest)
      }
      dest
    },
    format = "file"
  ),

  # Render the two standalone TD (technical design) docs alongside the
  # reports. Plain .md, no executable chunks -- rendered for the read-only
  # HTML copy; the .md remains the source of truth read on GitHub.
  tarchetypes::tar_quarto(
    render_td_vectorisation,
    path = "TD_Vectorisation.md",
    output_file = "TD_Vectorisation.html",
    quiet = TRUE
  ),
  tarchetypes::tar_quarto(
    render_td_runpod_setup,
    path = "TD_RunPodSetup.md",
    output_file = "TD_RunPodSetup.html",
    quiet = TRUE
  ),
  tar_target(
    td_vectorisation,
    {
      src <- render_td_vectorisation[grepl("\\.html$", render_td_vectorisation)]
      if (length(src) != 1) {
        stop(
          "Expected exactly one rendered .html among ",
          "render_td_vectorisation's tracked files, got: ",
          paste(render_td_vectorisation, collapse = ", ")
        )
      }
      dest_dir <- "output/reports"
      dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
      dest <- file.path(dest_dir, basename(src))
      if (!file.copy(src, dest, overwrite = TRUE)) {
        stop("Could not copy ", src, " to ", dest)
      }
      fix_td_cross_links(dest)
      dest
    },
    format = "file"
  ),
  tar_target(
    td_runpod_setup,
    {
      src <- render_td_runpod_setup[grepl("\\.html$", render_td_runpod_setup)]
      if (length(src) != 1) {
        stop(
          "Expected exactly one rendered .html among ",
          "render_td_runpod_setup's tracked files, got: ",
          paste(render_td_runpod_setup, collapse = ", ")
        )
      }
      dest_dir <- "output/reports"
      dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
      dest <- file.path(dest_dir, basename(src))
      if (!file.copy(src, dest, overwrite = TRUE)) {
        stop("Could not copy ", src, " to ", dest)
      }
      fix_td_cross_links(dest)
      dest
    },
    format = "file"
  ),

  # Landing page linking to the two reports and two TD docs above. Depends
  # on the copy targets (not the render_* ones) so it always points at the
  # files that actually landed in output/reports/, and only builds once
  # they have.
  tar_target(
    report_index,
    build_report_index(
      report_analysis,
      report_citation_comparison,
      td_vectorisation,
      td_runpod_setup,
      out_dir = "output/reports"
    ),
    format = "file"
  ),

  NULL
)
