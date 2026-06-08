# Vectorisation report visualisations.
#
# Every figure target builds the R object (cached via qs2) AND writes a
# static artifact to output/figures/ for quick browser/Preview viewing.
# The QMD pulls everything via tar_read() and prints — no per-chunk
# computation in the report.

# ---- shared helpers --------------------------------------------------------

wrap_for_hover <- function(x, width = 70) {
  vapply(
    x,
    function(s) {
      if (is.na(s) || !nzchar(s)) return("")
      paste(
        unlist(strsplit(stringr::str_wrap(s, width = width), "\n", fixed = TRUE)),
        collapse = "<br>"
      )
    },
    character(1),
    USE.NAMES = FALSE
  )
}

ensure_figures_dir <- function(dir = "output/figures") {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  dir
}

save_ggplot_png <- function(p, name, dir = "output/figures",
                            width = 10, height = 6, dpi = 120) {
  ensure_figures_dir(dir)
  path <- file.path(dir, paste0(name, ".png"))
  ggplot2::ggsave(path, plot = p, width = width, height = height, dpi = dpi)
  invisible(path)
}

save_widget_html <- function(w, name, dir = "output/figures") {
  ensure_figures_dir(dir)
  path <- file.path(dir, paste0(name, ".html"))
  # selfcontained = TRUE embeds JS/CSS so the file works standalone in Finder.
  htmlwidgets::saveWidget(w, path, selfcontained = TRUE)
  invisible(path)
}

# ---- raw data loaders (small, cheap, called by figure builders) ------------

read_embeddings <- function(config_dir) {
  # config_dir = .../embeddings/config=<X>/ — read every (source, variant)
  # partition underneath.
  arrow::open_dataset(config_dir) |> dplyr::collect()
}

read_scores_long <- function(scores_tcac20_title_abstract) {
  arrow::open_dataset(file.path(scores_tcac20_title_abstract, "..", "..")) |>
    dplyr::collect() |>
    tidyr::pivot_longer(
      cols = dplyr::starts_with("https://"),
      names_to = "ref_id",
      values_to = "score"
    )
}

# ---- 1. Run-metadata table -------------------------------------------------

viz_metadata_table <- function(embeddings) {
  embeddings |>
    dplyr::count(source, variant) |>
    tidyr::pivot_wider(names_from = variant, values_from = n, values_fill = 0L) |>
    dplyr::arrange(source)
}

# ---- 2. Score distribution -------------------------------------------------

viz_score_summary <- function(scores_long) {
  scores_long |>
    dplyr::summarise(
      n    = dplyr::n(),
      min  = min(score, na.rm = TRUE),
      mean = mean(score, na.rm = TRUE),
      max  = max(score, na.rm = TRUE),
      p10  = stats::quantile(score, 0.10, na.rm = TRUE),
      p50  = stats::quantile(score, 0.50, na.rm = TRUE),
      p90  = stats::quantile(score, 0.90, na.rm = TRUE),
      p99  = stats::quantile(score, 0.99, na.rm = TRUE),
      .by  = variant
    )
}

viz_score_quantiles <- function(scores_long) {
  scores_long |>
    dplyr::summarise(
      p10 = stats::quantile(score, 0.10),
      p50 = stats::median(score),
      p90 = stats::quantile(score, 0.90),
      p99 = stats::quantile(score, 0.99),
      .by = variant
    )
}

viz_score_dist_fig <- function(scores_long, figures_dir = "output/figures") {
  p <- ggplot2::ggplot(
    scores_long,
    ggplot2::aes(x = score, fill = variant)
  ) +
    ggplot2::geom_density(alpha = 0.4) +
    ggplot2::geom_vline(
      ggplot2::aes(xintercept = mean(score)),
      color = "blue", linetype = "dashed"
    ) +
    ggplot2::theme_minimal(base_size = 12)
  save_ggplot_png(p, "score_dist", figures_dir)
  p
}

# ---- 3. Top / bottom matches ----------------------------------------------

viz_top_bottom_tables <- function(embeddings, scores_tcac20_title_abstract,
                                  n = 10) {
  scores <- arrow::open_dataset(
    file.path(scores_tcac20_title_abstract, "..", "..")
  ) |>
    dplyr::collect()

  text_lookup <- embeddings |>
    dplyr::filter(source == "corpus") |>
    dplyr::select(id, variant, title_clean) |>
    dplyr::distinct(id, variant, .keep_all = TRUE)

  variants <- embeddings |> dplyr::distinct(variant) |> dplyr::pull()

  build_one <- function(v) {
    s <- scores |>
      dplyr::filter(variant == v) |>
      dplyr::rowwise() |>
      dplyr::mutate(
        max_sim = max(dplyr::c_across(dplyr::starts_with("https://")), na.rm = TRUE)
      ) |>
      dplyr::ungroup()

    txt <- text_lookup |>
      dplyr::filter(variant == v) |>
      dplyr::select(id, title_clean)

    joined <- dplyr::left_join(s, txt, by = "id") |>
      dplyr::arrange(dplyr::desc(max_sim))

    dplyr::bind_rows(
      utils::head(joined, n) |>
        dplyr::mutate(rank = paste0("top ", seq_len(dplyr::n()))),
      utils::tail(joined, n) |>
        dplyr::mutate(rank = paste0("bottom ", seq_len(dplyr::n())))
    ) |>
      dplyr::transmute(rank, max_sim = round(max_sim, 3), title_clean)
  }

  stats::setNames(lapply(variants, build_one), variants)
}

# ---- 4. Variant-agreement plotly -------------------------------------------

viz_variant_agree_data <- function(scores_long) {
  per_work <- scores_long |>
    dplyr::summarise(max_sim = max(score, na.rm = TRUE), .by = c(id, variant)) |>
    tidyr::pivot_wider(names_from = variant, values_from = max_sim)

  dplyr::bind_rows(
    per_work |>
      dplyr::transmute(id, pair = "title vs abstract",
                       x = title, y = abstract),
    per_work |>
      dplyr::transmute(id, pair = "title vs title_abstract",
                       x = title, y = title_abstract),
    per_work |>
      dplyr::transmute(id, pair = "abstract vs title_abstract",
                       x = abstract, y = title_abstract)
  )
}

viz_variant_agree_fig <- function(agree_data, figures_dir = "output/figures") {
  sd <- crosstalk::SharedData$new(
    agree_data, key = ~id, group = "variant_agreement"
  )
  fig <- plotly::plot_ly(
    sd,
    x = ~x, y = ~y, color = ~pair,
    colors = c("#E41A1C", "#377EB8", "#4DAF4A"),
    symbol = ~pair,
    symbols = c("circle", "triangle-up", "square"),
    text = ~paste0(pair, "<br>", id),
    hoverinfo = "text",
    type = "scattergl", mode = "markers",
    marker = list(
      size = 6, opacity = 0.4,
      line = list(width = 1, color = "rgba(40,40,40,0.9)")
    )
  ) |>
    plotly::layout(
      xaxis = list(title = "max similarity (first variant)", range = c(0, 1)),
      yaxis = list(title = "max similarity (second variant)", range = c(0, 1)),
      shapes = list(list(
        type = "line", x0 = 0, x1 = 1, y0 = 0, y1 = 1,
        xref = "x", yref = "y",
        line = list(color = "gray", dash = "dash", width = 1)
      )),
      legend = list(orientation = "h", x = 0, y = -0.2)
    ) |>
    plotly::highlight(
      on = "plotly_click",
      off = "plotly_doubleclick",
      selected = plotly::attrs_selected(
        marker = list(opacity = 1, size = 10),
        showlegend = FALSE
      ),
      opacityDim = 0.15,
      selectize = TRUE,
      persistent = FALSE
    )
  save_widget_html(fig, "variant_agree", figures_dir)
  fig
}

# ---- 5. Threshold sweep ----------------------------------------------------

viz_threshold_fig <- function(scores_long, figures_dir = "output/figures") {
  work_max <- scores_long |>
    dplyr::summarise(max_sim = max(score, na.rm = TRUE), .by = c(id, variant))

  thresholds <- seq(0, 1, by = 0.01)
  sweep <- work_max |>
    dplyr::group_by(variant) |>
    dplyr::reframe(
      threshold = thresholds,
      n_above   = vapply(thresholds, function(t) sum(max_sim >= t), integer(1))
    )

  x_zoom_min <- min(work_max$max_sim, na.rm = TRUE) - 0.01

  p <- ggplot2::ggplot(
    sweep, ggplot2::aes(threshold, n_above, colour = variant)
  ) +
    ggplot2::geom_line(linewidth = 1) +
    ggplot2::scale_x_continuous(limits = c(x_zoom_min, 1)) +
    ggplot2::scale_y_log10() +
    ggplot2::scale_colour_manual(
      values = c("#E41A1C", "#377EB8", "#4DAF4A")
    ) +
    ggplot2::labs(
      x = "Cosine threshold",
      y = "Works above threshold (log)",
      colour = NULL
    ) +
    ggplot2::theme_minimal(base_size = 12) +
    ggplot2::theme(legend.position = "bottom")
  save_ggplot_png(p, "threshold_sweep", figures_dir)
  p
}

# ---- 6. UMAP coords (used by both interactive UMAP and topics UMAP) --------

viz_umap_coords <- function(embeddings, variant = "title_abstract", seed = 13L) {
  emb <- embeddings |>
    dplyr::filter(variant == !!variant) |>
    dplyr::select(id, source, dplyr::starts_with("V"))
  vcols <- grep("^V[0-9]+$", names(emb), value = TRUE)
  vcols <- vcols[order(as.integer(sub("^V", "", vcols)))]
  M <- as.matrix(emb[, vcols, drop = FALSE])
  set.seed(seed)
  u <- uwot::umap(M, n_neighbors = 15, min_dist = 0.1, metric = "cosine")
  tibble::tibble(
    id = emb$id, source = emb$source,
    x  = u[, 1], y = u[, 2]
  )
}

# ---- 7. Interactive UMAP --------------------------------------------------

viz_umap_data <- function(umap_coords, embeddings, scores_long,
                          corpus_tcac20, key_works,
                          variant = "title_abstract") {
  max_sim_per_id <- scores_long |>
    dplyr::filter(variant == !!variant) |>
    dplyr::summarise(max_sim = max(score, na.rm = TRUE), .by = id)

  title_per_id <- embeddings |>
    dplyr::filter(variant == "title") |>
    dplyr::select(id, title_clean) |>
    dplyr::distinct(id, .keep_all = TRUE)

  citation_per_id <- dplyr::bind_rows(
    arrow::open_dataset(corpus_tcac20) |>
      dplyr::select(id, citation) |>
      dplyr::collect(),
    arrow::open_dataset(key_works) |>
      dplyr::select(id, citation) |>
      dplyr::collect()
  ) |>
    dplyr::distinct(id, .keep_all = TRUE)

  emb_corpus <- umap_coords |>
    dplyr::filter(source == "corpus") |>
    dplyr::left_join(max_sim_per_id,  by = "id") |>
    dplyr::left_join(title_per_id,    by = "id") |>
    dplyr::left_join(citation_per_id, by = "id") |>
    dplyr::mutate(
      max_sim_pctl  = dplyr::percent_rank(max_sim),
      title_wrap    = wrap_for_hover(title_clean, 70),
      citation_wrap = wrap_for_hover(citation,    70)
    )

  emb_keypaper_base <- umap_coords |>
    dplyr::filter(source == "keypaper") |>
    dplyr::left_join(title_per_id,    by = "id") |>
    dplyr::left_join(citation_per_id, by = "id") |>
    dplyr::mutate(
      title_wrap    = wrap_for_hover(title_clean, 70),
      citation_wrap = wrap_for_hover(citation,    70)
    )

  list(
    emb_corpus = emb_corpus,
    emb_keypaper_base = emb_keypaper_base
  )
}

viz_umap_best_kp <- function(umap_data, scores_tcac20_title_abstract,
                             variant = "title_abstract") {
  scores <- arrow::open_dataset(
    file.path(scores_tcac20_title_abstract, "..", "..")
  ) |> dplyr::collect()
  scores_v <- scores |> dplyr::filter(variant == !!variant)
  ref_cols <- grep("^https://", names(scores_v), value = TRUE)
  mtx <- as.matrix(scores_v[, ref_cols])
  best_idx <- max.col(mtx, ties.method = "first")

  ec <- umap_data$emb_corpus
  ek <- umap_data$emb_keypaper_base

  tibble::tibble(
    corpus_id = scores_v$id,
    kp_id     = ref_cols[best_idx]
  ) |>
    dplyr::left_join(
      ec |> dplyr::select(corpus_id = id, corpus_x = x, corpus_y = y),
      by = "corpus_id"
    ) |>
    dplyr::left_join(
      ek |> dplyr::select(kp_id = id, kp_x = x, kp_y = y),
      by = "kp_id"
    )
}

viz_umap_keypaper <- function(umap_data, best_kp_df) {
  umap_data$emb_keypaper_base |>
    dplyr::left_join(
      best_kp_df |> dplyr::count(kp_id, name = "n_corpus"),
      by = c("id" = "kp_id")
    ) |>
    dplyr::mutate(
      n_corpus    = tidyr::replace_na(n_corpus, 0L),
      marker_size = 6 + 20 * sqrt(n_corpus) / max(sqrt(max(n_corpus, 1L)), 1)
    )
}

viz_umap_work_max <- function(scores_long) {
  scores_long |>
    dplyr::summarise(work_max_sim = max(score, na.rm = TRUE), .by = id) |>
    dplyr::arrange(id)
}

viz_umap_contour <- function(umap_coords, emb_corpus, grid_n = 60L) {
  grid_x <- seq(min(umap_coords$x), max(umap_coords$x), length.out = grid_n)
  grid_y <- seq(min(umap_coords$y), max(umap_coords$y), length.out = grid_n)
  grid_df <- expand.grid(x = grid_x, y = grid_y)
  fit <- stats::loess(max_sim ~ x + y, data = emb_corpus, span = 0.5)
  grid_df$z <- as.numeric(stats::predict(fit, newdata = grid_df))
  list(
    x = grid_x, y = grid_y,
    z = matrix(grid_df$z, nrow = grid_n, ncol = grid_n, byrow = TRUE)
  )
}

viz_umap_fig <- function(emb_corpus, emb_keypaper, contour, best_kp_df,
                        work_max, figures_dir = "output/figures") {
  sd_corpus <- crosstalk::SharedData$new(
    emb_corpus, key = ~id, group = "tcac20_works"
  )
  sd_keypaper <- crosstalk::SharedData$new(
    emb_keypaper, key = ~id, group = "tcac20_works"
  )

  best_kp_json  <- jsonlite::toJSON(
    best_kp_df, dataframe = "rows", auto_unbox = TRUE
  )
  work_max_json <- jsonlite::toJSON(
    work_max, dataframe = "rows", auto_unbox = TRUE
  )

  on_render <- sprintf(
    "
    function(el, x) {
      window._tcacUmapEl = el;
      var bestKpArr  = %s;
      var workMaxArr = %s;
      var bestKp = {}, kpToCorpus = {};
      bestKpArr.forEach(function (r) {
        bestKp[r.corpus_id] = r;
        if (!kpToCorpus[r.kp_id]) kpToCorpus[r.kp_id] = [];
        kpToCorpus[r.kp_id].push(r);
      });
      var workMax = {};
      workMaxArr.forEach(function (r) { workMax[r.id] = r.work_max_sim; });
      var handle = new crosstalk.SelectionHandle('tcac20_works');
      window.tcacSetCluster = function (kpId) {
        var cluster = kpToCorpus[kpId] || [];
        if (!cluster.length) { handle.clear(); Plotly.relayout(el, { shapes: [] }); return; }
        var keys = [kpId].concat(cluster.map(function (c) { return c.corpus_id; }));
        handle.set(keys);
        var shapes = cluster.map(function (c) {
          return { type: 'line',
                   x0: c.corpus_x, y0: c.corpus_y,
                   x1: c.kp_x,     y1: c.kp_y,
                   xref: 'x', yref: 'y',
                   line: { color: 'rgba(255,0,0,0.35)', width: 0.8 } };
        });
        Plotly.relayout(el, { shapes: shapes });
      };
      window.tcacSetThreshold = function (t) {
        Plotly.relayout(el, { shapes: [] });
        if (t <= 0) { handle.clear(); return; }
        var keys = Object.keys(workMax).filter(function (id) { return workMax[id] >= t; });
        handle.set(keys);
      };
      el.on('plotly_click', function (d) {
        var p = d.points[0];
        var id = p.customdata;
        if (p.data.name === 'keypaper') { window.tcacSetCluster(id); }
        else if (p.data.name === 'corpus') {
          var info = bestKp[id]; if (info) window.tcacSetCluster(info.kp_id);
        }
      });
    }",
    best_kp_json, work_max_json
  )

  fig <- plotly::plot_ly() |>
    plotly::add_trace(
      type = "contour",
      x = contour$x, y = contour$y, z = contour$z,
      colorscale = "Viridis", opacity = 0.35, showscale = FALSE,
      contours = list(coloring = "heatmap", showlines = FALSE),
      hoverinfo = "skip", name = "contour"
    ) |>
    plotly::add_markers(
      data = sd_corpus, x = ~x, y = ~y,
      text = ~paste0(
        "<b>", citation_wrap, "</b><br><br>",
        title_wrap,
        "<br><br>Max similarity to keypapers: ", sprintf("%.3f", max_sim)
      ),
      customdata = ~id, hoverinfo = "text",
      hoverlabel = list(align = "left", namelength = -1),
      color = ~max_sim, colors = viridisLite::viridis(256),
      marker = list(
        size = 5, opacity = 0.7,
        colorbar = list(
          title = "Max similarity",
          len = 0.6, y = 0.5, yanchor = "middle",
          x = 1.05, thickness = 12
        )
      ),
      name = "corpus"
    ) |>
    plotly::add_markers(
      data = sd_keypaper, x = ~x, y = ~y,
      text = ~paste0(
        "<b>", citation_wrap, "</b><br><br>",
        title_wrap, "<br><br>", n_corpus, " corpus matches"
      ),
      customdata = ~id, hoverinfo = "text",
      hoverlabel = list(align = "left", namelength = -1),
      marker = list(
        symbol = "triangle-up", color = "red",
        opacity = 0.85, size = ~marker_size, sizemode = "diameter",
        line = list(color = "black", width = 1)
      ),
      name = "keypaper"
    ) |>
    plotly::layout(
      xaxis = list(title = "UMAP 1"),
      yaxis = list(title = "UMAP 2"),
      height = 600,
      margin = list(r = 120),
      legend = list(
        orientation = "h", x = 0, y = -0.12,
        bgcolor = "rgba(255,255,255,0.6)"
      )
    ) |>
    plotly::highlight(
      on = "plotly_selected",
      off = "plotly_doubleclick",
      opacityDim = 0.2
    ) |>
    htmlwidgets::onRender(on_render)

  save_widget_html(fig, "umap_interactive", figures_dir)
  fig
}

# ---- 8. Topics ------------------------------------------------------------

viz_topics_table_data <- function(topics_tcac20, embeddings) {
  topics_dir <- dirname(topics_tcac20)
  topic_info <- arrow::read_parquet(file.path(topics_dir, "topic_info.parquet"))
  topics_df  <- arrow::read_parquet(file.path(topics_dir, "topics.parquet"))

  sample_titles_per_topic <- topics_df |>
    dplyr::filter(source == "corpus") |>
    dplyr::left_join(
      embeddings |>
        dplyr::filter(variant == "title") |>
        dplyr::select(id, title_clean) |>
        dplyr::distinct(id, .keep_all = TRUE),
      by = "id"
    ) |>
    dplyr::filter(!is.na(title_clean)) |>
    dplyr::group_by(topic_id) |>
    dplyr::summarise(
      sample_titles = paste(utils::head(title_clean, 3), collapse = "  •  "),
      .groups = "drop"
    )

  topic_info |>
    dplyr::arrange(dplyr::desc(n_keypapers), dplyr::desc(n_corpus)) |>
    dplyr::left_join(sample_titles_per_topic, by = "topic_id") |>
    dplyr::mutate(
      top_words = vapply(top_words, function(x) paste(x, collapse = ", "),
                          character(1))
    ) |>
    dplyr::transmute(
      topic_id, is_relevant, n_keypapers, n_corpus, top_words, sample_titles
    )
}

viz_topics_table <- function(topics_table_data, figures_dir = "output/figures") {
  w <- DT::datatable(
    topics_table_data,
    rownames = FALSE,
    options = list(
      pageLength = 15,
      autoWidth  = TRUE,
      columnDefs = list(list(width = "40%", targets = 4))
    ),
    caption = "Topics ranked by keypaper density. is_relevant = (n_keypapers >= keypaper_threshold)."
  )
  save_widget_html(w, "topics_table", figures_dir)
  w
}

viz_topics_fig <- function(topics_tcac20, emb_corpus, emb_keypaper,
                            figures_dir = "output/figures") {
  topics_dir <- dirname(topics_tcac20)
  topics_df  <- arrow::read_parquet(file.path(topics_dir, "topics.parquet"))
  corpus_topics <- topics_df |> dplyr::filter(source == "corpus")

  corpus_pts <- emb_corpus |>
    dplyr::left_join(
      corpus_topics |> dplyr::select(id, topic_id), by = "id"
    ) |>
    dplyr::mutate(topic_id = factor(topic_id))

  keypaper_topics <- topics_df |> dplyr::filter(source == "keypaper")
  kp_pts <- emb_keypaper |>
    dplyr::left_join(
      keypaper_topics |> dplyr::select(id, topic_id), by = "id"
    ) |>
    dplyr::mutate(topic_id = factor(topic_id))

  # id → topic, topic → [ids] lookups for the click handler.
  # Both corpus and keypaper ids participate so a click highlights everything
  # in the topic regardless of source.
  combined_ids    <- c(corpus_pts$id, kp_pts$id)
  combined_topics <- c(as.character(corpus_pts$topic_id),
                       as.character(kp_pts$topic_id))
  id_to_topic  <- stats::setNames(combined_topics, combined_ids)
  topic_to_ids <- split(combined_ids, combined_topics)
  id_to_topic_json  <- jsonlite::toJSON(as.list(id_to_topic),  auto_unbox = TRUE)
  topic_to_ids_json <- jsonlite::toJSON(topic_to_ids,           auto_unbox = FALSE)

  on_render <- sprintf(
    "
    function(el, x) {
      var idToTopic  = %s;
      var topicToIds = %s;
      var handle = new crosstalk.SelectionHandle('tcac20_topics');
      el.on('plotly_click', function (d) {
        var p = d.points[0];
        var id = p.customdata;
        var t = idToTopic[id];
        if (t === undefined) { handle.clear(); return; }
        var ids = topicToIds[t] || [];
        handle.set(ids);
      });
      // DOM dblclick (capture phase) reliably fires even when plotly's own
      // doubleclick handler (autorange reset) consumes plotly_doubleclick.
      el.addEventListener('dblclick', function () { handle.clear(); }, true);
    }",
    id_to_topic_json, topic_to_ids_json
  )

  sd_corpus_topics <- crosstalk::SharedData$new(
    corpus_pts, key = ~id, group = "tcac20_topics"
  )
  sd_kp_topics <- crosstalk::SharedData$new(
    kp_pts, key = ~id, group = "tcac20_topics"
  )

  fig <- plotly::plot_ly() |>
    plotly::add_markers(
      data = sd_corpus_topics, x = ~x, y = ~y,
      color = ~topic_id,
      colors = viridisLite::turbo(nlevels(corpus_pts$topic_id)),
      text = ~paste0(
        "<b>", citation_wrap, "</b><br><br>",
        title_wrap,
        "<br><br>Topic: ", topic_id,
        "<br>Max similarity to keypapers: ", sprintf("%.3f", max_sim)
      ),
      customdata = ~id, hoverinfo = "text",
      hoverlabel = list(align = "left", namelength = -1),
      marker = list(size = 5, opacity = 0.8,
                     line = list(color = "rgba(40,40,40,0.4)", width = 0.3)),
      showlegend = FALSE,
      name = "corpus"
    ) |>
    plotly::add_markers(
      data = sd_kp_topics, x = ~x, y = ~y,
      text = ~paste0(
        "<b>", citation_wrap, "</b><br><br>",
        title_wrap,
        "<br><br>Topic: ", topic_id,
        "<br>", n_corpus, " corpus matches"
      ),
      customdata = ~id, hoverinfo = "text",
      hoverlabel = list(align = "left", namelength = -1),
      marker = list(
        symbol = "triangle-up", color = "red",
        opacity = 0.9, size = ~marker_size, sizemode = "diameter",
        line = list(color = "black", width = 1)
      ),
      showlegend = FALSE,
      name = "keypaper"
    ) |>
    plotly::layout(
      xaxis = list(title = "UMAP 1"),
      yaxis = list(title = "UMAP 2"),
      height = 600
    ) |>
    plotly::highlight(
      on = "plotly_selected",
      off = "plotly_doubleclick",
      opacityDim = 0.2
    ) |>
    htmlwidgets::onRender(on_render)

  save_widget_html(fig, "umap_topics", figures_dir)
  fig
}
