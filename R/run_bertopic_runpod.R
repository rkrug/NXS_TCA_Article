# RunPod-mode BERTopic wrapper.
#
# Orchestrates a one-shot BERTopic job on a remote RunPod pod built from the
# docker/bertopic-runpod/ image. Steps, all over SSH:
#   1. Skip-guard on local leaf — if .topics_complete exists, return.
#   2. Validate SSH connectivity.
#   3. rsync the primary variant + fallback variant + keypaper variants up to
#      cfg$remote_workdir. rsync allows resume if a previous attempt died
#      mid-upload (~32 GB takes ~50 min on RunPod's network at ~10 MB/s).
#   4. Write a single-config YAML and scp it.
#   5. ssh + invoke /opt/run_bertopic_gpu.py on the pod.
#   6. scp the three result parquets back into the local leaf.
#   7. Stamp .topics_complete locally.
#
# Designed for migration into openalexVectorComp: signature matches
# run_bertopic_local(), no private deps from this repo, configuration purely
# via the `cfg` list.

run_bertopic_runpod <- function(
  corpus_emb_dir,
  reference_emb_dir,
  out_dir,
  cfg,
  run_name,
  ...   # ignored — dep tokens (fallback_corpus, fallback_ref)
) {
  if (!is.list(cfg) || !nzchar(cfg$primary_variant %||% "")) {
    stop("`cfg` must be a list with at least `primary_variant`.")
  }
  if (!is.character(run_name) || length(run_name) != 1L || !nzchar(run_name)) {
    stop("`run_name` must be a non-empty string.")
  }
  required_ssh <- c("ssh_host", "ssh_user", "ssh_port", "ssh_key_path",
                    "remote_workdir")
  missing_ssh  <- setdiff(required_ssh, names(cfg))
  if (length(missing_ssh)) {
    stop(
      "`cfg` is missing SSH transport fields: ",
      paste(missing_ssh, collapse = ", "),
      ". See docker/bertopic-runpod/README.md."
    )
  }

  config_dir_corpus <- dirname(corpus_emb_dir)
  config_dir_ref    <- dirname(reference_emb_dir)
  if (!identical(config_dir_corpus, config_dir_ref)) {
    stop(
      "corpus and reference must share parent (config dir); got\n",
      "  corpus:    ", config_dir_corpus, "\n",
      "  reference: ", config_dir_ref
    )
  }
  config_name <- sub("^config=", "", basename(config_dir_corpus))
  primary     <- cfg$primary_variant
  fallback    <- cfg$fallback_variant

  leaf_dir <- file.path(
    out_dir,
    paste0("config=",   config_name),
    paste0("bertopic=", run_name),
    paste0("variant=",  primary)
  )
  topic_info_path <- file.path(leaf_dir, "topic_info.parquet")
  marker_path     <- file.path(leaf_dir, ".topics_complete")
  dir.create(leaf_dir, recursive = TRUE, showWarnings = FALSE)

  # ---- skip-guard -------------------------------------------------------
  if (file.exists(marker_path) && file.exists(topic_info_path)) {
    message(sprintf(
      "[bertopic_runpod|%s] leaf already complete — skipping run.", run_name
    ))
    return(topic_info_path)
  }

  # ---- SSH command builders (use openssh client) ----------------------
  ssh_target <- sprintf("%s@%s", cfg$ssh_user, cfg$ssh_host)
  ssh_key    <- normalizePath(cfg$ssh_key_path, mustWork = TRUE)
  ssh_port   <- as.integer(cfg$ssh_port)

  ssh_cmd <- function(remote_cmd) {
    args <- c(
      "-i", shQuote(ssh_key),
      "-p", as.character(ssh_port),
      "-o", "StrictHostKeyChecking=accept-new",
      "-o", "ServerAliveInterval=60",
      ssh_target,
      shQuote(remote_cmd)
    )
    sys_call("ssh", args)
  }

  # rsync is preferred over scp for resumability + parallel transfer of
  # many small parquet files.
  rsync_to_pod <- function(local_path, remote_path) {
    args <- c(
      "-az", "--info=progress2",
      "-e", shQuote(sprintf("ssh -i %s -p %d -o StrictHostKeyChecking=accept-new",
                            ssh_key, ssh_port)),
      shQuote(local_path),
      shQuote(sprintf("%s:%s", ssh_target, remote_path))
    )
    sys_call("rsync", args)
  }
  rsync_from_pod <- function(remote_path, local_path) {
    args <- c(
      "-az", "--info=progress2",
      "-e", shQuote(sprintf("ssh -i %s -p %d -o StrictHostKeyChecking=accept-new",
                            ssh_key, ssh_port)),
      shQuote(sprintf("%s:%s", ssh_target, remote_path)),
      shQuote(local_path)
    )
    sys_call("rsync", args)
  }

  # ---- 1. Connectivity check -------------------------------------------
  message(sprintf("[bertopic_runpod|%s] checking SSH connectivity to %s",
                  run_name, ssh_target))
  ssh_cmd("true")   # errors out if connection / auth fails

  # ---- 2. Prepare remote workdir ---------------------------------------
  remote_root  <- cfg$remote_workdir
  remote_in    <- file.path(remote_root, "in",  paste0("config=", config_name))
  remote_corp  <- file.path(remote_in, "source=corpus")
  remote_ref   <- file.path(remote_in, "source=keypaper")
  remote_out   <- file.path(remote_root, "out")
  remote_cfg   <- file.path(remote_root, sprintf("bertopic_cfg_%s.yaml", run_name))
  ssh_cmd(sprintf(
    "mkdir -p %s %s %s",
    shQuote(remote_corp), shQuote(remote_ref), shQuote(remote_out)
  ))
  ssh_cmd(sprintf("touch %s/.heartbeat",
                  shQuote(remote_root)))

  # ---- 3. Upload required variants -------------------------------------
  variants_to_upload <- unique(c(primary, fallback))
  variants_to_upload <- variants_to_upload[!is.na(variants_to_upload) &
                                             nzchar(variants_to_upload)]
  for (v in variants_to_upload) {
    local_corp_v <- file.path(corpus_emb_dir,    paste0("variant=", v))
    local_ref_v  <- file.path(reference_emb_dir, paste0("variant=", v))
    if (dir.exists(local_corp_v)) {
      message(sprintf("[bertopic_runpod|%s] uploading corpus/variant=%s …",
                      run_name, v))
      ssh_cmd(sprintf("mkdir -p %s", shQuote(file.path(remote_corp, paste0("variant=", v)))))
      rsync_to_pod(paste0(local_corp_v, "/"),
                   paste0(file.path(remote_corp, paste0("variant=", v)), "/"))
    }
    if (dir.exists(local_ref_v)) {
      message(sprintf("[bertopic_runpod|%s] uploading keypaper/variant=%s …",
                      run_name, v))
      ssh_cmd(sprintf("mkdir -p %s", shQuote(file.path(remote_ref, paste0("variant=", v)))))
      rsync_to_pod(paste0(local_ref_v, "/"),
                   paste0(file.path(remote_ref, paste0("variant=", v)), "/"))
    }
  }

  # ---- 4. Push the per-run cfg yaml ------------------------------------
  cfg_local <- tempfile(pattern = "bertopic_cfg_", fileext = ".yaml")
  on.exit(unlink(cfg_local), add = TRUE)
  yaml::write_yaml(cfg, cfg_local)
  rsync_to_pod(cfg_local, remote_cfg)

  # ---- 5. Trigger the GPU script on the pod ----------------------------
  remote_cmd <- sprintf(
    "set -euo pipefail; touch %s/.heartbeat; python /opt/run_bertopic_gpu.py %s %s %s %s %s",
    shQuote(remote_root),
    sprintf("--corpus-emb-dir %s",    shQuote(remote_corp)),
    sprintf("--reference-emb-dir %s", shQuote(remote_ref)),
    sprintf("--output-dir %s",        shQuote(remote_out)),
    sprintf("--bertopic-cfg-yaml %s", shQuote(remote_cfg)),
    sprintf("--run-name %s",          shQuote(run_name))
  )
  message(sprintf("[bertopic_runpod|%s] running GPU script on the pod (may take 1–4 h)",
                  run_name))
  ssh_cmd(remote_cmd)

  # ---- 6. Download results --------------------------------------------
  remote_leaf <- file.path(
    remote_out,
    paste0("config=",   config_name),
    paste0("bertopic=", run_name),
    paste0("variant=",  primary)
  )
  message(sprintf("[bertopic_runpod|%s] downloading topic parquets", run_name))
  rsync_from_pod(paste0(remote_leaf, "/"),
                 paste0(leaf_dir, "/"))

  # ---- 7. Validate + stamp marker -------------------------------------
  expected <- c("topic_info.parquet", "topics.parquet", "topic_words.parquet")
  missing  <- expected[!file.exists(file.path(leaf_dir, expected))]
  if (length(missing)) {
    stop("Expected outputs missing in local leaf ", leaf_dir, ": ",
         paste(missing, collapse = ", "))
  }
  write_topics_marker(leaf_dir, run_name)

  topic_info_path
}

# Tiny helper so each call site doesn't repeat the system2 + status check.
sys_call <- function(cmd, args) {
  status <- system2(cmd, args = args, stdout = "", stderr = "")
  if (status != 0L) {
    stop(sprintf("`%s` exited with status %d (args: %s)",
                 cmd, status, paste(args, collapse = " ")))
  }
  invisible(NULL)
}

if (!exists("%||%")) {
  `%||%` <- function(x, y) if (is.null(x)) y else x
}
