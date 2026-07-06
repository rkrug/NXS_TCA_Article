# Sync the local keypaper embeddings to Cloudflare R2 so the RunPod BERTopic
# pod sees the current keypaper set.
#
# run_bertopic_runpod() never uploads anything — it just translates the local
# `source=keypaper` path into the matching `s3://` URI and tells the pod to
# read from there via duckdb httpfs (see its "Translate local emb dirs ->
# s3:// URIs" step). Without this target, regenerating emb_keypapers_*
# locally (e.g. after swapping the keypaper input file) has no effect on
# what topics_runpod actually scores against, since the pod only ever
# looks at R2 — it silently keeps reading whatever was last pushed there.
#
# Credentials are read fresh from the system keyring on every call (entries
# R2_ACCESS_KEY / R2_SECRET_KEY) into a throwaway rclone remote defined
# purely via env vars, rather than relying on a pre-configured named remote
# in ~/.config/rclone/rclone.conf — keeps this target self-contained and
# independent of what's set up on the machine running the pipeline.

sync_keypaper_embeddings_to_r2 <- function(
  emb_keypapers_title,
  emb_keypapers_abstract,
  emb_keypapers_title_abstract,
  r2_cfg
) {
  if (!requireNamespace("keyring", quietly = TRUE)) {
    stop("Package 'keyring' is required for sync_keypaper_embeddings_to_r2().")
  }
  required <- c(
    "endpoint", "bucket", "embeddings_local_root", "embeddings_remote_prefix"
  )
  missing <- setdiff(required, names(r2_cfg %||% list()))
  if (length(missing)) {
    stop("r2_cfg is missing fields: ", paste(missing, collapse = ", "))
  }

  variant_dirs <- c(
    emb_keypapers_title, emb_keypapers_abstract, emb_keypapers_title_abstract
  )
  config_dirs <- unique(dirname(dirname(variant_dirs)))
  if (length(config_dirs) != 1L) {
    stop(
      "Keypaper embedding variants must share one config dir; got: ",
      paste(config_dirs, collapse = ", ")
    )
  }
  local_root <- file.path(config_dirs, "source=keypaper")
  if (!dir.exists(local_root)) {
    stop("Expected keypaper embeddings at: ", local_root)
  }

  emb_root <- normalizePath(
    r2_cfg$embeddings_local_root, mustWork = TRUE, winslash = "/"
  )
  abs_local <- normalizePath(local_root, mustWork = TRUE, winslash = "/")
  if (!startsWith(abs_local, emb_root)) {
    stop(
      "keypaper emb path ", abs_local,
      " is not under r2.embeddings_local_root ", emb_root
    )
  }
  rel <- sub("^/+", "", substring(abs_local, nchar(emb_root) + 1L))
  remote_path <- sprintf(
    "r2kp:%s/%s/%s", r2_cfg$bucket, r2_cfg$embeddings_remote_prefix, rel
  )

  access_key <- keyring::key_get("R2_ACCESS_KEY")
  secret_key <- keyring::key_get("R2_SECRET_KEY")

  env_vars <- c(
    "RCLONE_CONFIG_R2KP_TYPE", "RCLONE_CONFIG_R2KP_PROVIDER",
    "RCLONE_CONFIG_R2KP_ACCESS_KEY_ID", "RCLONE_CONFIG_R2KP_SECRET_ACCESS_KEY",
    "RCLONE_CONFIG_R2KP_ENDPOINT", "RCLONE_CONFIG_R2KP_ACL"
  )
  old_env <- Sys.getenv(env_vars, unset = NA, names = TRUE)
  on.exit({
    for (nm in names(old_env)) {
      if (is.na(old_env[[nm]])) {
        Sys.unsetenv(nm)
      } else {
        do.call(Sys.setenv, stats::setNames(list(old_env[[nm]]), nm))
      }
    }
  }, add = TRUE)

  Sys.setenv(
    RCLONE_CONFIG_R2KP_TYPE               = "s3",
    RCLONE_CONFIG_R2KP_PROVIDER           = "Cloudflare",
    RCLONE_CONFIG_R2KP_ACCESS_KEY_ID      = access_key,
    RCLONE_CONFIG_R2KP_SECRET_ACCESS_KEY  = secret_key,
    RCLONE_CONFIG_R2KP_ENDPOINT           = r2_cfg$endpoint,
    RCLONE_CONFIG_R2KP_ACL                = "private"
  )

  message(sprintf(
    "[sync_keypaper_embeddings_to_r2] %s -> %s", local_root, remote_path
  ))
  out <- system2(
    "rclone",
    c(
      "sync", local_root, remote_path,
      "--exclude", ".DS_Store",
      "--exclude", "._*",
      "--exclude", ".embed_complete",
      "--exclude", ".r2_synced"
    ),
    stdout = TRUE, stderr = TRUE
  )
  status <- attr(out, "status")
  cat(out, sep = "\n")
  if (!is.null(status) && status != 0L) {
    stop("rclone sync failed (status ", status, ") — see output above.")
  }

  marker_path <- file.path(local_root, ".r2_synced")
  writeLines(as.character(Sys.time()), marker_path)
  marker_path
}
