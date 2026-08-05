# Keyset-to-keyset linkage analysis: how the concept definitions (keypapers)
# link to one another, in three stages, and Sankey diagrams built from them.
# Primary interest: TCA Action (keyset TCA_Actions_Ch5) -> Nexus Response
# Option (keyset Nexus_Response_Options).
#
#   Stage 1 — similarity of the definition texts themselves (SPECTER2 keypaper
#             embeddings; cosine).
#   Stage 2 — overlap of the literature each definition CITES (no embeddings;
#             shared cited works / Jaccard on the resolved-citation sets).
#   Stage 3 — similarity of the CITED literature's embeddings (mean pairwise
#             cosine of the two keypapers' cited-work embedding sets).
#
# Each *_data builder returns a long keypaper x keypaper edge list with keyset
# labels attached; build_sankey_fig() renders one directed Sankey for a chosen
# source->target keyset pair (top-N links per source node), and
# build_keyset_matrix_fig() renders the keyset x keyset aggregate heatmap.

# Read (id -> keyset, title, code) for node labelling / keyset attribution.
.keypaper_meta <- function(key_works_dir) {
  arrow::open_dataset(key_works_dir) |>
    dplyr::select(id, keyset, title, code) |>
    dplyr::collect()
}

# Unit-normalise the rows of an embedding matrix (id + V* columns).
.unit_rows <- function(emb) {
  vcols <- grep("^V[0-9]+$", names(emb), value = TRUE)
  vcols <- vcols[order(as.integer(sub("^V", "", vcols)))]
  M <- as.matrix(emb[, vcols, drop = FALSE])
  n <- sqrt(rowSums(M * M))
  n[n == 0] <- 1
  M / n
}

# ---- Stage 1: definition-embedding similarity -----------------------------
build_link_stage1_data <- function(emb_keypapers_title_abstract, key_works) {
  emb <- arrow::open_dataset(emb_keypapers_title_abstract) |>
    dplyr::select(id, dplyr::starts_with("V")) |>
    dplyr::collect()
  M <- .unit_rows(emb)
  sims <- M %*% t(M)
  rownames(sims) <- emb$id
  colnames(sims) <- emb$id

  meta <- .keypaper_meta(key_works)
  ks <- stats::setNames(meta$keyset, meta$id)

  long <- tibble::as_tibble(as.data.frame.table(
    sims, responseName = "sim", stringsAsFactors = FALSE
  )) |>
    dplyr::rename(id_a = Var1, id_b = Var2) |>
    dplyr::mutate(
      sim = as.numeric(sim),
      keyset_a = unname(ks[id_a]),
      keyset_b = unname(ks[id_b])
    ) |>
    dplyr::filter(id_a != id_b)
  long
}

# ---- Stage 2: cited-literature overlap (no embeddings) --------------------
build_link_stage2_data <- function(citations_resolved, key_works) {
  res <- arrow::open_dataset(citations_resolved) |>
    dplyr::filter(!is.na(matched_id)) |>
    dplyr::select(keypaper_id, keyset, matched_id) |>
    dplyr::collect() |>
    dplyr::distinct()

  # cited-work id set per keypaper
  sets <- split(res$matched_id, res$keypaper_id)
  sets <- lapply(sets, unique)
  ids <- names(sets)
  ks <- stats::setNames(res$keyset[!duplicated(res$keypaper_id)],
                        res$keypaper_id[!duplicated(res$keypaper_id)])

  rows <- list()
  for (i in seq_along(ids)) {
    for (j in seq_along(ids)) {
      if (i == j) next
      a <- sets[[i]]
      b <- sets[[j]]
      inter <- length(intersect(a, b))
      if (inter == 0L) next # sparse: only emit edges with ≥1 shared work
      uni <- length(union(a, b))
      rows[[length(rows) + 1]] <- data.frame(
        id_a = ids[i], id_b = ids[j],
        n_shared = inter, jaccard = inter / uni,
        keyset_a = unname(ks[ids[i]]), keyset_b = unname(ks[ids[j]]),
        stringsAsFactors = FALSE
      )
    }
  }
  if (!length(rows)) {
    return(data.frame(
      id_a = character(0), id_b = character(0), n_shared = integer(0),
      jaccard = numeric(0), keyset_a = character(0), keyset_b = character(0),
      stringsAsFactors = FALSE
    ))
  }
  tibble::as_tibble(do.call(rbind, rows))
}

# ---- Stage 3: cited-literature embedding similarity (mean pairwise cosine) -
# Mean pairwise cosine between two keypapers' cited-work embedding sets equals
# the dot product of their centroids-of-unit-vectors (NOT re-normalised):
#   mean_{a in A, b in B} <â, b̂> = <mean_a â, mean_b b̂>.
# So we compute one centroid per keypaper and take pairwise dot products —
# O(n+m) per pair instead of O(n·m).
build_link_stage3_data <- function(citations_resolved,
                                    emb_cited_title_abstract,
                                    key_works) {
  emb <- arrow::open_dataset(emb_cited_title_abstract) |>
    dplyr::select(id, dplyr::starts_with("V")) |>
    dplyr::collect()
  U <- .unit_rows(emb) # unit vectors, rows aligned to emb$id
  rownames(U) <- emb$id

  res <- arrow::open_dataset(citations_resolved) |>
    dplyr::filter(!is.na(matched_id)) |>
    dplyr::select(keypaper_id, keyset, matched_id) |>
    dplyr::collect() |>
    dplyr::distinct()
  # keep only cited works that actually have an embedding
  res <- res[res$matched_id %in% rownames(U), , drop = FALSE]

  sets <- split(res$matched_id, res$keypaper_id)
  sets <- lapply(sets, unique)
  ids <- names(sets)
  ks <- stats::setNames(res$keyset[!duplicated(res$keypaper_id)],
                        res$keypaper_id[!duplicated(res$keypaper_id)])

  # centroid of unit vectors per keypaper
  cent <- t(vapply(ids, function(k) {
    colMeans(U[sets[[k]], , drop = FALSE])
  }, numeric(ncol(U))))
  rownames(cent) <- ids

  sims <- cent %*% t(cent) # mean pairwise cosine
  long <- tibble::as_tibble(as.data.frame.table(
    sims, responseName = "sim", stringsAsFactors = FALSE
  )) |>
    dplyr::rename(id_a = Var1, id_b = Var2) |>
    dplyr::mutate(
      sim = as.numeric(sim),
      n_cited_a = lengths(sets)[id_a],
      n_cited_b = lengths(sets)[id_b],
      keyset_a = unname(ks[id_a]),
      keyset_b = unname(ks[id_b])
    ) |>
    dplyr::filter(id_a != id_b)
  long
}

# ---- Sankey: one directed keyset->keyset diagram --------------------------
# edge_data: long df with id_a/id_b/keyset_a/keyset_b + a numeric value column.
# Keeps the top_n strongest links per source node (source keyset -> target
# keyset), labels nodes by keypaper title, colours by keyset. Built with
# echarts4r (ECharts) rather than plotly: ECharts' sankey series supports
# per-node label position ("left"/"right", rendered outside the node with no
# manual annotation/margin math) and ships built-in hover-adjacency
# highlighting (`emphasis.focus = "adjacency"`) — both were only achievable in
# plotly via hand-rolled paper-coordinate annotations and had no hover
# highlighting equivalent at all.
build_sankey_fig <- function(edge_data,
                             key_works,
                             value_col,
                             name,
                             source_keyset = "TCA_Actions_Ch5",
                             target_keyset = "Nexus_Response_Options",
                             top_n = 3,
                             figures_dir = "output/figures") {
  meta <- .keypaper_meta(key_works)
  title_lbl <- ifelse(is.na(meta$title) | !nzchar(meta$title), meta$id,
                       substr(meta$title, 1, 60))
  # Prepend the code where the keyset has one (e.g. Nexus Response Options'
  # "B01") and it isn't already baked into the title (TCA Actions' titles
  # already start with "Action 1.1: ...").
  has_code <- !is.na(meta$code) & nzchar(meta$code)
  label_of <- stats::setNames(
    ifelse(has_code, paste(meta$code, title_lbl), title_lbl),
    meta$id
  )

  e <- edge_data[edge_data$keyset_a == source_keyset &
                   edge_data$keyset_b == target_keyset, , drop = FALSE]
  e$value <- as.numeric(e[[value_col]])
  e <- e[is.finite(e$value) & e$value > 0, , drop = FALSE]

  # top_n targets per source node by value
  e <- e[order(e$id_a, -e$value), , drop = FALSE]
  e <- do.call(rbind, lapply(split(e, e$id_a), utils::head, n = top_n))
  if (is.null(e)) {
    e <- data.frame(id_a = character(0), id_b = character(0),
                    value = numeric(0))
  }

  # Every Action / Response Option is shown as a node, even ones with no
  # qualifying link (they just end up unconnected) — so the diagram reflects
  # the full keyset, not only the subset that happened to survive top_n.
  # Sort by display label (not raw id) so nodes read alphabetically
  # top-to-bottom; ECharts' `layout="none"` + explicit per-node x/y (below)
  # honours this order exactly (unlike plotly's default "snap" arrangement,
  # which repositions nodes to minimize link crossings and ignores array
  # order).
  src_ids <- meta$id[meta$keyset == source_keyset]
  src_ids <- src_ids[order(unname(label_of[src_ids]))]
  tgt_ids <- meta$id[meta$keyset == target_keyset]
  tgt_ids <- tgt_ids[order(unname(label_of[tgt_ids]))]

  # node.y=0 is the top; evenly space each column top-to-bottom in the
  # alphabetical order established above.
  y_pos <- function(n) if (n <= 1) 0.5 else seq(0.02, 0.98, length.out = n)
  src_y <- y_pos(length(src_ids))
  tgt_y <- y_pos(length(tgt_ids))

  .make_side <- function(ids, y, x, color, side) {
    unname(Map(function(id, yy) {
      full <- unname(label_of[id])
      list(
        name = id, x = x, y = yy,
        itemStyle = list(color = color),
        label = list(
          position = side,
          formatter = htmlwidgets::JS("function(p){return p.data.disp;}")
        ),
        disp = substr(full, 1, 30),
        full = full
      )
    }, ids, y))
  }
  nodes <- c(
    .make_side(src_ids, src_y, 0.05, "#2563eb", "left"),
    .make_side(tgt_ids, tgt_y, 0.95, "#16a34a", "right")
  )

  links <- unname(Map(function(a, b, v) {
    list(source = a, target = b, value = v,
         label_text = sprintf("%s = %.3f", value_col, v))
  }, e$id_a, e$id_b, e$value))

  opt <- list(
    title = list(
      text = sprintf("%s → %s (top %d per node, by %s)",
                      source_keyset, target_keyset, top_n, value_col),
      left = "center", textStyle = list(fontSize = 13)
    ),
    tooltip = list(
      trigger = "item", triggerOn = "mousemove",
      formatter = htmlwidgets::JS(
        "function(p){
           if (p.dataType === 'edge') { return p.data.label_text; }
           return p.data.full;
         }"
      )
    ),
    series = list(list(
      type = "sankey", layout = "none",
      left = "20%", right = "20%", top = "8%", bottom = "2%",
      emphasis = list(focus = "adjacency"),
      data = nodes, links = links,
      label = list(fontSize = 10),
      lineStyle = list(color = "gray", opacity = 0.35, curveness = 0.5),
      nodeWidth = 16, nodeGap = 8
    ))
  )

  w <- echarts4r::e_charts() |> echarts4r::e_list(opt)
  save_widget_html(w, name, figures_dir)
  w
}

# Interpolate a smooth S-curve between (x0,y0) and (x1,y1) — smoothstep easing
# on y so the "ribbon" leaves/arrives roughly horizontal at each node, the
# same visual convention as a real Sankey link (used by build_sankey_fig_ggplot).
.sankey_curve_points <- function(x0, x1, y0, y1, n = 40) {
  t <- seq(0, 1, length.out = n)
  s <- t^2 * (3 - 2 * t) # smoothstep
  data.frame(x = x0 + (x1 - x0) * t, y = y0 + (y1 - y0) * s)
}

# ---- Sankey (static ggplot alternative) -----------------------------------
# Same contract as build_sankey_fig() (identical args, same top_n/all-nodes/
# alphabetical-order semantics) but hand-drawn with ggplot2 instead of
# echarts4r: links are manually interpolated S-curves (geom_path, linewidth ~
# value), nodes are geom_segment ticks, labels are geom_text placed outside
# the plotting area via clip = "off". Static PNG — no hover highlighting,
# but pixel-exact label placement/sizing needs none of the paper-coordinate
# or layout-relaxation workarounds the interactive versions required.
build_sankey_fig_ggplot <- function(edge_data,
                                    key_works,
                                    value_col,
                                    name,
                                    source_keyset = "TCA_Actions_Ch5",
                                    target_keyset = "Nexus_Response_Options",
                                    top_n = 3,
                                    color_by_value = FALSE,
                                    figures_dir = "output/figures") {
  meta <- .keypaper_meta(key_works)
  title_lbl <- ifelse(is.na(meta$title) | !nzchar(meta$title), meta$id,
                       substr(meta$title, 1, 60))
  has_code <- !is.na(meta$code) & nzchar(meta$code)
  label_of <- stats::setNames(
    ifelse(has_code, paste(meta$code, title_lbl), title_lbl),
    meta$id
  )

  e <- edge_data[edge_data$keyset_a == source_keyset &
                   edge_data$keyset_b == target_keyset, , drop = FALSE]
  e$value <- as.numeric(e[[value_col]])
  e <- e[is.finite(e$value) & e$value > 0, , drop = FALSE]
  e <- e[order(e$id_a, -e$value), , drop = FALSE]
  e <- do.call(rbind, lapply(split(e, e$id_a), utils::head, n = top_n))
  if (is.null(e)) {
    e <- data.frame(id_a = character(0), id_b = character(0),
                    value = numeric(0))
  }

  # Every Action / Response Option is a node, linked or not (see
  # build_sankey_fig() for why); ordered alphabetically by display label.
  src_ids <- meta$id[meta$keyset == source_keyset]
  src_ids <- src_ids[order(unname(label_of[src_ids]))]
  tgt_ids <- meta$id[meta$keyset == target_keyset]
  tgt_ids <- tgt_ids[order(unname(label_of[tgt_ids]))]

  # Purely positional y (0 = bottom, 1 = top), independent of link value —
  # ggplot never auto-resizes nodes by throughput the way a "real" Sankey
  # layout engine does, so this needs no layoutIterations-style override.
  y_of <- function(ids) {
    n <- length(ids)
    y <- if (n <= 1) 0.5 else rev(seq(0.02, 0.98, length.out = n))
    stats::setNames(y, ids)
  }
  src_y <- y_of(src_ids)
  tgt_y <- y_of(tgt_ids)

  x_src <- 0
  x_tgt <- 1
  half_h <- 0.35 * min(
    if (length(src_ids) > 1) diff(range(src_y)) / (length(src_ids) - 1) else 1,
    if (length(tgt_ids) > 1) diff(range(tgt_y)) / (length(tgt_ids) - 1) else 1
  )

  nodes <- rbind(
    data.frame(id = src_ids, x = x_src, y = unname(src_y[src_ids]),
              side = "src", stringsAsFactors = FALSE),
    data.frame(id = tgt_ids, x = x_tgt, y = unname(tgt_y[tgt_ids]),
              side = "tgt", stringsAsFactors = FALSE)
  )
  nodes$label_full <- unname(label_of[nodes$id])
  nodes$label_trunc <- substr(nodes$label_full, 1, 30)

  links <- if (nrow(e)) {
    do.call(rbind, lapply(seq_len(nrow(e)), function(i) {
      pts <- .sankey_curve_points(
        x_src, x_tgt, unname(src_y[e$id_a[i]]), unname(tgt_y[e$id_b[i]])
      )
      pts$link_id <- i
      pts$value <- e$value[i]
      pts
    }))
  } else {
    data.frame(x = numeric(0), y = numeric(0), link_id = integer(0),
              value = numeric(0))
  }

  # Nodes are drawn with hardcoded colours (not via an aes colour scale) so the
  # single ggplot colour scale is free for the links when color_by_value=TRUE.
  p <- ggplot2::ggplot()
  if (color_by_value) {
    p <- p +
      ggplot2::geom_path(
        data = links,
        ggplot2::aes(x = x, y = y, group = link_id, linewidth = value,
                    color = value),
        alpha = 0.6, lineend = "round"
      ) +
      ggplot2::scale_color_viridis_c(
        name = value_col,
        guide = ggplot2::guide_colorbar(
          direction = "horizontal", title.position = "top",
          barwidth = grid::unit(6, "cm")
        )
      )
  } else {
    p <- p +
      ggplot2::geom_path(
        data = links,
        ggplot2::aes(x = x, y = y, group = link_id, linewidth = value),
        color = "grey45", alpha = 0.35, lineend = "round"
      )
  }
  p <- p +
    ggplot2::scale_linewidth(range = c(0.15, 2.5), guide = "none") +
    ggplot2::geom_segment(
      data = nodes[nodes$side == "src", ],
      ggplot2::aes(x = x, xend = x, y = y - half_h, yend = y + half_h),
      color = "#2563eb", linewidth = 3.5
    ) +
    ggplot2::geom_segment(
      data = nodes[nodes$side == "tgt", ],
      ggplot2::aes(x = x, xend = x, y = y - half_h, yend = y + half_h),
      color = "#16a34a", linewidth = 3.5
    ) +
    ggplot2::geom_text(
      data = nodes[nodes$side == "src", ],
      ggplot2::aes(x = x - 0.015, y = y, label = label_trunc),
      hjust = 1, size = 2.6
    ) +
    ggplot2::geom_text(
      data = nodes[nodes$side == "tgt", ],
      ggplot2::aes(x = x + 0.015, y = y, label = label_trunc),
      hjust = 0, size = 2.6
    ) +
    ggplot2::coord_cartesian(xlim = c(-0.3, 1.3), clip = "off") +
    ggplot2::labs(
      title = sprintf("%s → %s (top %d per node, by %s)",
                      source_keyset, target_keyset, top_n, value_col)
    ) +
    ggplot2::theme_void(base_size = 11) +
    ggplot2::theme(
      plot.title = ggplot2::element_text(hjust = 0.5),
      plot.margin = ggplot2::margin(t = 15, l = 130, r = 130, b = 5),
      plot.background = ggplot2::element_rect(fill = "white", color = NA),
      panel.background = ggplot2::element_rect(fill = "white", color = NA),
      legend.position = if (color_by_value) "bottom" else "none"
    )

  n_rows <- max(length(src_ids), length(tgt_ids))
  save_ggplot_png(p, name, figures_dir,
                  width = 10, height = max(6, 0.16 * n_rows), dpi = 150)
  p
}

# ---- Keyset x keyset aggregate heatmap ------------------------------------
# Mean of the value column across all keypaper pairs in each keyset pair.
build_keyset_matrix_fig <- function(edge_data, value_col, name,
                                    figures_dir = "output/figures") {
  d <- edge_data
  d$value <- as.numeric(d[[value_col]])
  agg <- d |>
    dplyr::group_by(keyset_a, keyset_b) |>
    dplyr::summarise(mean_value = mean(value, na.rm = TRUE), .groups = "drop")
  p <- ggplot2::ggplot(
    agg, ggplot2::aes(x = keyset_a, y = keyset_b, fill = mean_value)
  ) +
    ggplot2::geom_tile() +
    ggplot2::geom_text(ggplot2::aes(label = sprintf("%.3f", mean_value)),
                       size = 3) +
    ggplot2::scale_fill_viridis_c(name = paste0("mean\n", value_col)) +
    ggplot2::labs(
      x = "keyset (source)", y = "keyset (target)",
      title = paste0("Keyset × keyset mean ", value_col)
    ) +
    ggplot2::theme_minimal(base_size = 10) +
    ggplot2::theme(
      axis.text.x = ggplot2::element_text(angle = 30, hjust = 1),
      panel.grid = ggplot2::element_blank()
    )
  save_ggplot_png(p, name, figures_dir, width = 8, height = 6.5)
  p
}

# ---- Pair-level (keypaper x keypaper) heatmap for one keyset pair ---------
# Every source-keyset x target-keyset keypaper pair (not just the top-N shown
# by the Sankey), plus a "real vs chance" flag: the background/null is the
# empirical distribution of this stage's value across ALL keypaper pairs in
# the whole corpus (edge_data), zero-padded to account for pairs stage 2
# drops (build_link_stage2_data() only emits rows with >=1 shared cited
# work). Shuffling which keypaper carries which vector/cited-set and
# recomputing the pairwise value is equivalent to drawing from that same
# already-materialised population, so this needs no permutation loop.
build_pair_heatmap_data <- function(edge_data, key_works, value_col,
                                    source_keyset, target_keyset) {
  meta <- .keypaper_meta(key_works)
  title_lbl <- ifelse(is.na(meta$title) | !nzchar(meta$title), meta$id,
                       substr(meta$title, 1, 60))
  has_code <- !is.na(meta$code) & nzchar(meta$code)
  label_of <- stats::setNames(
    ifelse(has_code, paste(meta$code, title_lbl), title_lbl),
    meta$id
  )

  # Keypapers with zero data for this stage anywhere (e.g. no resolved
  # citations at all for stage 2/3) never appear in edge_data and are
  # dropped, same convention build_sankey_fig_ggplot() relies on.
  present_ids <- unique(c(edge_data$id_a, edge_data$id_b))
  src_ids <- meta$id[meta$keyset == source_keyset & meta$id %in% present_ids]
  tgt_ids <- meta$id[meta$keyset == target_keyset & meta$id %in% present_ids]

  grid <- expand.grid(id_a = src_ids, id_b = tgt_ids, stringsAsFactors = FALSE)
  observed <- edge_data[edge_data$id_a %in% src_ids &
                           edge_data$id_b %in% tgt_ids,
                        c("id_a", "id_b", value_col)]
  d <- dplyr::left_join(grid, observed, by = c("id_a", "id_b"))
  d[[value_col]][is.na(d[[value_col]])] <- 0

  # Zero-inflation-corrected background: append the pairs stage 2 dropped
  # (value 0) to the observed edge values. No-op for the already-dense
  # stage 1 / stage 3 edge lists (n_missing == 0).
  n_nodes <- length(present_ids)
  bg_raw <- as.numeric(edge_data[[value_col]])
  n_missing <- max(n_nodes * (n_nodes - 1) - length(bg_raw), 0)
  bg <- c(bg_raw, rep(0, n_missing))

  # Mid-rank percentile (mean(bg < v) + 0.5*mean(bg == v)): plain mean(bg<=v)
  # would put every pair at v==0 above the 95th percentile whenever the
  # zero-inflation-corrected background is itself >95% zero (stage 2), since
  # then even a "no overlap" cell counts as "beating" nearly all of bg.
  d$percentile <- vapply(
    d[[value_col]],
    function(v) mean(bg < v) + 0.5 * mean(bg == v),
    numeric(1)
  )
  d$real_diff <- d$percentile >= 0.95
  d$label_a <- unname(label_of[d$id_a])
  d$label_b <- unname(label_of[d$id_b])
  tibble::as_tibble(d)
}

build_pair_heatmap_fig <- function(edge_data, key_works, value_col, name,
                                   source_keyset, target_keyset,
                                   figures_dir = "output/figures") {
  d <- build_pair_heatmap_data(edge_data, key_works, value_col,
                               source_keyset, target_keyset)

  # Cell fill spans the full viridis range even though the underlying values
  # are tightly clustered (e.g. stage 1 sim in [0.86, 0.97]), so dark-purple
  # cells need white text and yellow cells need black text -- a single fixed
  # label colour is unreadable at one end or the other. Map each value
  # through the same viridis palette scale_fill_viridis_c() will use, then
  # pick text colour by the resulting cell's relative luminance.
  pal <- viridisLite::viridis(256)
  idx <- pmax(1, pmin(256, round(scales::rescale(d[[value_col]]) * 255) + 1))
  cell_rgb <- grDevices::col2rgb(pal[idx]) / 255
  luminance <- 0.2126 * cell_rgb["red", ] + 0.7152 * cell_rgb["green", ] +
    0.0722 * cell_rgb["blue", ]
  d$text_color <- ifelse(luminance > 0.5, "black", "white")

  p <- ggplot2::ggplot(
    d, ggplot2::aes(x = label_a, y = label_b, fill = .data[[value_col]])
  ) +
    ggplot2::geom_tile(
      ggplot2::aes(color = real_diff, linewidth = real_diff)
    ) +
    ggplot2::geom_text(
      ggplot2::aes(label = sprintf("%.2f", .data[[value_col]])),
      color = d$text_color, size = 2.3
    ) +
    ggplot2::scale_fill_viridis_c(name = value_col) +
    ggplot2::scale_color_manual(
      values = c(`TRUE` = "black", `FALSE` = NA), guide = "none"
    ) +
    ggplot2::scale_linewidth_manual(
      values = c(`TRUE` = 0.9, `FALSE` = 0.1), guide = "none"
    ) +
    ggplot2::labs(
      x = paste0(source_keyset, " (source)"),
      y = paste0(target_keyset, " (target)"),
      title = paste0(source_keyset, " × ", target_keyset, " — ", value_col),
      subtitle = stringr::str_wrap(paste0(
        "Black border = above the 95th percentile of all corpus-wide ",
        "keypaper pairs for this measure (unlikely by chance); no border = ",
        "indistinguishable from typical background similarity"
      ), width = 85)
    ) +
    ggplot2::theme_minimal(base_size = 9) +
    ggplot2::theme(
      axis.text.x = ggplot2::element_text(angle = 30, hjust = 1),
      panel.grid = ggplot2::element_blank()
    )
  save_ggplot_png(p, name, figures_dir, width = 8, height = 10)
  p
}

# ---- Combined Stage 1 + Stage 2 heatmap (equal-weight blend) --------------
# Stage 3 (cited-literature embedding similarity) is left out: for this pair
# it never clears the 95th-percentile bar and sits in a narrow band, i.e. it
# carries no distinguishing signal here.
build_pair_heatmap_combined_data <- function(link_stage1, link_stage2, key_works,
                                             source_keyset, target_keyset) {
  d1 <- build_pair_heatmap_data(link_stage1, key_works, "sim",
                                source_keyset, target_keyset)
  d2 <- build_pair_heatmap_data(link_stage2, key_works, "jaccard",
                                source_keyset, target_keyset)
  d <- dplyr::inner_join(
    d1[, c("id_a", "id_b", "label_a", "label_b", "sim", "percentile", "real_diff")],
    d2[, c("id_a", "id_b", "jaccard", "percentile", "real_diff")],
    by = c("id_a", "id_b"),
    suffix = c("_stage1", "_stage2")
  )
  # sim (~[0.86, 0.97]) and jaccard ([0, 0.09]) are not on comparable scales,
  # so averaging the raw values would let stage 1 dominate. percentile_* is
  # already each stage's own value expressed as a 0-1 rank against its own
  # corpus-wide background (build_pair_heatmap_data()) -- a common unit -- so
  # the mean of the two percentiles is a genuine equal-weight blend.
  d$combined <- (d$percentile_stage1 + d$percentile_stage2) / 2
  d$n_agree <- d$real_diff_stage1 + d$real_diff_stage2
  d
}

build_pair_heatmap_combined_fig <- function(link_stage1, link_stage2, key_works,
                                            name, source_keyset, target_keyset,
                                            figures_dir = "output/figures") {
  d <- build_pair_heatmap_combined_data(link_stage1, link_stage2, key_works,
                                        source_keyset, target_keyset)

  # Discrete axes need numeric positions so three labels can be placed per
  # tile (center/bottom-left/bottom-right); alphabetical order matches
  # build_pair_heatmap_fig()'s default (ggplot's discrete-axis ordering).
  x_levels <- sort(unique(d$label_a))
  y_levels <- sort(unique(d$label_b))
  d$xn <- match(d$label_a, x_levels)
  d$yn <- match(d$label_b, y_levels)

  # The combined score is a continuous blend, but "at least one stage links
  # this pair" (n_agree >= 1) vs "neither does" (n_agree == 0) is a real
  # split in it: the max combined value among unlinked pairs sits just below
  # the min combined value among linked ones (verified empirically -- the two
  # groups don't interleave, leaving a narrow data-free gap between them).
  # A plain 3-stop diverging gradient wastes most of its visible contrast on
  # that gap, where no cell actually lands, leaving every real cell looking
  # washed-out near-white. Instead build a 4-stop scale whose two middle
  # knots sit exactly at the two group extremes: colour barely changes while
  # scanning across each group's own range (knot 1->2, knot 3->4), then jumps
  # sharply from light-blue to light-red across the knot-2->3 gap that no
  # cell occupies -- so every cell reads clearly as one side or the other.
  none_max <- suppressWarnings(max(d$combined[d$n_agree == 0], na.rm = TRUE))
  linked_min <- suppressWarnings(min(d$combined[d$n_agree >= 1], na.rm = TRUE))
  rng <- range(d$combined, na.rm = TRUE)
  if (is.finite(none_max) && is.finite(linked_min) && none_max < linked_min) {
    knots <- c(rng[1], none_max, linked_min, rng[2])
  } else {
    # No clean split (or only one group present): fall back to a small
    # nominal jump straddling the median instead of a real empirical gap.
    mid <- stats::median(d$combined, na.rm = TRUE)
    gap <- max(diff(rng) * 0.01, .Machine$double.eps)
    knots <- sort(unique(c(
      rng[1], min(mid - gap / 2, rng[2]), max(mid + gap / 2, rng[1]), rng[2]
    )))
  }

  # Reuse the same diverging hues as the Cliff's delta figures
  # (build_viz_chapter_cliffs_delta_fig()) for a consistent visual language,
  # but skip the washed-out white midpoint -- the jump itself marks "no data
  # falls here", so the two inner knots are already light-toned colour, not
  # white.
  div_colors <- c("#2166AC", "#92C5DE", "#F4A582", "#B2182B")
  knot_pos <- scales::rescale(knots)
  pal_fun <- scales::gradient_n_pal(div_colors, values = knot_pos)
  cell_colors <- pal_fun(scales::rescale(d$combined, from = rng))
  cell_rgb <- grDevices::col2rgb(cell_colors) / 255
  luminance <- 0.2126 * cell_rgb["red", ] + 0.7152 * cell_rgb["green", ] +
    0.0722 * cell_rgb["blue", ]
  d$text_color <- ifelse(luminance > 0.5, "black", "white")

  d$agreement <- factor(
    d$n_agree, levels = c(0, 1, 2), labels = c("neither", "one", "both")
  )

  # Bold only the numbers that themselves indicate a real link (above that
  # measure's own 95th percentile); the center combined number bolds
  # whenever either component does, matching when a border is drawn at all.
  fontface_combined <- ifelse(d$n_agree >= 1, "bold", "plain")
  fontface_sim <- ifelse(d$real_diff_stage1, "bold", "plain")
  fontface_jaccard <- ifelse(d$real_diff_stage2, "bold", "plain")

  p <- ggplot2::ggplot(d, ggplot2::aes(x = xn, y = yn)) +
    ggplot2::geom_tile(
      ggplot2::aes(
        fill = combined, color = agreement, linewidth = agreement,
        linetype = agreement
      ),
      width = 1, height = 1
    ) +
    ggplot2::geom_text(
      ggplot2::aes(label = sprintf("%.2f", combined)),
      color = d$text_color, fontface = fontface_combined, size = 3.4
    ) +
    ggplot2::geom_text(
      ggplot2::aes(x = xn - 0.28, y = yn - 0.32, label = sprintf("%.2f", sim)),
      color = d$text_color, fontface = fontface_sim, size = 2
    ) +
    ggplot2::geom_text(
      ggplot2::aes(x = xn + 0.28, y = yn - 0.32, label = sprintf("%.2f", jaccard)),
      color = d$text_color, fontface = fontface_jaccard, size = 2
    ) +
    ggplot2::scale_fill_gradientn(
      name = "combined\n(mean percentile)",
      colours = div_colors, values = knot_pos, limits = rng
    ) +
    # A grey/lighter border reads poorly against the mid-tone viridis fills,
    # so both tiers stay solid black; "one stage only" is distinguished by a
    # dashed rather than solid outline instead of a weaker colour.
    ggplot2::scale_color_manual(
      values = c(neither = NA, one = "black", both = "black"), guide = "none"
    ) +
    ggplot2::scale_linewidth_manual(
      values = c(neither = 0.1, one = 0.6, both = 1.1), guide = "none"
    ) +
    ggplot2::scale_linetype_manual(
      values = c(neither = "solid", one = "dashed", both = "solid"),
      guide = "none"
    ) +
    ggplot2::scale_x_continuous(
      breaks = seq_along(x_levels), labels = x_levels,
      expand = ggplot2::expansion(add = 0.6)
    ) +
    ggplot2::scale_y_continuous(
      breaks = seq_along(y_levels), labels = y_levels,
      expand = ggplot2::expansion(add = 0.6)
    ) +
    ggplot2::labs(
      x = paste0(source_keyset, " (source)"),
      y = paste0(target_keyset, " (target)"),
      title = stringr::str_wrap(paste0(
        source_keyset, " × ", target_keyset,
        " — combined (Stage 1 + Stage 2, equal weight)"
      ), width = 55),
      subtitle = stringr::str_wrap(paste0(
        "Center (large) = mean of each stage's own percentile rank ",
        "(equal-weight blend). Bottom-left (small) = Stage 1 definition-text ",
        "cosine similarity; bottom-right (small) = Stage 2 cited-literature ",
        "Jaccard overlap. Bold = that value is itself above its measure's ",
        "95th percentile (a real link). Solid border = both stages agree; ",
        "dashed border = one stage only; no border = neither. Fill jumps ",
        "sharply from light blue to light red across the gap (",
        sprintf("%.2f", knots[2]), "-", sprintf("%.2f", knots[3]),
        ") that separates \"neither stage links this pair\" (blue) from ",
        "\"at least one does\" (red) -- no cell actually falls in that gap."
      ), width = 85)
    ) +
    ggplot2::theme_minimal(base_size = 9) +
    ggplot2::theme(
      axis.text.x = ggplot2::element_text(angle = 30, hjust = 1),
      panel.grid = ggplot2::element_blank()
    )
  save_ggplot_png(p, name, figures_dir, width = 8, height = 10)
  p
}
