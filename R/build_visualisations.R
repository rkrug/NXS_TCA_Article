# Report visualisation helpers (trimmed).
#
# This file was reduced to only the functions still used after the pipeline was
# pruned to the TCA Approaches x TCA Actions combined heatmap:
#   * the shared figure-I/O helpers, which R/build_linkage.R calls, and
#   * the keypaper self-similarity ("keypaper coherence") builders, kept by the
#     Chapter Analysis report.
# The ~60 score/chapter/embedding-QC/topic builders that backed the removed
# targets were deleted along with those targets.

# ---- shared helpers --------------------------------------------------------

ensure_figures_dir <- function(dir = "output/figures") {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  dir
}

# Writes the figure as PNG (raster preview), SVG and PDF. `units` is passed
# straight to ggsave, so callers targeting a journal spec can give the size in
# "mm" rather than converting to inches. `eps = TRUE` adds an EPS for
# manuscript submission -- opt-in, because EPS cannot express transparency and
# silently drops it, which matters only for the one figure actually being
# submitted (supporting-information figures are not typeset).
save_ggplot_fig <- function(
  p,
  name,
  dir = "output/figures",
  width = 10,
  height = 6,
  units = "in",
  dpi = 120,
  eps = FALSE
) {
  ensure_figures_dir(dir)
  path_png <- file.path(dir, paste0(name, ".png"))
  ggplot2::ggsave(
    path_png, plot = p,
    width = width, height = height, units = units, dpi = dpi
  )
  path_svg <- file.path(dir, paste0(name, ".svg"))
  ggplot2::ggsave(
    path_svg, plot = p, width = width, height = height, units = units
  )
  path_pdf <- file.path(dir, paste0(name, ".pdf"))
  ggplot2::ggsave(
    path_pdf, plot = p, width = width, height = height, units = units
  )
  # PLOS accepts "TIFF or EPS only" for submission. EPS is preferred over TIFF
  # here because R's quartz TIFF device on this machine supports neither the
  # LZW compression PLOS requires nor a flattened no-alpha-channel output,
  # whereas EPS is vector and has neither concern.
  if (isTRUE(eps)) {
    path_eps <- file.path(dir, paste0(name, ".eps"))
    ggplot2::ggsave(
      path_eps, plot = p, width = width, height = height, units = units
    )
  }
  invisible(path_png)
}

save_widget_html <- function(w, name, dir = "output/figures") {
  ensure_figures_dir(dir)
  path <- file.path(dir, paste0(name, ".html"))
  # selfcontained = TRUE embeds JS/CSS so the file works standalone in Finder.
  htmlwidgets::saveWidget(w, path, selfcontained = TRUE)
  invisible(path)
}

# output/figures/ is not tracked in git (see .gitignore), so a report that
# links straight there would 404 once distributed. Called from the
# report_* copy targets in _targets.R, once per report, after its render:
# copies whichever export formats exist for each figure `name` alongside
# the report's own tracked copy in output/reports/.
copy_report_figures <- function(
  names,
  src_dir = "output/figures",
  dest_dir = "output/reports/figures"
) {
  dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
  exts <- c("png", "svg", "pdf", "eps")
  srcs <- file.path(src_dir, outer(names, exts, function(n, e) paste0(n, ".", e)))
  srcs <- srcs[file.exists(srcs)]
  dests <- file.path(dest_dir, basename(srcs))
  ok <- file.copy(srcs, dests, overwrite = TRUE)
  if (!all(ok)) {
    stop("Could not copy: ", paste(srcs[!ok], collapse = ", "))
  }
  dests
}

# A "Download: PNG | SVG | PDF | EPS" markdown line for whichever formats
# save_ggplot_fig() actually wrote for `name`. Existence is checked against
# src_dir (output/figures/, populated by the viz_*_fig target at render
# time); the emitted links point at link_dir because copy_report_figures()
# lands the same files there, alongside the rendered report itself.
fig_download_links_md <- function(
  name,
  src_dir = "output/figures",
  link_dir = "figures"
) {
  exts <- c(PNG = "png", SVG = "svg", PDF = "pdf", EPS = "eps")
  present <- exts[file.exists(file.path(src_dir, paste0(name, ".", exts)))]
  if (length(present) == 0) {
    return("")
  }
  links <- sprintf(
    "[%s](%s)", names(present), file.path(link_dir, paste0(name, ".", present))
  )
  paste0("**Download:** ", paste(links, collapse = " · "))
}

# ---- keypaper coherence (self-similarity heatmap) --------------------------

build_viz_keypaper_self_sim_data <- function(
  emb_keypapers_title_abstract,
  key_works
) {
  emb <- arrow::open_dataset(emb_keypapers_title_abstract) |>
    dplyr::select(id, dplyr::starts_with("V")) |>
    dplyr::collect()

  # Restrict to the CURRENT definition set. embed_works() never removes rows
  # for definitions that have since been dropped from the source xlsx (its
  # skip-guard only compares the leaf's row count against its own completion
  # marker), so the embedding store accumulates orphans -- without this the
  # heatmap plots definitions that are no longer part of the key set.
  current_ids <- arrow::open_dataset(key_works) |>
    dplyr::select(id) |>
    dplyr::collect()
  n_before <- nrow(emb)
  emb <- emb[emb$id %in% current_ids$id, , drop = FALSE]
  if (nrow(emb) < n_before) {
    message(sprintf(
      paste0(
        "[keypaper_self_sim] %d of %d embedded rows are not in the current ",
        "key set -- dropped (stale embeddings from a previous definition set)."
      ),
      n_before - nrow(emb), n_before
    ))
  }

  vcols <- grep("^V[0-9]+$", names(emb), value = TRUE)
  vcols <- vcols[order(as.integer(sub("^V", "", vcols)))]
  M <- as.matrix(emb[, vcols, drop = FALSE])
  norms <- sqrt(rowSums(M * M))
  norms[norms == 0] <- 1
  M <- M / norms
  sims <- M %*% t(M)
  # Cosine similarity is bounded by [-1, 1], but the matrix product overshoots
  # slightly on the diagonal (1.0000000000000022). Those values fall outside
  # the fill scale's limits and render as grey NA cells, so clamp away the
  # floating-point excess.
  sims <- pmin(pmax(sims, -1), 1)
  # Hierarchical clustering order so block structure pops on the heatmap
  ord <- stats::hclust(stats::as.dist(1 - sims), method = "average")$order
  ids_ordered <- emb$id[ord]
  rownames(sims) <- emb$id
  colnames(sims) <- emb$id

  # Long form, with id factor levels in cluster order
  long <- tibble::as_tibble(as.data.frame.table(
    sims,
    responseName = "sim",
    stringsAsFactors = FALSE
  )) |>
    dplyr::rename(id_a = Var1, id_b = Var2) |>
    dplyr::mutate(
      id_a = factor(id_a, levels = ids_ordered),
      id_b = factor(id_b, levels = ids_ordered),
      sim = as.numeric(sim)
    )
  long
}

build_viz_keypaper_self_sim_fig <- function(
  self_sim_data,
  figures_dir = "output/figures"
) {
  p <- ggplot2::ggplot(
    self_sim_data,
    ggplot2::aes(x = id_a, y = id_b, fill = sim)
  ) +
    ggplot2::geom_tile() +
    ggplot2::scale_fill_viridis_c(
      name = "Cosine\nsimilarity",
      limits = c(-0.05, 1)
    ) +
    ggplot2::coord_fixed() +
    ggplot2::labs(x = NULL, y = NULL) +
    ggplot2::theme_minimal(base_size = 10) +
    ggplot2::theme(
      axis.text.x = ggplot2::element_blank(),
      axis.text.y = ggplot2::element_blank(),
      axis.ticks = ggplot2::element_blank(),
      panel.grid = ggplot2::element_blank()
    )
  save_ggplot_fig(p, "keypaper_self_sim", figures_dir, width = 7, height = 6.5)
  p
}
