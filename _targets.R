# _targets.R

library(targets)
library(tarchetypes)
library(quarto)
library(openalexPro)
library(rmarkdown)

# Source all R files in the R/ folder
lapply(list.files("R", pattern = "\\.R$", full.names = TRUE), source)

## read params from the TCAC 2.0 Building.qmd file
params <- rmarkdown::yaml_front_matter(normalizePath(
  "./TCAC 2.0 Building.qmd"
))$params

# Set target options
tar_option_set(
  packages = c("dplyr", "arrow"), # packages loaded for all targets
  format = "rds" # default storage format
)

# Define the pipeline
list(
  #### Preparations

  # Track keypaper doi list from TCAC 1.0
  tar_target(
    key_papers_file,
    params$key_papers,
    format = "file"
  ),
  tar_target(
    key_works,
    prepare_keypapers(key_papers_file),
    format = "file"
  ),

  # Track types list
  tar_target(
    types_file,
    params$types_filter,
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

  # Track search term tfc
  tar_target(
    tfc_file,
    params$tfc,
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

  # Track search term nature
  tar_target(
    nature_file,
    params$nature,
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

  # Define search term tfc AND nature
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

  #### Get count

  tar_target(
    count_st,
    get_count(tfc_st, nature_st, types_filter, workers = params$workers),
  ),

  #### Render final report

  # Render the Quarto document as the final step
  tar_target(
    report,
    {
      quarto::quarto_render("TCAC 2.0 Building.qmd")
      # Clean up _files directory (embed-resources makes it unnecessary)
      unlink("TCAC 2.0 Building_files", recursive = TRUE)
      "TCAC 2.0 Building.html"
    },
    format = "file"
  )
)
