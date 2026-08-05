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
# Config names baked into the rendered report filenames. tar_quarto's
# output_file is evaluated eagerly at pipeline-construction time, so these must
# be plain script variables (not targets). emb_name (above) is the active
# embedding config; bertopic_viz_name is the active_for_viz BERTopic run.
bertopic_viz_name <- cfg$bertopic$active_for_viz
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

  # Mermaid pipeline diagrams. File targets so editing a diagram re-renders
  # downstream. `mmd_figs` renders every .mmd to SVG + PNG (mermaid-cli, so
  # elk layout + themes work) under output/figures/mmd/; the index report
  # embeds the SVGs.
  tar_target(mmd_pipeline, "input/mmd/pipeline.mmd", format = "file"),
  tar_target(mmd_sequence, "input/mmd/sequence.mmd", format = "file"),
  tar_target(
    mmd_figs,
    render_mmd(c(mmd_pipeline, mmd_sequence), out_dir = "output/figures/mmd"),
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
  # Extract every inline (author, year) token from the keypaper definitions,
  # resolve each to a work in the MATCHING assessment's reference library (two
  # passes: strict then loose; unresolved kept for verification), then build the
  # new `corpus` = the distinct cited works (a subset of corpus_chapter, same
  # schema). See R/extract_definition_citations.R / resolve_citations.R /
  # build_cited_corpus.R.

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
  # by citations.active in config.yaml (regex | llm). Both upstreams are built
  # regardless; this just picks which one flows downstream.
  tar_target(
    citations_resolved_active,
    if (identical(citations_active, "llm")) {
      citations_resolved_llm
    } else {
      citations_resolved
    },
    format = "file"
  ),
  tar_target(
    corpus,
    build_cited_corpus(
      resolved_dir = citations_resolved_active,
      corpus_chapter_dir = corpus_chapter,
      out_dir = "output/NXS_TCA_corpus/corpus"
    ),
    format = "file"
  ),

  # Per-assessment pilot subsets (first emb_cfg$pilot_n rows; n = NULL → the
  # whole assessment corpus). Split per assessment so the tca and nxs
  # embedding flows are fully independent.

  tar_target(
    pilot_corpus_tca,
    make_pilot_subset(
      corpus_path = corpus_chapter_tca,
      out_dir = file.path(
        "output/NXS_TCA_corpus",
        paste0("pilot_tca_n", emb_cfg$pilot_n)
      ),
      n = emb_cfg$pilot_n
    ),
    format = "file"
  ),
  tar_target(
    pilot_corpus_nxs,
    make_pilot_subset(
      corpus_path = corpus_chapter_nxs,
      out_dir = file.path(
        "output/NXS_TCA_corpus",
        paste0("pilot_nxs_n", emb_cfg$pilot_n)
      ),
      n = emb_cfg$pilot_n
    ),
    format = "file"
  ),

  # Corpus embeddings → source=corpus, split per assessment × variant -------
  # Each (assessment, variant) is its own embed_works leaf
  # (…/variant=<v>/assessment=<a>/) with an independent skip-guard marker, so
  # re-embedding one assessment (e.g. when NXS changes) never rebuilds the
  # other's embeddings. The chapter-partitioned corpus embeds a work once per
  # chapter it belongs to (embeddings are id-keyed → identical vectors under
  # each chapter); accepted duplication.
  #
  # The emb_corpus_<variant> targets below combine the two assessment leaves
  # by returning the parent variant= dir — downstream consumers
  # (score_keypapers, viz, BERTopic) open that dir and arrow reads both
  # assessment leaves, so they need no change.

  tar_target(
    emb_corpus_tca_title,
    embed_works(
      corpus_path = pilot_corpus_tca,
      out_dir = "output/NXS_TCA_corpus/embeddings",
      source = "corpus_chapter",
      config_name = emb_name,
      cfg = emb_cfg,
      variant_name = "title",
      preprocessor = variant_preprocessor("title", emb_cfg)$prep,
      preprocessor_args = variant_preprocessor("title", emb_cfg)$args,
      assessment = "tca"
    ),
    format = "file"
  ),
  tar_target(
    emb_corpus_tca_abstract,
    embed_works(
      corpus_path = pilot_corpus_tca,
      out_dir = "output/NXS_TCA_corpus/embeddings",
      source = "corpus_chapter",
      config_name = emb_name,
      cfg = emb_cfg,
      variant_name = "abstract",
      preprocessor = variant_preprocessor("abstract", emb_cfg)$prep,
      preprocessor_args = variant_preprocessor("abstract", emb_cfg)$args,
      assessment = "tca"
    ),
    format = "file"
  ),
  tar_target(
    emb_corpus_tca_title_abstract,
    embed_works(
      corpus_path = pilot_corpus_tca,
      out_dir = "output/NXS_TCA_corpus/embeddings",
      source = "corpus_chapter",
      config_name = emb_name,
      cfg = emb_cfg,
      variant_name = "title_abstract",
      preprocessor = variant_preprocessor("title_abstract", emb_cfg)$prep,
      preprocessor_args = variant_preprocessor("title_abstract", emb_cfg)$args,
      assessment = "tca"
    ),
    format = "file"
  ),
  tar_target(
    emb_corpus_nxs_title,
    embed_works(
      corpus_path = pilot_corpus_nxs,
      out_dir = "output/NXS_TCA_corpus/embeddings",
      source = "corpus_chapter",
      config_name = emb_name,
      cfg = emb_cfg,
      variant_name = "title",
      preprocessor = variant_preprocessor("title", emb_cfg)$prep,
      preprocessor_args = variant_preprocessor("title", emb_cfg)$args,
      assessment = "nxs"
    ),
    format = "file"
  ),
  tar_target(
    emb_corpus_nxs_abstract,
    embed_works(
      corpus_path = pilot_corpus_nxs,
      out_dir = "output/NXS_TCA_corpus/embeddings",
      source = "corpus_chapter",
      config_name = emb_name,
      cfg = emb_cfg,
      variant_name = "abstract",
      preprocessor = variant_preprocessor("abstract", emb_cfg)$prep,
      preprocessor_args = variant_preprocessor("abstract", emb_cfg)$args,
      assessment = "nxs"
    ),
    format = "file"
  ),
  tar_target(
    emb_corpus_nxs_title_abstract,
    embed_works(
      corpus_path = pilot_corpus_nxs,
      out_dir = "output/NXS_TCA_corpus/embeddings",
      source = "corpus_chapter",
      config_name = emb_name,
      cfg = emb_cfg,
      variant_name = "title_abstract",
      preprocessor = variant_preprocessor("title_abstract", emb_cfg)$prep,
      preprocessor_args = variant_preprocessor("title_abstract", emb_cfg)$args,
      assessment = "nxs"
    ),
    format = "file"
  ),

  # Combined corpus-embedding handles: return the parent variant= dir once
  # both assessment leaves exist. Downstream targets depend on these (not the
  # per-assessment leaves) and read both assessments via one open_dataset().

  tar_target(
    emb_corpus_title,
    {
      force(emb_corpus_tca_title)
      force(emb_corpus_nxs_title)
      dirname(emb_corpus_tca_title)
    },
    format = "file"
  ),
  tar_target(
    emb_corpus_abstract,
    {
      force(emb_corpus_tca_abstract)
      force(emb_corpus_nxs_abstract)
      dirname(emb_corpus_tca_abstract)
    },
    format = "file"
  ),
  tar_target(
    emb_corpus_title_abstract,
    {
      force(emb_corpus_tca_title_abstract)
      force(emb_corpus_nxs_title_abstract)
      dirname(emb_corpus_tca_title_abstract)
    },
    format = "file"
  ),

  # Cited-corpus embeddings → source=corpus. The cited corpus is a subset of
  # corpus_chapter sharing the same SPECTER2 config, so its embeddings are
  # DERIVED by filtering the corpus_chapter embeddings to the cited-work ids
  # (no TEI re-embedding). One target per variant, wire-compatible with the
  # emb_corpus_* combiner handles (returns the variant= dir).
  tar_target(
    emb_cited_title,
    derive_source_embeddings(
      chapter_variant_dir = emb_corpus_title,
      cited_corpus_dir = corpus,
      config_name = emb_name,
      variant = "title"
    ),
    format = "file"
  ),
  tar_target(
    emb_cited_abstract,
    derive_source_embeddings(
      chapter_variant_dir = emb_corpus_abstract,
      cited_corpus_dir = corpus,
      config_name = emb_name,
      variant = "abstract"
    ),
    format = "file"
  ),
  tar_target(
    emb_cited_title_abstract,
    derive_source_embeddings(
      chapter_variant_dir = emb_corpus_title_abstract,
      cited_corpus_dir = corpus,
      config_name = emb_name,
      variant = "title_abstract"
    ),
    format = "file"
  ),

  # Keypaper embeddings → source=keypaper, one target per variant ------------
  # Shares the config= root with the corpus embeddings above — score_keypapers()
  # requires corpus and reference embeddings to live under the same config dir.

  tar_target(
    emb_keypapers_title,
    embed_works(
      corpus_path = key_works,
      out_dir = "output/NXS_TCA_corpus/embeddings",
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
      out_dir = "output/NXS_TCA_corpus/embeddings",
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

  # Scoring: one target per variant. dirname() of the variant target gives the
  # source-level dir; score_keypapers walks up once more to find the shared
  # config root, so this is wire-compatible with the previous shape.

  tar_target(
    scores_title,
    score_keypapers(
      corpus_emb_dir = dirname(emb_corpus_title),
      reference_emb_dir = dirname(emb_keypapers_title),
      variant = "title",
      out_dir = "output/NXS_TCA_corpus/scores"
    ),
    format = "file"
  ),
  tar_target(
    scores_abstract,
    score_keypapers(
      corpus_emb_dir = dirname(emb_corpus_abstract),
      reference_emb_dir = dirname(emb_keypapers_abstract),
      variant = "abstract",
      out_dir = "output/NXS_TCA_corpus/scores"
    ),
    format = "file"
  ),
  tar_target(
    scores_title_abstract,
    score_keypapers(
      corpus_emb_dir = dirname(emb_corpus_title_abstract),
      reference_emb_dir = dirname(emb_keypapers_title_abstract),
      variant = "title_abstract",
      out_dir = "output/NXS_TCA_corpus/scores"
    ),
    format = "file"
  ),

  # Combined, hive-partitioned scores (config/assessment/chapter) — one score
  # per corpus work from its title_abstract embedding, supplemented by the
  # title embedding where the work has no abstract (so is absent from the
  # title_abstract variant). Mirrors the corpus embedding hive layout. Added
  # alongside the flat per-variant scores above (which feed the existing viz
  # layer); these partitioned datasets are for export / per-chapter analysis.
  #
  # Two references for the title-only fallback works:
  #   scores_combined         — like-for-like: fallback works scored vs the
  #                             keypaper *title* reference.
  #   scores_combined_ta_ref  — fallback works scored vs the keypaper
  #                             *title_abstract* reference (always ta ref).
  # Abstract-having works are title_abstract vs title_abstract in both.
  tar_target(
    scores_combined,
    score_keypapers_combined(
      corpus_ta_dir = emb_corpus_title_abstract,
      corpus_title_dir = emb_corpus_title,
      ref_ta_dir = emb_keypapers_title_abstract,
      ref_title_dir = emb_keypapers_title,
      out_dir = "output/NXS_TCA_corpus/scores_combined",
      fallback_ref = "title"
    ),
    format = "file"
  ),
  tar_target(
    scores_combined_ta_ref,
    score_keypapers_combined(
      corpus_ta_dir = emb_corpus_title_abstract,
      corpus_title_dir = emb_corpus_title,
      ref_ta_dir = emb_keypapers_title_abstract,
      ref_title_dir = emb_keypapers_title,
      out_dir = "output/NXS_TCA_corpus/scores_combined_ta_ref",
      fallback_ref = "title_abstract"
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

  # === Topic modelling: DISABLED for now (no topic modelling yet) ============
  # The whole BERTopic compute + R2-sync region is wrapped in `if (FALSE)` so
  # none of these targets enter the pipeline (they would need a live RunPod
  # pod). Builder functions in R/ are kept intact. Re-enable by switching
  # `if (FALSE)` to `if (TRUE)`.
  if (FALSE) list(
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

  # Kept as separate un-hashed targets (rather than a field on
  # bertopic_local_cfg/bertopic_runpod_cfg) because .topics_cfg_hash()
  # hashes the whole cfg object for the skip-guard marker comparison —
  # folding run_name into cfg would change that hash for every config and
  # force a spurious one-time re-run/re-dispatch on the next invocation.
  if (!is.null(cfg$bertopic$active_local)) {
    tar_target(
      bertopic_local_run_name,
      yaml::read_yaml(config_file)$bertopic$active_local
    )
  },
  tar_target(
    bertopic_runpod_run_name,
    yaml::read_yaml(config_file)$bertopic$active_runpod
  ),

  # Path A — local CPU sample-fit + transfer. Self-contained on the laptop.
  # corpus_emb_dir / reference_emb_dir resolve to the source-level dir via
  # dirname() of the primary variant target; the Python script discovers
  # variant=… partitions inside. fallback_* args are dep tokens so the
  # fallback variant targets are also DAG dependencies.
  if (!is.null(cfg$bertopic$active_local)) {
    tar_target(
      topics_local,
      run_bertopic_local(
        corpus_emb_dir = dirname(emb_corpus_title_abstract),
        reference_emb_dir = dirname(emb_keypapers_title_abstract),
        out_dir = "output/NXS_TCA_corpus/topics",
        cfg = bertopic_local_cfg,
        run_name = bertopic_local_run_name,
        fallback_corpus = emb_corpus_title,
        fallback_ref = emb_keypapers_title
      ),
      format = "file"
    )
  },

  # The RunPod pod reads embeddings straight from R2 (no rsync upload) — see
  # run_bertopic_runpod()'s "Translate local emb dirs -> s3:// URIs" step. Both
  # the corpus and keypaper embeddings must therefore be mirrored to R2 before
  # dispatch, or the pod silently reads a stale/absent set. These two sync
  # targets depend on all three emb_* variants each, so they re-push whenever
  # any embedding changes; topics_runpod takes both as dep tokens below so the
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
  # Corpus embeddings → R2. Excludes the "No Chapter" partitions so BERTopic
  # clusters only chapter-assigned works (see sync_corpus_embeddings_to_r2()).
  # Small enough here to re-sync per run (unlike the ~6M-row TCAC 2.0 corpus).
  tar_target(
    emb_corpus_r2_synced,
    sync_corpus_embeddings_to_r2(
      emb_corpus_title,
      emb_corpus_abstract,
      emb_corpus_title_abstract,
      r2_cfg = bertopic_runpod_cfg$r2,
      exclude_no_chapter = TRUE
    ),
    format = "file"
  ),

  # Path B — RunPod GPU full-fit via cuml. SSH/rsync orchestrated by the
  # R wrapper; needs a pod up from the docker/bertopic-runpod image.
  tar_target(
    topics_runpod,
    run_bertopic_runpod(
      corpus_emb_dir = dirname(emb_corpus_title_abstract),
      reference_emb_dir = dirname(emb_keypapers_title_abstract),
      out_dir = "output/NXS_TCA_corpus/topics",
      cfg = bertopic_runpod_cfg,
      run_name = bertopic_runpod_run_name,
      fallback_corpus = emb_corpus_title,
      fallback_ref = emb_keypapers_title,
      keypaper_r2_synced = emb_keypapers_r2_synced,
      corpus_r2_synced = emb_corpus_r2_synced
    ),
    format = "file"
  )
  ), # end if (FALSE) — topic-modelling compute/sync disabled

  # NOTE: the previous topics alias target tried to switch
  # between Path A (topics_local) and Path B (topics_runpod)
  # via bertopic.active_for_viz. targets' static dependency analysis
  # treated BOTH referenced targets as deps regardless of which active
  # config was selected, so switching active_for_viz to default_runpod
  # still dispatched Path A. With Path B now the production path, the
  # viz layer references topics_runpod directly. Re-introduce
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
      scores_title,
      scores_abstract,
      scores_title_abstract
    ),
    format = qs2_format()
  ),
  # viz_metadata: orphaned — the Embedding report builds the
  # config × source × variant table inline (its own chunk), not via this
  # target. Commented out (builder viz_metadata_table() kept in R/).
  # tar_target(
  #   viz_metadata,
  #   viz_metadata_table(emb_corpus_title),
  #   format = qs2_format()
  # ),
  tar_target(
    viz_score_summary_tbl,
    viz_score_summary(viz_scores_long),
    format = qs2_format()
  ),
  # viz_score_quantiles_tbl: orphaned — redundant with viz_score_summary_tbl
  # (in the Chapter Analysis report), which already reports the same quantiles.
  # tar_target(
  #   viz_score_quantiles_tbl,
  #   viz_score_quantiles(viz_scores_long),
  #   format = qs2_format()
  # ),
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

  # ---- Chapter Analysis report (chapter <-> keypaper, from scores_combined) --
  # Centrepiece: top matches per keypaper, stacked by assessment/chapter, from
  # the per-chapter combined scores. Plus overall chapter-alignment + a
  # chapter x keypaper heatmap. (Replaces the old flat viz_top_matches_per_kp /
  # tbl_top_matches_per_kp, which had no chapter dimension.)
  tar_target(
    viz_top_matches_combined,
    build_viz_top_matches_per_kp_combined_data(
      scores_combined = scores_combined,
      key_works = key_works,
      corpus = corpus_chapter
    ),
    format = qs2_format()
  ),
  tar_target(
    tbl_top_matches_combined,
    build_tbl_top_matches_per_kp_combined_widget(viz_top_matches_combined),
    format = qs2_format()
  ),
  tar_target(
    viz_chapter_alignment_data,
    build_viz_chapter_alignment_data(scores_combined),
    format = qs2_format()
  ),
  tar_target(
    viz_chapter_alignment_fig,
    build_viz_chapter_alignment_fig(viz_chapter_alignment_data),
    format = qs2_format()
  ),
  tar_target(
    viz_chapter_keypaper_heatmap_data,
    build_viz_chapter_keypaper_heatmap_data(scores_combined, key_works),
    format = qs2_format()
  ),
  tar_target(
    viz_chapter_keypaper_heatmap_fig,
    build_viz_chapter_keypaper_heatmap_fig(viz_chapter_keypaper_heatmap_data),
    format = qs2_format()
  ),
  tar_target(
    viz_chapter_keypaper_heatmap_interactive_fig,
    build_viz_chapter_keypaper_heatmap_interactive_fig(
      viz_chapter_keypaper_heatmap_data
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_chapter_cliffs_delta_data,
    build_viz_chapter_cliffs_delta_data(scores_combined),
    format = qs2_format()
  ),
  tar_target(
    viz_chapter_cliffs_delta_fig,
    build_viz_chapter_cliffs_delta_fig(viz_chapter_cliffs_delta_data),
    format = qs2_format()
  ),
  tar_target(
    viz_chapter_cliffs_delta_interactive_data,
    build_viz_chapter_cliffs_delta_interactive_data(scores_combined, key_works),
    format = qs2_format()
  ),
  tar_target(
    viz_chapter_cliffs_delta_interactive_fig,
    build_viz_chapter_cliffs_delta_interactive_fig(
      viz_chapter_cliffs_delta_interactive_data
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_text_length_data,
    build_viz_text_length_data(
      corpus = corpus_chapter,
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

  # ---- Keyset linkage (keypaper <-> keypaper, 3 stages) --------------------
  # How the concept definitions link across key-sets, especially TCA Action ->
  # Nexus Response Option. Stage 1: definition-embedding similarity. Stage 2:
  # overlap of the cited literature (no embeddings). Stage 3: mean pairwise
  # cosine of the cited literature's embeddings. See R/build_linkage.R.
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
  tar_target(
    link_stage3,
    build_link_stage3_data(citations_resolved_active, emb_cited_title_abstract,
                           key_works),
    format = qs2_format()
  ),
  # Interactive (echarts4r) Sankeys — DISABLED for now in favour of the static
  # ggplot versions below (build_sankey_fig() is left in place, unreferenced).
  # Re-enable by unwrapping and repointing the report's fig-sankey-* chunks
  # back to these targets.
  if (FALSE) list(
  tar_target(
    viz_sankey_stage1_fig,
    build_sankey_fig(link_stage1, key_works, value_col = "sim",
                     name = "sankey_stage1_definition_embedding"),
    format = qs2_format()
  ),
  tar_target(
    viz_sankey_stage2_fig,
    build_sankey_fig(link_stage2, key_works, value_col = "jaccard",
                     name = "sankey_stage2_citation_overlap"),
    format = qs2_format()
  ),
  tar_target(
    viz_sankey_stage3_fig,
    build_sankey_fig(link_stage3, key_works, value_col = "sim",
                     name = "sankey_stage3_cited_embedding"),
    format = qs2_format()
  )
  ),
  # Static ggplot Sankeys, two source->target keyset pairs. Each pair gets the
  # three signal stages (definition embedding / citation overlap / cited
  # embedding). build_sankey_fig_ggplot() defaults to Action -> Response Option,
  # so the second pair passes source/target_keyset explicitly.
  # -- Pair A: TCA Action -> Nexus Response Option --
  # The two embedding-similarity stages (1 = definition text, 3 = cited
  # literature) show top 5 targets per node with links coloured by similarity;
  # stage 2 (citation-overlap Jaccard, not an embedding signal) stays top 3,
  # uncoloured.
  tar_target(
    viz_sankey_act_resp_stage1_ggplot_fig,
    build_sankey_fig_ggplot(link_stage1, key_works, value_col = "sim",
                            top_n = 5, color_by_value = TRUE,
                            name = "sankey_act_resp_stage1_definition_embedding_ggplot"),
    format = qs2_format()
  ),
  tar_target(
    viz_sankey_act_resp_stage2_ggplot_fig,
    build_sankey_fig_ggplot(link_stage2, key_works, value_col = "jaccard",
                            name = "sankey_act_resp_stage2_citation_overlap_ggplot"),
    format = qs2_format()
  ),
  tar_target(
    viz_sankey_act_resp_stage3_ggplot_fig,
    build_sankey_fig_ggplot(link_stage3, key_works, value_col = "sim",
                            top_n = 5, color_by_value = TRUE,
                            name = "sankey_act_resp_stage3_cited_embedding_ggplot"),
    format = qs2_format()
  ),
  # -- Pair B: TCA Approaches -> TCA Action --
  tar_target(
    viz_sankey_appr_act_stage1_ggplot_fig,
    build_sankey_fig_ggplot(link_stage1, key_works, value_col = "sim",
                            source_keyset = "TCA_Approaches_3_2",
                            target_keyset = "TCA_Actions_Ch5",
                            top_n = 5, color_by_value = TRUE,
                            name = "sankey_appr_act_stage1_definition_embedding_ggplot"),
    format = qs2_format()
  ),
  tar_target(
    viz_sankey_appr_act_stage2_ggplot_fig,
    build_sankey_fig_ggplot(link_stage2, key_works, value_col = "jaccard",
                            source_keyset = "TCA_Approaches_3_2",
                            target_keyset = "TCA_Actions_Ch5",
                            name = "sankey_appr_act_stage2_citation_overlap_ggplot"),
    format = qs2_format()
  ),
  tar_target(
    viz_sankey_appr_act_stage3_ggplot_fig,
    build_sankey_fig_ggplot(link_stage3, key_works, value_col = "sim",
                            source_keyset = "TCA_Approaches_3_2",
                            target_keyset = "TCA_Actions_Ch5",
                            top_n = 5, color_by_value = TRUE,
                            name = "sankey_appr_act_stage3_cited_embedding_ggplot"),
    format = qs2_format()
  ),
  tar_target(
    viz_keyset_matrix_stage1_fig,
    build_keyset_matrix_fig(link_stage1, value_col = "sim",
                            name = "keyset_matrix_stage1"),
    format = qs2_format()
  ),
  tar_target(
    viz_keyset_matrix_stage2_fig,
    build_keyset_matrix_fig(link_stage2, value_col = "jaccard",
                            name = "keyset_matrix_stage2"),
    format = qs2_format()
  ),
  tar_target(
    viz_keyset_matrix_stage3_fig,
    build_keyset_matrix_fig(link_stage3, value_col = "sim",
                            name = "keyset_matrix_stage3"),
    format = qs2_format()
  ),
  tar_target(
    viz_pair_heatmap_appr_act_stage1_fig,
    build_pair_heatmap_fig(link_stage1, key_works, value_col = "sim",
                           source_keyset = "TCA_Approaches_3_2",
                           target_keyset = "TCA_Actions_Ch5",
                           name = "pair_heatmap_appr_act_stage1"),
    format = qs2_format()
  ),
  tar_target(
    viz_pair_heatmap_appr_act_stage2_fig,
    build_pair_heatmap_fig(link_stage2, key_works, value_col = "jaccard",
                           source_keyset = "TCA_Approaches_3_2",
                           target_keyset = "TCA_Actions_Ch5",
                           name = "pair_heatmap_appr_act_stage2"),
    format = qs2_format()
  ),
  tar_target(
    viz_pair_heatmap_appr_act_stage3_fig,
    build_pair_heatmap_fig(link_stage3, key_works, value_col = "sim",
                           source_keyset = "TCA_Approaches_3_2",
                           target_keyset = "TCA_Actions_Ch5",
                           name = "pair_heatmap_appr_act_stage3"),
    format = qs2_format()
  ),
  tar_target(
    viz_pair_heatmap_appr_act_combined_fig,
    build_pair_heatmap_combined_fig(link_stage1, link_stage2, key_works,
                                    source_keyset = "TCA_Approaches_3_2",
                                    target_keyset = "TCA_Actions_Ch5",
                                    name = "pair_heatmap_appr_act_combined"),
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

  tar_target(
    viz_score_year_data,
    build_viz_score_year_data(viz_scores_long, corpus_chapter),
    format = qs2_format()
  ),
  tar_target(
    viz_score_year_fig,
    build_viz_score_year_fig(viz_score_year_data),
    format = qs2_format()
  ),
  tar_target(
    viz_type_counts,
    build_viz_type_counts(corpus_chapter, min_pct = 0.5),
    format = qs2_format()
  ),
  tar_target(
    viz_type_count_fig,
    build_viz_type_count_fig(viz_type_counts),
    format = qs2_format()
  ),
  tar_target(
    viz_type_score_stats,
    build_viz_type_score_stats(viz_scores_long, corpus_chapter, min_pct = 0.5),
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
    build_viz_language_counts(corpus_chapter, min_pct = 0.5),
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
      corpus_chapter,
      title_cap_combined = emb_cfg$title_cap_combined %||% 200L,
      sep_token = emb_cfg$sep_token %||% "[SEP]"
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_keypaper_score_dist_data,
    build_viz_keypaper_score_dist_data(
      scores_title_abstract,
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
      emb_corpus_title = emb_corpus_title,
      emb_corpus_abstract = emb_corpus_abstract,
      emb_corpus_title_abstract = emb_corpus_title_abstract,
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
    build_viz_citation_score_data(viz_scores_long, corpus_chapter),
    format = qs2_format()
  ),
  tar_target(
    viz_citation_score_fig,
    build_viz_citation_score_fig(viz_citation_score_data),
    format = qs2_format()
  ),
  tar_target(
    viz_top_bottom,
    viz_top_bottom_tables(viz_scores_long, corpus_chapter),
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

  # === Topic-modelling visualisation: DISABLED (see if(FALSE) note above) ====
  if (FALSE) list(
  tar_target(
    viz_umap_coords_df,
    viz_umap_coords(
      emb_corpus_title_abstract,
      emb_keypapers_title_abstract,
      viz_cfg = viz_cfg
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_umap_join,
    viz_umap_data(
      umap_coords = viz_umap_coords_df,
      emb_corpus_title = emb_corpus_title,
      emb_keypapers_title = emb_keypapers_title,
      scores_title_abstract = scores_title_abstract,
      corpus = corpus_chapter,
      key_works = key_works
    ),
    format = qs2_format()
  ),
  tar_target(
    viz_umap_bestkp,
    viz_umap_best_kp(viz_umap_join, scores_title_abstract),
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
    build_tbl_topics_data(topics_runpod, emb_corpus_title),
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
      topics = topics_runpod,
      emb_corpus = viz_umap_join$emb_corpus,
      emb_keypaper = viz_umap_kp
    ),
    format = qs2_format()
  )
  ), # end if (FALSE) — topic-modelling viz disabled

  # Render the embeddings report. Re-builds whenever any score parquet,
  # the embeddings dataset, or the .qmd itself changes.
  tarchetypes::tar_quarto(
    render_report_embeddings,
    path = "NXS TCS Article Embedding Report.qmd",
    output_file = paste0(
      "NXS TCS Article Embedding Report - ",
      emb_name,
      ".html"
    ),
    quiet = TRUE
  ),

  # Render the Topic Modelling Report — DISABLED (no topic modelling for now).
  # Re-enable together with the topic compute/viz blocks above.
  if (FALSE) tarchetypes::tar_quarto(
    render_report_topic_modelling,
    path = "NXS TCS Article Topic Modelling Report.qmd",
    output_file = paste0(
      "NXS TCS Article Topic Modelling Report - ",
      bertopic_viz_name,
      ".html"
    ),
    quiet = TRUE
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

  # Top-level index: intro + links to the reports. Depends only on the reports
  # (via tar_read in the .qmd) — a lightweight landing page; its links resolve
  # once each report is rendered into output/reports/.
  tarchetypes::tar_quarto(
    render_report_index,
    path = "NXS TCS Article Report.qmd",
    output_file = "NXS TCS Article Report.html",
    quiet = TRUE
  ),

  # Sync the rendered reports into output/reports/. Each report's filename
  # already carries its config name (baked into output_file above via
  # emb_name / bertopic_viz_name), so switching the active config produces a
  # differently-named file rather than overwriting the previous one — these
  # copies just collect the per-config reports into one folder. tar_quarto's
  # format="file" value is c(<rendered>.html, <source>.qmd) — it tracks the
  # input alongside the output for staleness — so pick out just the .html.
  tar_target(
    report_embeddings,
    {
      src <- render_report_embeddings[grepl(
        "\\.html$",
        render_report_embeddings
      )]
      if (length(src) != 1) {
        stop(
          "Expected exactly one rendered .html among ",
          "render_report_embeddings's tracked files, got: ",
          paste(render_report_embeddings, collapse = ", ")
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
  # report_topic_modelling — DISABLED (no topic modelling for now).
  if (FALSE) tar_target(
    report_topic_modelling,
    {
      src <- render_report_topic_modelling[grepl(
        "\\.html$",
        render_report_topic_modelling
      )]
      if (length(src) != 1) {
        stop(
          "Expected exactly one rendered .html among ",
          "render_report_topic_modelling's tracked files, got: ",
          paste(render_report_topic_modelling, collapse = ", ")
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
        "\\.html$", render_report_citation_comparison
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
  tar_target(
    report_index,
    {
      src <- render_report_index[grepl("\\.html$", render_report_index)]
      if (length(src) != 1) {
        stop(
          "Expected exactly one rendered .html among ",
          "render_report_index's tracked files, got: ",
          paste(render_report_index, collapse = ", ")
        )
      }
      dest_dir <- "output/reports"
      dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
      dest <- file.path(dest_dir, "index.html") # basename(src))
      if (!file.copy(src, dest, overwrite = TRUE)) {
        stop("Could not copy ", src, " to ", dest)
      }
      dest
    },
    format = "file"
  ),

  NULL
)
