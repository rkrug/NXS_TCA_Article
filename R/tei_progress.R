# Background watcher that tails the parquet shard directory embed_corpus
# writes into, and prints elapsed + rate + ETA after each new shard.
#
# Run via callr::r_bg so it doesn't block the foreground embed_corpus call.
# stderr is inherited so message() lines surface in the targets per-target log.

start_shard_watcher <- function(scratch_dir,
                                n_in,
                                batch_size,
                                label,
                                poll_seconds = 10) {
  dir.create(scratch_dir, recursive = TRUE, showWarnings = FALSE)
  callr::r_bg(
    func = function(scratch_dir, n_in, batch_size, label, poll_seconds) {
      n_shards_expected <- max(1L, ceiling(n_in / batch_size))
      t0 <- Sys.time()
      last_count <- 0L
      fmt_dur <- function(s) {
        if (!is.finite(s)) return("?")
        h <- floor(s / 3600)
        m <- floor((s %% 3600) / 60)
        sprintf("%dh%02dm", h, m)
      }
      repeat {
        files <- list.files(
          scratch_dir, pattern = "\\.parquet$", recursive = TRUE
        )
        n_done <- length(files)
        if (n_done != last_count) {
          n_rows_done <- min(n_in, n_done * batch_size)
          elapsed_s <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
          rate <- if (elapsed_s > 0) n_rows_done / elapsed_s else 0
          remaining <- max(0, n_in - n_rows_done)
          eta_s <- if (rate > 0) remaining / rate else NA_real_
          pct <- 100 * n_rows_done / n_in
          message(sprintf(
            "[%s] shard %d/%d | rows %s/%s (%.1f%%) | %.1f rows/s | elapsed %s | ETA %s",
            label, n_done, n_shards_expected,
            format(n_rows_done, big.mark = ","),
            format(n_in,        big.mark = ","),
            pct, rate, fmt_dur(elapsed_s), fmt_dur(eta_s)
          ))
          last_count <- n_done
        }
        Sys.sleep(poll_seconds)
      }
    },
    args = list(
      scratch_dir = scratch_dir,
      n_in = n_in,
      batch_size = batch_size,
      label = label,
      poll_seconds = poll_seconds
    ),
    supervise = TRUE,
    stderr = "2>&1"
  )
}

stop_shard_watcher <- function(handle) {
  if (is.null(handle)) return(invisible(NULL))
  if (inherits(handle, "process") && handle$is_alive()) {
    handle$kill()
  }
  invisible(NULL)
}
