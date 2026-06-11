# RunPod-mode BERTopic wrapper (Phase 1 — embeddings in R2).
#
# Orchestrates a one-shot BERTopic job on a remote RunPod pod built from the
# docker/bertopic-runpod/ image. The pod reads embeddings *directly from
# Cloudflare R2* via duckdb httpfs — no 32 GB rsync upload from the laptop.
# Only the small per-run cfg yaml goes up the wire, and only the small
# result parquets come back.
#
# Steps:
#   1. Skip-guard on local leaf — if .topics_complete exists and cfg hash
#      matches, return.
#   2. Validate SSH connectivity.
#   3. Translate local emb dirs -> s3:// URIs using cfg$r2.
#   4. Write a single-config YAML (no secrets) and rsync it to the pod.
#   5. ssh + invoke /opt/run_bertopic_gpu.py on the pod with the s3 URIs.
#   6. rsync the three result parquets back into the local leaf.
#   7. Stamp .topics_complete locally.
#
# Designed for migration into openalexVectorComp: signature matches
# run_bertopic_local(), no private deps from this repo, configuration purely
# via the `cfg` list (incl. cfg$r2 sub-list for endpoint/bucket/prefix).

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
  required_r2 <- c("endpoint", "bucket", "embeddings_local_root",
                   "embeddings_remote_prefix")
  missing_r2  <- setdiff(required_r2, names(cfg$r2 %||% list()))
  if (length(missing_r2)) {
    stop(
      "`cfg$r2` is missing fields: ", paste(missing_r2, collapse = ", "),
      ". Add the r2: block in config.yaml — see cloud_storage_migration.md."
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
  # Cfg-aware (see run_bertopic_local.R for rationale). Skip only when the
  # marker's stored cfg_hash matches the current cfg's hash — so changing
  # bertopic params (or SSH details, since they're part of cfg) re-runs the
  # job automatically.
  current_cfg_hash <- .topics_cfg_hash(cfg)
  if (file.exists(marker_path) && file.exists(topic_info_path)) {
    marker <- read_topics_marker(leaf_dir)
    if (!is.na(marker$cfg_hash) &&
        identical(marker$cfg_hash, current_cfg_hash)) {
      message(sprintf(
        "[bertopic_runpod|%s] leaf already complete with matching cfg — skipping run.",
        run_name
      ))
      return(topic_info_path)
    }
    if (is.na(marker$cfg_hash)) {
      message(sprintf(
        "[bertopic_runpod|%s] marker has no cfg hash (older format) — re-running to refresh.",
        run_name
      ))
    } else {
      message(sprintf(
        "[bertopic_runpod|%s] cfg changed since last run (hash %s -> %s) — re-running.",
        run_name, substr(marker$cfg_hash, 1, 8), substr(current_cfg_hash, 1, 8)
      ))
    }
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
  # -rltD instead of -a: skip -o/-g (chown/chgrp), -p (perms). RunPod's
  # volume mount disallows chown by container root, which makes -a exit
  # non-zero even on successful transfer. We don't need ownership/perm
  # preservation — the pod runs as root, files only need to be readable.
  rsync_to_pod <- function(local_path, remote_path) {
    args <- c(
      "-rltD", "-z", "--progress",
      "-e", shQuote(sprintf("ssh -i %s -p %d -o StrictHostKeyChecking=accept-new",
                            ssh_key, ssh_port)),
      shQuote(local_path),
      shQuote(sprintf("%s:%s", ssh_target, remote_path))
    )
    sys_call("rsync", args)
  }
  rsync_from_pod <- function(remote_path, local_path) {
    args <- c(
      "-rltD", "-z", "--progress",
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

  # ---- 2. Translate local emb dirs -> s3:// URIs -----------------------
  # Targets passes corpus_emb_dir as a local filesystem path under
  # `embeddings_local_root` (e.g. .../embeddings/config=SPECTER2_runpod/
  # source=corpus). We translate to the matching R2 prefix; the pod reads
  # parquets from there via duckdb httpfs.
  local_root <- normalizePath(cfg$r2$embeddings_local_root,
                              mustWork = TRUE, winslash = "/")
  to_s3 <- function(local_path) {
    abs_local <- normalizePath(local_path, mustWork = TRUE, winslash = "/")
    if (!startsWith(abs_local, local_root)) {
      stop("emb path ", abs_local,
           " is not under r2.embeddings_local_root ", local_root)
    }
    # Path arithmetic — no regex, avoids POSIX-bracket-class gotchas with
    # punctuation in the prefix.
    rel <- substring(abs_local, nchar(local_root) + 1L)
    rel <- sub("^/+", "", rel)
    sprintf("s3://%s/%s/%s",
            cfg$r2$bucket, cfg$r2$embeddings_remote_prefix, rel)
  }
  s3_corpus_dir <- to_s3(corpus_emb_dir)
  s3_ref_dir    <- to_s3(reference_emb_dir)
  message(sprintf("[bertopic_runpod|%s] corpus    -> %s", run_name, s3_corpus_dir))
  message(sprintf("[bertopic_runpod|%s] reference -> %s", run_name, s3_ref_dir))

  # ---- 3. Prepare remote workdir (only out + cfg, no input upload) -----
  remote_root <- cfg$remote_workdir
  remote_out  <- file.path(remote_root, "out")
  remote_cfg  <- file.path(remote_root, sprintf("bertopic_cfg_%s.yaml", run_name))
  ssh_cmd(sprintf("mkdir -p %s && touch %s/.heartbeat",
                  shQuote(remote_out), shQuote(remote_root)))

  # ---- 4. Push the per-run cfg yaml (no secrets — pod has them in env) -
  # Strip cfg$r2's keyring entry names; the pod doesn't use them. Endpoint,
  # bucket, region stay so the Python script can configure duckdb httpfs.
  cfg_for_pod      <- cfg
  cfg_for_pod$r2   <- cfg$r2[c("endpoint", "bucket", "region")]
  cfg_local <- tempfile(pattern = "bertopic_cfg_", fileext = ".yaml")
  on.exit(unlink(cfg_local), add = TRUE)
  yaml::write_yaml(cfg_for_pod, cfg_local)
  rsync_to_pod(cfg_local, remote_cfg)

  # ---- 6. Trigger the GPU script on the pod ----------------------------
  # R2 credentials come from RunPod Secrets set on the pod template
  # (R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY). The wrapper does NOT pass
  # them — they live encrypted at rest on RunPod's side and are exposed
  # to the pod as env vars at boot.
  #
  # NOTE: non-interactive sshd sessions don't inherit the container's
  # init env, so the Secrets aren't visible to the Python script by
  # default. We pull them off /proc/1/environ (the entrypoint's env,
  # which DOES have them) and export them before invoking python. The
  # v0.1.4 image will fix this at the image level by writing the env to
  # /etc/environment in the entrypoint.
  remote_cmd <- sprintf(
    paste0(
      "set -euo pipefail; touch %s/.heartbeat; ",
      # Make `python` resolve in non-interactive shells. RAPIDS base puts
      # python under /opt/conda/bin which isn't on the default SSH PATH.
      # No-op if already symlinked. Drop once v0.1.4 bakes this in.
      "[ -x /usr/local/bin/python ] || ln -sf /opt/conda/bin/python /usr/local/bin/python; ",
      # Export the entrypoint's env (R2_*, RUNPOD_API_KEY, etc.) into this shell.
      "set -a; ",
      "while IFS='=' read -r -d '' k v; do ",
      "  case \"$k\" in ",
      "    R2_*|RUNPOD_*|PUBLIC_KEY|IDLE_MIN) export \"$k=$v\" ;; ",
      "  esac; ",
      "done < /proc/1/environ; ",
      "set +a; ",
      # Sanity: bail before the long run if creds are missing.
      "[ -n \"${R2_ACCESS_KEY_ID:-}\" ] || { echo 'R2_ACCESS_KEY_ID missing in /proc/1/environ' >&2; exit 2; }; ",
      "[ -n \"${R2_SECRET_ACCESS_KEY:-}\" ] || { echo 'R2_SECRET_ACCESS_KEY missing' >&2; exit 2; }; ",
      # Then dispatch the GPU script.
      "python /opt/run_bertopic_gpu.py %s %s %s %s %s"
    ),
    shQuote(remote_root),
    sprintf("--corpus-emb-dir %s",    shQuote(s3_corpus_dir)),
    sprintf("--reference-emb-dir %s", shQuote(s3_ref_dir)),
    sprintf("--output-dir %s",        shQuote(remote_out)),
    sprintf("--bertopic-cfg-yaml %s", shQuote(remote_cfg)),
    sprintf("--run-name %s",          shQuote(run_name))
  )
  message(sprintf("[bertopic_runpod|%s] running GPU script on the pod (may take 1–3 h)",
                  run_name))
  ssh_cmd(remote_cmd)

  # ---- 7. Download results --------------------------------------------
  remote_leaf <- file.path(
    remote_out,
    paste0("config=",   config_name),
    paste0("bertopic=", run_name),
    paste0("variant=",  primary)
  )
  message(sprintf("[bertopic_runpod|%s] downloading topic parquets", run_name))
  rsync_from_pod(paste0(remote_leaf, "/"),
                 paste0(leaf_dir, "/"))

  # ---- 8. Validate + stamp marker -------------------------------------
  expected <- c("topic_info.parquet", "topics.parquet", "topic_words.parquet")
  missing  <- expected[!file.exists(file.path(leaf_dir, expected))]
  if (length(missing)) {
    stop("Expected outputs missing in local leaf ", leaf_dir, ": ",
         paste(missing, collapse = ", "))
  }
  write_topics_marker(leaf_dir, run_name, current_cfg_hash)

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
