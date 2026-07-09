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

# Read (id -> keyset, title) for node labelling / keyset attribution.
.keypaper_meta <- function(key_works_dir) {
  arrow::open_dataset(key_works_dir) |>
    dplyr::select(id, keyset, title) |>
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
# keyset), labels nodes by keypaper title, colours by keyset.
build_sankey_fig <- function(edge_data,
                             key_works,
                             value_col,
                             name,
                             source_keyset = "TCA_Actions_Ch5",
                             target_keyset = "Nexus_Response_Options",
                             top_n = 3,
                             figures_dir = "output/figures") {
  meta <- .keypaper_meta(key_works)
  label_of <- stats::setNames(
    ifelse(is.na(meta$title) | !nzchar(meta$title), meta$id,
           substr(meta$title, 1, 60)),
    meta$id
  )

  e <- edge_data[edge_data$keyset_a == source_keyset &
                   edge_data$keyset_b == target_keyset, , drop = FALSE]
  e$value <- as.numeric(e[[value_col]])
  e <- e[is.finite(e$value) & e$value > 0, , drop = FALSE]

  # top_n targets per source node by value
  e <- e[order(e$id_a, -e$value), , drop = FALSE]
  e <- do.call(rbind, lapply(split(e, e$id_a), utils::head, n = top_n))

  if (is.null(e) || !nrow(e)) {
    w <- plotly::plot_ly() |>
      plotly::add_annotations(
        text = paste0("No ", source_keyset, " → ", target_keyset,
                      " links above 0"),
        showarrow = FALSE
      )
    save_widget_html(w, name, figures_dir)
    return(w)
  }

  # Sort by display label (not raw id) so source nodes read alphabetically
  # top-to-bottom. Plotly's default arrangement ("snap") repositions nodes to
  # minimize link crossings and ignores array order entirely, so the sort
  # only takes visual effect when combined with arrangement="fixed" + explicit
  # per-node x/y below.
  src_ids <- unique(e$id_a)
  src_ids <- src_ids[order(unname(label_of[src_ids]))]
  tgt_ids <- unique(e$id_b)
  tgt_ids <- tgt_ids[order(unname(label_of[tgt_ids]))]
  nodes <- c(src_ids, tgt_ids)
  idx <- stats::setNames(seq_along(nodes) - 1L, nodes) # 0-based for plotly
  node_labels <- unname(label_of[nodes])
  node_colors <- c(rep("#2563eb", length(src_ids)),
                   rep("#16a34a", length(tgt_ids)))

  # node.y=0 is the top in plotly's sankey coordinate space; evenly space each
  # column top-to-bottom in the alphabetical order established above.
  y_pos <- function(n) if (n <= 1) 0.5 else seq(0.02, 0.98, length.out = n)
  node_x <- c(rep(0.01, length(src_ids)), rep(0.99, length(tgt_ids)))
  node_y <- c(y_pos(length(src_ids)), y_pos(length(tgt_ids)))

  w <- plotly::plot_ly(
    type = "sankey", orientation = "h", arrangement = "fixed",
    node = list(
      label = node_labels, color = node_colors,
      x = node_x, y = node_y,
      pad = 12, thickness = 16,
      line = list(color = "white", width = 0.5)
    ),
    link = list(
      source = unname(idx[e$id_a]),
      target = unname(idx[e$id_b]),
      value = e$value,
      label = sprintf("%s = %.3f", value_col, e$value)
    )
  ) |>
    plotly::layout(
      title = sprintf("%s → %s (top %d per node, by %s)",
                      source_keyset, target_keyset, top_n, value_col),
      font = list(size = 11)
    )
  save_widget_html(w, name, figures_dir)
  w
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
