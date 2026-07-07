# Sync the local corpus embeddings to Cloudflare R2 so the RunPod BERTopic
# pod can read them via duckdb httpfs.
#
# Companion to sync_keypaper_embeddings_to_r2() (same self-contained
# keyring-env rclone remote approach — no reliance on a pre-configured named
# remote in rclone.conf). run_bertopic_runpod() never uploads corpus
# embeddings itself; it only translates the local source=corpus path into the
# matching s3:// URI and tells the pod to read from there. This target closes
# that gap so `tar_make(topics_runpod)` re-pushes the corpus whenever the
# embeddings change.
#
# (On the upstream TCAC 2.0 corpus this made no sense — ~6M embeddings, tens of
# GB, mirrored once by hand. This corpus is small enough to re-sync per run.)
#
# Chapter filter: by default the "No Chapter" partitions (works with no chapter
# tag) are EXCLUDED from the upload, so BERTopic clusters only chapter-assigned
# works. `--delete-excluded` makes the remote exactly match the local tree
# minus the excludes, so a stale No-Chapter partition left on R2 from an
# earlier sync is removed rather than silently re-read by the pod.

sync_corpus_embeddings_to_r2 <- function(
  emb_corpus_title,
  emb_corpus_abstract,
  emb_corpus_title_abstract,
  r2_cfg,
  exclude_no_chapter = TRUE
) {
  if (!requireNamespace("keyring", quietly = TRUE)) {
    stop("Package 'keyring' is required for sync_corpus_embeddings_to_r2().")
  }
  required <- c(
    "endpoint", "bucket", "embeddings_local_root", "embeddings_remote_prefix"
  )
  missing <- setdiff(required, names(r2_cfg %||% list()))
  if (length(missing)) {
    stop("r2_cfg is missing fields: ", paste(missing, collapse = ", "))
  }

  variant_dirs <- c(
    emb_corpus_title, emb_corpus_abstract, emb_corpus_title_abstract
  )
  config_dirs <- unique(dirname(dirname(variant_dirs)))
  if (length(config_dirs) != 1L) {
    stop(
      "Corpus embedding variants must share one config dir; got: ",
      paste(config_dirs, collapse = ", ")
    )
  }
  local_root <- file.path(config_dirs, "source=corpus")
  if (!dir.exists(local_root)) {
    stop("Expected corpus embeddings at: ", local_root)
  }

  emb_root <- normalizePath(
    r2_cfg$embeddings_local_root, mustWork = TRUE, winslash = "/"
  )
  abs_local <- normalizePath(local_root, mustWork = TRUE, winslash = "/")
  if (!startsWith(abs_local, emb_root)) {
    stop(
      "corpus emb path ", abs_local,
      " is not under r2.embeddings_local_root ", emb_root
    )
  }
  rel <- sub("^/+", "", substring(abs_local, nchar(emb_root) + 1L))
  remote_path <- sprintf(
    "r2corp:%s/%s/%s", r2_cfg$bucket, r2_cfg$embeddings_remote_prefix, rel
  )

  access_key <- keyring::key_get("R2_ACCESS_KEY")
  secret_key <- keyring::key_get("R2_SECRET_KEY")

  env_vars <- c(
    "RCLONE_CONFIG_R2CORP_TYPE", "RCLONE_CONFIG_R2CORP_PROVIDER",
    "RCLONE_CONFIG_R2CORP_ACCESS_KEY_ID", "RCLONE_CONFIG_R2CORP_SECRET_ACCESS_KEY",
    "RCLONE_CONFIG_R2CORP_ENDPOINT", "RCLONE_CONFIG_R2CORP_ACL"
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
    RCLONE_CONFIG_R2CORP_TYPE               = "s3",
    RCLONE_CONFIG_R2CORP_PROVIDER           = "Cloudflare",
    RCLONE_CONFIG_R2CORP_ACCESS_KEY_ID      = access_key,
    RCLONE_CONFIG_R2CORP_SECRET_ACCESS_KEY  = secret_key,
    RCLONE_CONFIG_R2CORP_ENDPOINT           = r2_cfg$endpoint,
    RCLONE_CONFIG_R2CORP_ACL                = "private"
  )

  # Chapter values are URL-encoded on disk: "No Chapter" -> "No%20Chapter".
  # Match at any depth (…/variant=X/assessment=Y/chapter=No%20Chapter/…).
  no_chapter_excludes <- if (isTRUE(exclude_no_chapter)) {
    c("--exclude", "**/chapter=No%20Chapter/**")
  } else {
    character(0)
  }

  args <- c(
    "sync", local_root, remote_path,
    "--exclude", ".DS_Store",
    "--exclude", "._*",
    "--exclude", ".embed_complete",
    "--exclude", ".r2_synced",
    "--exclude", ".parts.tmp/**",
    no_chapter_excludes,
    # Make the remote exactly match local-minus-excludes: drop any excluded
    # objects (e.g. a No-Chapter partition, markers) left on R2 by a prior
    # sync, so the pod's recursive glob never re-reads them.
    "--delete-excluded",
    "--fast-list"
  )

  message(sprintf(
    "[sync_corpus_embeddings_to_r2] %s -> %s%s",
    local_root, remote_path,
    if (isTRUE(exclude_no_chapter)) " (excluding No Chapter)" else ""
  ))
  out <- system2("rclone", args, stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status")
  cat(out, sep = "\n")
  if (!is.null(status) && status != 0L) {
    stop("rclone sync failed (status ", status, ") — see output above.")
  }

  marker_path <- file.path(local_root, ".r2_synced")
  writeLines(as.character(Sys.time()), marker_path)
  marker_path
}
