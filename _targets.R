# _targets.R

library(targets)
library(tarchetypes)
library(quarto)
library(openalexPro)
library(rmarkdown)

# Source all R files in the R/ folder
lapply(list.files("R", pattern = "\\.R$", full.names = TRUE), source)

# Build one independent target per parameter (no shared params target) ----

params <- rmarkdown::yaml_front_matter(
  normalizePath("./TCAC 2.0 Building.qmd")
)$params

param_targets <- unlist(
  lapply(
    names(params),
    function(param_name) {
      tar_target_raw(
        name = paste0("param_", param_name),
        command = substitute(
          param_value,
          list(param_value = params[[param_name]])
        )
      )
    }
  ),
  recursive = FALSE
)

rm(params)

# Set target options -----------------------------------------------------

tar_option_set(
  packages = c(
    "dplyr",
    "arrow",
    "openalexPro"
  ), # packages loaded for all targets
  format = "rds" # default storage format
)

# Define the pipeline ----------------------------------------------------

c(
  param_targets,

  list(
    # Track Input Files ------------------------------------------------------

    tar_target(
      quarto_file,
      normalizePath("./TCAC 2.0 Building.qmd"),
      format = "file"
    ),

    tar_target(
      ids_tcac10_file,
      param_ids_tcac10_dir,
      format = "file"
    ),

    # Track keypaper doi list from TCAC 1.0 ----------------------------------

    tar_target(
      key_papers_file,
      param_key_papers_dir,
      format = "file"
    ),

    tar_target(
      key_works,
      prepare_keypapers(key_papers_file, workers = param_workers),
      format = "file"
    ),

    # Track types list -------------------------------------------------------

    tar_target(
      types_file,
      param_types_filter_dir,
      format = "file"
    ),
    tar_target(
      types_filter,
      {
        types_file |>
          read.csv() |>
          dplyr::filter(Included) |>
          dplyr::pull(Type)
      }
    ),

    # Track search term `tfc` ------------------------------------------------

    tar_target(
      tfc_file,
      param_tfc_dir,
      format = "file"
    ),
    tar_target(
      tfc_st,
      {
        tfc_file |>
          readLines() |>
          paste0(collapse = "\n")
      }
    ),

    # Track searech term `nature` -------------------------------------------

    tar_target(
      nature_file,
      param_nature_dir,
      format = "file"
    ),

    tar_target(
      nature_st,
      {
        nature_file |>
          readLines() |>
          paste0(collapse = "\n")
      }
    ),

    # Define search term `tfc AND nature` ------------------------------------

    tar_target(
      tca_st,
      {
        paste(
          "(",
          nature_st,
          ") \nAND \n(",
          tfc_st,
          ")"
        )
      }
    ),

    # Define the pipeline ----------------------------------------------------

    tar_target(
      count_st,
      get_count(tfc_st, nature_st, types_filter, workers = param_workers),
      format = "file"
    ),

    # TCAC 2.0: Get ids -------------------------------------------------------

    tar_target(
      tcac_20_ids,
      get_tcac20_ids(
        st = tca_st,
        tf = types_filter,
        project_folder = param_ids_tcac20_dir
      ),
      format = "file"
    ),

    # TCAC 2.0: Extract Corpus from Snapshot using the ids --------------------------

    tar_target(
      tcac_20_corpus,
      get_corpus_from_snapshot(
        ids_db = tcac_20_ids,
        snapshot_dir = param_snapshot_dir,
        corpus_dir = param_corpus_tcac20_dir
      ),
      format = "file"
    ),

    # TCAC 1.0: Extract from Snapshot using the ids --------------------------

    tar_target(
      tcac_10_corpus,
      get_corpus_from_snapshot(
        ids_db = param_ids_tcac10_dir,
        snapshot_dir = param_snapshot_dir,
        corpus_dir = param_corpus_tcac10_dir
      ),
      format = "file"
    )

    # Render final report ----------------------------------------------------

    # Render the Quarto document as the final step
    # tar_target(
    #   report,
    #   {
    #     quarto::quarto_render(quarto_file)
    #     # Clean up _files directory (embed-resources makes it unnecessary)
    #     unlink("TCAC 2.0 Building_files", recursive = TRUE)
    #     "TCAC 2.0 Building.html"
    #   },
    #   format = "file"
    # )
  )
)
