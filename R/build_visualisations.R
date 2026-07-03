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
      if (is.na(s) || !nzchar(s)) {
        return("")
      }
      paste(
        unlist(strsplit(
          stringr::str_wrap(s, width = width),
          "\n",
          fixed = TRUE
        )),
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

save_ggplot_png <- function(
  p,
  name,
  dir = "output/figures",
  width = 10,
  height = 6,
  dpi = 120
) {
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

read_scores_long <- function(
  scores_tcac20_title,
  scores_tcac20_abstract,
  scores_tcac20_title_abstract
) {
  # SLIM long form: one row per (id, variant) with max similarity across
  # all keypaper columns. Replaces the previous full wide->long pivot,
  # which produced ~600M rows (5.77M × 105 keypapers) and OOM'd at full
  # corpus scale. All current consumers only need per-work max — see
  # TODO_Visualisations.md §1.
  #
  # Implementation: a single duckdb query per variant parquet, using
  # GREATEST(col1, col2, ..., colN) over the keypaper score columns.
  # Streams via duckdb — no full matrix lands in R memory.
  #
  # Takes all three variant score paths explicitly (rather than scanning
  # the shared config directory for sibling files) so `targets` sees the
  # real dependency edges — otherwise nothing guarantees
  # scores_tcac20_title/abstract are built before this target runs, and
  # viz_agree_data (which needs all three variants) can silently see a
  # partial result.
  if (
    !requireNamespace("duckdb", quietly = TRUE) ||
      !requireNamespace("DBI", quietly = TRUE)
  ) {
    stop("Packages 'duckdb' and 'DBI' are required for read_scores_long().")
  }
  files <- c(
    scores_tcac20_title,
    scores_tcac20_abstract,
    scores_tcac20_title_abstract
  )

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(
    try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE),
    add = TRUE
  )

  parts <- lapply(files, function(f) {
    # variant=<X> is the parent directory's name
    variant <- sub("^variant=", "", basename(dirname(f)))
    cols <- names(DBI::dbGetQuery(
      con,
      sprintf("SELECT * FROM read_parquet('%s') LIMIT 0", f)
    ))
    # duckdb infers hive-partition columns (config, variant) from the path's
    # key=value segments even for a literal single-file read, not just
    # directory scans — exclude them alongside id so GREATEST() only sees
    # the numeric keypaper score columns.
    score_cols <- setdiff(cols, c("id", "config", "variant"))
    if (!length(score_cols)) {
      stop("No keypaper score columns in ", f)
    }
    greatest_expr <- sprintf(
      "GREATEST(%s)",
      paste(sprintf('"%s"', score_cols), collapse = ", ")
    )
    sql <- sprintf(
      "SELECT id, '%s' AS variant, %s AS score
         FROM read_parquet('%s')",
      variant,
      greatest_expr,
      f
    )
    tibble::as_tibble(DBI::dbGetQuery(con, sql))
  })
  dplyr::bind_rows(parts)
}

# ---- 1. Run-metadata table -------------------------------------------------

viz_metadata_table <- function(emb_tcac20_title) {
  # Count via arrow pushdown — reads only parquet metadata, no rows
  # materialised. Used to take the full viz_embeddings tibble; that
  # path no longer scales.
  config_dir <- dirname(dirname(emb_tcac20_title))
  arrow::open_dataset(config_dir) |>
    dplyr::count(source, variant) |>
    dplyr::collect() |>
    tidyr::pivot_wider(
      names_from = variant,
      values_from = n,
      values_fill = 0L
    ) |>
    dplyr::arrange(source)
}

# ---- 2. Score distribution -------------------------------------------------

viz_score_summary <- function(scores_long) {
  scores_long |>
    dplyr::summarise(
      n = dplyr::n(),
      min = min(score, na.rm = TRUE),
      mean = mean(score, na.rm = TRUE),
      max = max(score, na.rm = TRUE),
      p10 = stats::quantile(score, 0.10, na.rm = TRUE),
      p50 = stats::quantile(score, 0.50, na.rm = TRUE),
      p90 = stats::quantile(score, 0.90, na.rm = TRUE),
      p99 = stats::quantile(score, 0.99, na.rm = TRUE),
      .by = variant
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

build_viz_score_dist_data <- function(scores_long, bins = 100L) {
  # Pre-bin so the figure target carries ~bins×variants rows instead of
  # the full 17M-row scores_long. Keeps tar_read(viz_score_dist_fig)
  # instant — ggplot2 stores the input data inside the object.
  rng <- range(scores_long$score, na.rm = TRUE)
  brks <- seq(rng[1], rng[2], length.out = bins + 1L)
  scores_long |>
    dplyr::mutate(
      bin = cut(
        score,
        breaks = brks,
        include.lowest = TRUE,
        labels = FALSE
      )
    ) |>
    dplyr::count(variant, bin) |>
    dplyr::mutate(x_mid = (brks[bin] + brks[bin + 1L]) / 2)
}

build_viz_score_dist_fig <- function(
  dist_data,
  figures_dir = "output/figures"
) {
  # Frequency polygons — bin-top lines per variant — overlap cleanly
  # where bars would occlude each other. A light fill keeps the
  # "histogram feel" without hiding any variant. Bars come from the
  # pre-binned dist_data, so the saved figure target stays tiny.
  p <- ggplot2::ggplot(
    dist_data,
    ggplot2::aes(x = x_mid, y = n, fill = variant, colour = variant)
  ) +
    ggplot2::geom_area(position = "identity", alpha = 0.15, linewidth = 0) +
    ggplot2::geom_line(linewidth = 0.8) +
    ggplot2::labs(
      x = "Max cosine similarity to nearest keypaper",
      y = "Number of works"
    ) +
    ggplot2::theme_minimal(base_size = 12)
  save_ggplot_png(p, "score_dist", figures_dir)
  p
}

# ---- 2b. ECDF (subsampled for plotting) ----------------------------------

build_viz_score_ecdf_data <- function(
  scores_long,
  n_per_variant = 50000L,
  seed = 13L
) {
  # Subsample so ggplot's stat_ecdf doesn't choke at 5M+ points. With
  # 50k per variant the rendered curve is visually indistinguishable from
  # the full-data ECDF; capture the seed in the caption.
  set.seed(seed)
  scores_long |>
    dplyr::group_by(variant) |>
    dplyr::slice_sample(n = n_per_variant) |>
    dplyr::ungroup()
}

build_viz_score_ecdf_fig <- function(
  ecdf_data,
  figures_dir = "output/figures"
) {
  p <- ggplot2::ggplot(
    ecdf_data,
    ggplot2::aes(x = score, colour = variant)
  ) +
    ggplot2::stat_ecdf(geom = "step", linewidth = 0.8) +
    ggplot2::labs(
      x = "Max cosine similarity to nearest keypaper",
      y = "ECDF — fraction of works with score ≤ x"
    ) +
    ggplot2::theme_minimal(base_size = 12)
  save_ggplot_png(p, "score_ecdf", figures_dir)
  p
}

# ---- 3. Top / bottom matches ----------------------------------------------

viz_top_bottom_tables <- function(scores_long, corpus_tcac20, n = 10) {
  # scores_long is the slim per-id max form (id, variant, score). Pick
  # top/bottom-N per variant, then fetch title strings from corpus via
  # an arrow pushdown filter on the (small) id set. Avoids loading
  # title_clean for the full corpus.
  picked <- scores_long |>
    dplyr::group_by(variant) |>
    dplyr::arrange(dplyr::desc(score), .by_group = TRUE) |>
    dplyr::group_modify(
      ~ dplyr::bind_rows(
        utils::head(.x, n) |>
          dplyr::mutate(rank = paste0("top ", seq_len(dplyr::n()))),
        utils::tail(.x, n) |>
          dplyr::mutate(rank = paste0("bottom ", seq_len(dplyr::n())))
      )
    ) |>
    dplyr::ungroup()

  titles <- arrow::open_dataset(corpus_tcac20) |>
    dplyr::filter(id %in% picked$id) |>
    dplyr::select(id, title) |>
    dplyr::collect()

  joined <- picked |>
    dplyr::left_join(titles, by = "id") |>
    dplyr::transmute(variant, rank, max_sim = round(score, 3), title)

  variants <- sort(unique(joined$variant))
  stats::setNames(
    lapply(variants, function(v) {
      joined |>
        dplyr::filter(variant == v) |>
        dplyr::select(-variant)
    }),
    variants
  )
}

# ---- 4. Variant-agreement plotly -------------------------------------------

viz_variant_agree_data <- function(scores_long, bins = 100L) {
  # 2D rectangular binning per variant pair. 100 × 100 bins × 3 pairs ≈
  # 30k rows max (in practice much less — most cells empty). Tar_read on
  # the fig target is instant; static ggplot renders at any scale.
  #
  # Pair order goes most-related → least-related so the visual story
  # reads left-to-right: title ⊂ title_abstract, abstract ⊂
  # title_abstract, title vs abstract (the disagreement diagnostic).
  per_work <- scores_long |>
    dplyr::summarise(
      max_sim = max(score, na.rm = TRUE),
      .by = c(id, variant)
    ) |>
    tidyr::pivot_wider(names_from = variant, values_from = max_sim)

  brks <- seq(0, 1, length.out = bins + 1L)

  bin_pair <- function(df, xv, yv, pair_name) {
    df |>
      dplyr::filter(!is.na(.data[[xv]]), !is.na(.data[[yv]])) |>
      dplyr::mutate(
        xb = cut(.data[[xv]], brks, include.lowest = TRUE, labels = FALSE),
        yb = cut(.data[[yv]], brks, include.lowest = TRUE, labels = FALSE)
      ) |>
      dplyr::count(xb, yb) |>
      dplyr::mutate(
        x_mid = (brks[xb] + brks[xb + 1L]) / 2,
        y_mid = (brks[yb] + brks[yb + 1L]) / 2,
        pair = pair_name,
        x_var = xv,
        y_var = yv
      ) |>
      dplyr::select(pair, x_var, y_var, x_mid, y_mid, n)
  }

  # bin_pair(df, xv, yv, ...) — xv lands on the x-axis, yv on y.
  # Inverted-L layout: top row uses y = title; bottom row uses y = abstract.
  # Left column uses x = title; right column uses x = title_abstract.
  # Top-left cell (y = title, x = title) is the identity, intentionally empty.
  dplyr::bind_rows(
    bin_pair(per_work, "title_abstract", "title", "title vs title_abstract"),
    bin_pair(per_work, "title", "abstract", "title vs abstract"),
    bin_pair(
      per_work,
      "title_abstract",
      "abstract",
      "abstract vs title_abstract"
    )
  )
}

build_viz_agree_fig <- function(agree_data, figures_dir = "output/figures") {
  # Order the row/column factors so the inverted-L layout renders as:
  #   row "title" + col "title" → empty (drop = FALSE)
  #   row "title" + col "title_abstract"     → top-right
  #   row "abstract" + col "title"           → bottom-left
  #   row "abstract" + col "title_abstract"  → bottom-right
  # Factor levels chosen so the empty cell is bottom-right (the
  # title-vs-title identity).
  #   row 1 (y = abstract): cols = abstract vs title_abstract | title vs abstract
  #   row 2 (y = title):    cols = title vs title_abstract     | (empty)
  agree_data <- agree_data |>
    dplyr::mutate(
      y_var = factor(y_var, levels = c("abstract", "title")),
      x_var = factor(x_var, levels = c("title_abstract", "title"))
    )

  rng <- range(c(agree_data$x_mid, agree_data$y_mid), na.rm = TRUE)
  rng <- c(floor(rng[1] * 10) / 10, ceiling(rng[2] * 10) / 10)

  p <- ggplot2::ggplot(
    agree_data,
    ggplot2::aes(x = x_mid, y = y_mid, fill = n)
  ) +
    ggplot2::geom_tile() +
    ggplot2::geom_abline(
      slope = 1,
      intercept = 0,
      linetype = "dashed",
      colour = "gray60"
    ) +
    ggplot2::scale_fill_viridis_c(
      trans = "log10",
      name = "Works\n(log)",
      option = "viridis"
    ) +
    ggplot2::scale_x_continuous(expand = c(0, 0)) +
    ggplot2::scale_y_continuous(expand = c(0, 0)) +
    ggplot2::coord_fixed(xlim = rng, ylim = rng) +
    ggplot2::facet_grid(
      rows = ggplot2::vars(y_var),
      cols = ggplot2::vars(x_var),
      drop = FALSE,
      switch = "y",
      labeller = ggplot2::labeller(
        y_var = function(v) paste0("y: ", v),
        x_var = function(v) paste0("x: ", v)
      )
    ) +
    ggplot2::labs(
      x = "Max cosine similarity",
      y = "Max cosine similarity"
    ) +
    ggplot2::theme_minimal(base_size = 12) +
    ggplot2::theme(
      panel.spacing = ggplot2::unit(1, "lines"),
      strip.text = ggplot2::element_text(face = "bold"),
      strip.placement = "outside"
    )
  save_ggplot_png(p, "variant_agree", figures_dir, width = 9, height = 8)
  p
}

# ---- 5. Threshold sweep ----------------------------------------------------

build_viz_threshold_fig <- function(
  scores_long,
  figures_dir = "output/figures"
) {
  work_max <- scores_long |>
    dplyr::summarise(max_sim = max(score, na.rm = TRUE), .by = c(id, variant))

  thresholds <- seq(0, 1, by = 0.01)
  sweep <- work_max |>
    dplyr::group_by(variant) |>
    dplyr::reframe(
      threshold = thresholds,
      n_above = vapply(thresholds, function(t) sum(max_sim >= t), integer(1))
    ) |>
    # log10(0) is -Inf; drop empty thresholds rather than let ggplot
    # warn about removed values.
    dplyr::filter(n_above > 0L)

  x_zoom_min <- min(work_max$max_sim, na.rm = TRUE) - 0.01

  p <- ggplot2::ggplot(
    sweep,
    ggplot2::aes(threshold, n_above, colour = variant)
  ) +
    ggplot2::geom_line(linewidth = 1) +
    ggplot2::scale_y_log10() +
    ggplot2::coord_cartesian(xlim = c(x_zoom_min, 1)) +
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

# ---- 5b. Top matches per keypaper -----------------------------------------
# For EVERY keypaper, its top-N corpus matches by cosine similarity (
# title_abstract variant). Feeds the interactive dropdown + histogram + table
# (build_tbl_top_matches_per_kp_widget()) in the Embedding Report — a
# static HTML report can't query the 4.6M-row corpus live, so this bounds
# what's shipped to the browser to n_matches per keypaper. n_matches = 1000
# stays small enough for a self-contained HTML widget (44 keypapers x 1000 =
# 44k rows; confirmed not sluggish in practice) while giving the per-keypaper
# histogram/table a fuller distribution to show than a bare top handful.
#
# Implementation: one duckdb ORDER BY ... LIMIT query per keypaper column,
# reading the scores parquet directly — duckdb's columnar pushdown means
# each query only reads the id + that one keypaper's column, not the full
# ~45-column x 4.6M-row file.

build_viz_top_matches_per_kp_data <- function(
  scores_tcac20_title_abstract,
  key_works,
  corpus_tcac20,
  n_matches = 1000L
) {
  if (
    !requireNamespace("duckdb", quietly = TRUE) ||
      !requireNamespace("DBI", quietly = TRUE)
  ) {
    stop("Packages 'duckdb' and 'DBI' are required.")
  }
  f <- scores_tcac20_title_abstract
  if (!file.exists(f)) stop("Scores parquet not found: ", f)

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)

  cols <- names(DBI::dbGetQuery(
    con, sprintf("SELECT * FROM read_parquet('%s') LIMIT 0", f)
  ))
  # See read_scores_long() for why config/variant are excluded alongside id.
  kp_cols <- setdiff(cols, c("id", "config", "variant"))

  parts <- lapply(kp_cols, function(kp) {
    sql <- sprintf(
      'SELECT id AS match_id, "%s" AS similarity
         FROM read_parquet(\'%s\')
        WHERE "%s" IS NOT NULL
        ORDER BY similarity DESC
        LIMIT %d',
      kp, f, kp, n_matches
    )
    d <- DBI::dbGetQuery(con, sql)
    d$keypaper_id <- kp
    d$rank <- seq_len(nrow(d))
    d
  })
  matches <- dplyr::bind_rows(parts)

  kp_meta <- arrow::open_dataset(key_works) |>
    dplyr::select(id, title) |>
    dplyr::collect() |>
    dplyr::rename(keypaper_id = id, keypaper_title = title)

  corpus_meta <- arrow::open_dataset(corpus_tcac20) |>
    dplyr::select(id, doi, title, citation) |>
    dplyr::filter(id %in% unique(matches$match_id)) |>
    dplyr::collect() |>
    dplyr::rename(
      match_id = id, match_doi = doi,
      match_title = title, match_citation = citation
    )

  matches |>
    dplyr::left_join(kp_meta, by = "keypaper_id") |>
    dplyr::left_join(corpus_meta, by = "match_id") |>
    dplyr::mutate(match_link = dplyr::coalesce(match_doi, match_id)) |>
    dplyr::select(
      keypaper_id, keypaper_title,
      rank, match_link, match_citation, match_title, similarity
    ) |>
    dplyr::arrange(keypaper_title, rank)
}

# Interactive dropdown (keypaper) + similarity-distribution histogram + DT
# table (with CSV export) over build_viz_top_matches_per_kp_data()'s
# precomputed top-N-per-keypaper pool. Client-side only (crosstalk) — no
# server, works in the static report HTML. The histogram is a plotly trace
# built on the same SharedData object as the table, so picking a keypaper in
# the dropdown filters both — no separate reactive wiring needed, crosstalk
# handles it via the shared `group`.
build_tbl_top_matches_per_kp_widget <- function(
  top_matches_per_kp,
  tables_dir = "output/tables"
) {
  if (
    !requireNamespace("crosstalk", quietly = TRUE) ||
      !requireNamespace("DT", quietly = TRUE) ||
      !requireNamespace("plotly", quietly = TRUE)
  ) {
    stop("Packages 'crosstalk', 'DT', and 'plotly' are required.")
  }

  df <- top_matches_per_kp |>
    dplyr::transmute(
      keypaper_label = keypaper_title,
      keypaper = keypaper_id,
      rank,
      link = sprintf(
        '<a href="%s" target="_blank" rel="noopener">%s</a>',
        match_link,
        htmltools::htmlEscape(match_link)
      ),
      citation = match_citation,
      title = match_title,
      similarity = round(similarity, 4)
    )

  sd <- crosstalk::SharedData$new(df, group = "tbl_top_matches_per_kp")

  # Fixed "all keypapers" distribution line — a probability-density line
  # showing the full-pool shape for reference. Rendered as its OWN plotly
  # widget (own graph div), completely separate from the dropdown-filtered
  # histogram below it — putting both traces in one plot_ly() call let
  # crosstalk's filtering apply to the whole graph (including the
  # non-SharedData trace), making the "always shown" line disappear on
  # selection. Two independent widgets can't have that problem: this one
  # has no SharedData anywhere in it, so crosstalk has nothing to attach a
  # filter listener to.
  #
  # Uses identical bin edges as the histogram (explicit `xbins` there,
  # matching breaks used here) and `histnorm = "probability"` on the
  # histogram so the two are shape-comparable despite the "all" line
  # covering ~40x more rows than a single filtered keypaper.
  sim_rng <- range(df$similarity, na.rm = TRUE)
  n_bins <- 40L
  bin_width <- diff(sim_rng) / n_bins
  breaks <- seq(sim_rng[1], sim_rng[2], length.out = n_bins + 1L)

  all_dist <- df |>
    dplyr::mutate(
      bin = cut(similarity, breaks, include.lowest = TRUE, labels = FALSE)
    ) |>
    dplyr::count(bin) |>
    dplyr::mutate(
      x_mid = (breaks[bin] + breaks[bin + 1L]) / 2,
      density = n / sum(n)
    )

  p_all <- plotly::plot_ly(
    all_dist, x = ~x_mid, y = ~density, height = 110,
    type = "scatter", mode = "lines",
    line = list(color = "red", width = 1.5, shape = "spline"),
    name = "all keypapers"
  ) |>
    plotly::layout(
      xaxis = list(title = "", range = sim_rng),
      yaxis = list(title = "all (density)"),
      margin = list(t = 10, b = 10),
      showlegend = FALSE
    )

  p_kp <- plotly::plot_ly(height = 200) |>
    plotly::add_histogram(
      data = sd, x = ~similarity,
      xbins = list(start = sim_rng[1], end = sim_rng[2], size = bin_width),
      histnorm = "probability",
      marker = list(color = "#377EB8"),
      name = "selected keypaper"
    ) |>
    plotly::layout(
      xaxis = list(title = "similarity", range = sim_rng),
      yaxis = list(title = "selected (probability)"),
      bargap = 0.05,
      margin = list(t = 10),
      showlegend = FALSE
    )

  hist <- htmltools::tagList(p_all, p_kp)

  w <- crosstalk::bscols(
    widths = c(3, 9),
    list(
      htmltools::tagList(
        # Scoped to just this select control so it doesn't shrink the
        # table/histogram text too.
        htmltools::tags$style(
          ".tbl-top-matches-kp-select .selectize-input,
           .tbl-top-matches-kp-select .selectize-dropdown { font-size: 12px; }"
        ),
        htmltools::div(
          class = "tbl-top-matches-kp-select",
          crosstalk::filter_select(
            "kp_select", "Keypaper", sd, ~keypaper_label, multiple = FALSE
          )
        )
      )
    ),
    list(
      hist,
      htmltools::tagList(
        # "compact" (DT's built-in class) tightens row padding; the
        # explicit font-size rules are what actually shrink the table text
        # and the CSV button text — scoped to this table's wrapper class so
        # they don't affect the dropdown/histogram.
        htmltools::tags$style(
          ".tbl-top-matches-per-kp table.dataTable { font-size: 12px; }
           .tbl-top-matches-per-kp .dt-buttons .dt-button { font-size: 12px; }"
        ),
        htmltools::div(
          class = "tbl-top-matches-per-kp",
          DT::datatable(
            sd,
            rownames = FALSE,
            escape = FALSE,
            class = "compact stripe hover",
            extensions = "Buttons",
            options = list(
              pageLength = 25,
              order = list(list(2, "asc")),
              columnDefs = list(list(visible = FALSE, targets = 0)),
              dom = "Bfrtip",
              buttons = list("csv")
            ),
            caption = paste0(
              "Top ", format(max(top_matches_per_kp$rank), big.mark = ","),
              " corpus matches per keypaper (title_abstract variant). Pick ",
              "a keypaper; download the filtered rows as CSV via the ",
              "button above the table."
            )
          )
        )
      )
    )
  )
  # bscols() returns a shiny.tag (dropdown + slider + table combined), not a
  # bare htmlwidget — htmlwidgets::saveWidget() (used by save_widget_html())
  # can't resolve its crosstalk dependencies and errors deep in htmltools.
  # htmltools::save_html() handles tag lists correctly; it writes JS/CSS as
  # sibling files under `<name>_files/` rather than inlining everything into
  # one file, so the .html and its `_files/` dir must travel together.
  ensure_figures_dir(tables_dir)
  save_html_path <- file.path(tables_dir, "tbl_top_matches_per_kp.html")
  htmltools::save_html(w, save_html_path)
  w
}

# ---- 5c. Text length distribution per variant -----------------------------
# Histogram of nchar(title), nchar(abstract), and nchar(title_abstract).
# Computed via duckdb pushdown (length() in SQL) so 5.77M rows never
# materialize as text in R.

build_viz_text_length_data <- function(
  corpus_tcac20,
  title_cap_combined = 200L,
  sep_token = "[SEP]",
  bins = 60L
) {
  if (
    !requireNamespace("duckdb", quietly = TRUE) ||
      !requireNamespace("DBI", quietly = TRUE)
  ) {
    stop(
      "Packages 'duckdb' and 'DBI' required for build_viz_text_length_data()."
    )
  }
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(
    try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE),
    add = TRUE
  )

  sep_len <- nchar(sep_token) + 2L # space + sep + space
  sql <- sprintf(
    "SELECT
       length(title)    AS title_len,
       length(abstract) AS abstract_len,
       LEAST(length(title), %d) + %d + length(abstract) AS title_abstract_len
     FROM read_parquet('%s')
     WHERE title IS NOT NULL OR abstract IS NOT NULL",
    title_cap_combined,
    sep_len,
    corpus_tcac20
  )
  df <- tibble::as_tibble(DBI::dbGetQuery(con, sql))

  # Long form + per-variant binning so the figure target stays tiny.
  long <- dplyr::bind_rows(
    tibble::tibble(variant = "title", len = df$title_len),
    tibble::tibble(variant = "abstract", len = df$abstract_len),
    tibble::tibble(variant = "title_abstract", len = df$title_abstract_len)
  ) |>
    dplyr::filter(!is.na(len), len > 0)

  # Bin in log10-space so the resolution matches the log x-axis the
  # figure uses. With linear bins on a log axis, titles (30-200 chars)
  # all fall into bins 1-2 of a 1..20000 range and the curve renders as
  # a degenerate triangle.
  log_rng <- log10(range(long$len))
  log_brks <- seq(log_rng[1], log_rng[2], length.out = bins + 1L)
  brks <- 10^log_brks
  long |>
    dplyr::mutate(
      bin = cut(log10(len), log_brks, include.lowest = TRUE, labels = FALSE)
    ) |>
    dplyr::count(variant, bin) |>
    dplyr::mutate(x_mid = 10^((log_brks[bin] + log_brks[bin + 1L]) / 2))
}

build_viz_text_length_fig <- function(
  text_length_data,
  figures_dir = "output/figures"
) {
  p <- ggplot2::ggplot(
    text_length_data,
    ggplot2::aes(x = x_mid, y = n, fill = variant, colour = variant)
  ) +
    ggplot2::geom_area(position = "identity", alpha = 0.15, linewidth = 0) +
    ggplot2::geom_line(linewidth = 0.8) +
    ggplot2::scale_x_continuous(trans = "log10", labels = scales::comma) +
    ggplot2::labs(
      x = "Characters in text sent to TEI (log scale)",
      y = "Number of works"
    ) +
    ggplot2::theme_minimal(base_size = 12)
  save_ggplot_png(p, "text_length", figures_dir)
  p
}

# ---- 5d. Within-keypaper self-similarity ----------------------------------
# 105 x 105 cosine matrix of keypapers against themselves (title_abstract
# variant). Tile heatmap, hierarchical ordering so coherent clusters
# sit next to each other on the axes.

build_viz_keypaper_self_sim_data <- function(emb_keypapers_title_abstract) {
  emb <- arrow::open_dataset(emb_keypapers_title_abstract) |>
    dplyr::select(id, dplyr::starts_with("V")) |>
    dplyr::collect()
  vcols <- grep("^V[0-9]+$", names(emb), value = TRUE)
  vcols <- vcols[order(as.integer(sub("^V", "", vcols)))]
  M <- as.matrix(emb[, vcols, drop = FALSE])
  norms <- sqrt(rowSums(M * M))
  norms[norms == 0] <- 1
  M <- M / norms
  sims <- M %*% t(M)
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
  save_ggplot_png(p, "keypaper_self_sim", figures_dir, width = 7, height = 6.5)
  p
}

# ---- 5e. Score vs publication year ----------------------------------------
# 2D histogram of (publication_year, max_sim) per variant. Spot biases
# where relevance correlates with recency.

build_viz_score_year_data <- function(
  scores_long,
  corpus_tcac20,
  year_min = 1990L,
  score_bins = 60L
) {
  years <- arrow::open_dataset(corpus_tcac20) |>
    dplyr::select(id, publication_year) |>
    dplyr::collect()

  joined <- scores_long |>
    dplyr::inner_join(years, by = "id") |>
    dplyr::filter(!is.na(publication_year), publication_year >= year_min)

  score_rng <- range(joined$score, na.rm = TRUE)
  score_brks <- seq(score_rng[1], score_rng[2], length.out = score_bins + 1L)

  hist <- joined |>
    dplyr::mutate(
      score_bin = cut(
        score,
        score_brks,
        include.lowest = TRUE,
        labels = FALSE
      )
    ) |>
    dplyr::count(variant, publication_year, score_bin) |>
    dplyr::mutate(
      score_mid = (score_brks[score_bin] + score_brks[score_bin + 1L]) / 2
    )

  stats <- joined |>
    dplyr::summarise(
      mean_score = mean(score, na.rm = TRUE),
      median_score = stats::median(score, na.rm = TRUE),
      .by = c(variant, publication_year)
    ) |>
    dplyr::arrange(variant, publication_year)

  list(hist = hist, stats = stats)
}

build_viz_score_year_fig <- function(
  score_year_data,
  figures_dir = "output/figures"
) {
  p <- ggplot2::ggplot() +
    ggplot2::geom_tile(
      data = score_year_data$hist,
      ggplot2::aes(x = publication_year, y = score_mid, fill = n)
    ) +
    ggplot2::geom_line(
      data = score_year_data$stats,
      ggplot2::aes(x = publication_year, y = mean_score, colour = "mean"),
      linewidth = 1.2
    ) +
    ggplot2::geom_line(
      data = score_year_data$stats,
      ggplot2::aes(x = publication_year, y = median_score, colour = "median"),
      linewidth = 1.2,
      linetype = "dashed"
    ) +
    ggplot2::geom_point(
      data = score_year_data$stats,
      ggplot2::aes(x = publication_year, y = mean_score),
      colour = "#FF3300",
      size = 1.6
    ) +
    ggplot2::geom_point(
      data = score_year_data$stats,
      ggplot2::aes(x = publication_year, y = median_score),
      colour = "#FFCC00",
      size = 1.6
    ) +
    ggplot2::scale_fill_viridis_c(trans = "log10", name = "Works\n(log)") +
    ggplot2::scale_colour_manual(
      name = NULL,
      values = c(mean = "#FF3300", median = "#FFCC00"),
      guide = ggplot2::guide_legend(
        override.aes = list(linetype = c("solid", "dashed"), linewidth = 1.2)
      )
    ) +
    ggplot2::facet_wrap(~variant, ncol = 3) +
    ggplot2::labs(
      x = "Publication year",
      y = "Max cosine similarity to nearest keypaper"
    ) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(panel.spacing = ggplot2::unit(1, "lines"))
  save_ggplot_png(p, "score_year", figures_dir, width = 12, height = 4.5)
  p
}

# ---- 5f. Work-type breakdown ----------------------------------------------
# Count per OpenAlex work type + score distribution per type, per
# variant. Types below `min_pct` of the corpus are dropped from the
# score plots (too few works for a meaningful median/violin) but kept
# in the count bar chart so the long tail is visible.

build_viz_type_counts <- function(corpus_tcac20, min_pct = 0.5) {
  arrow::open_dataset(corpus_tcac20) |>
    dplyr::count(type) |>
    dplyr::collect() |>
    dplyr::mutate(
      pct = 100 * n / sum(n),
      popular = pct >= min_pct,
      type = ifelse(is.na(type) | type == "", "(unknown)", type)
    ) |>
    dplyr::arrange(dplyr::desc(n))
}

build_viz_type_count_fig <- function(
  type_counts,
  figures_dir = "output/figures"
) {
  d <- type_counts |>
    dplyr::mutate(type = factor(type, levels = rev(type_counts$type)))
  p <- ggplot2::ggplot(
    d,
    ggplot2::aes(x = n, y = type, fill = popular)
  ) +
    ggplot2::geom_col() +
    ggplot2::geom_text(
      ggplot2::aes(
        label = ifelse(pct < 0.01, "< 0.01%", sprintf("%.2f%%", pct))
      ),
      hjust = -0.1,
      size = 3
    ) +
    ggplot2::scale_x_continuous(
      trans = "log10",
      labels = scales::comma,
      expand = ggplot2::expansion(mult = c(0, 0.18))
    ) +
    ggplot2::scale_fill_manual(
      values = c(`TRUE` = "#2C7FB8", `FALSE` = "#BBBBBB"),
      name = "≥ filter",
      labels = c(`TRUE` = "kept for score plots", `FALSE` = "long tail")
    ) +
    ggplot2::labs(x = "Number of works (log)", y = NULL) +
    ggplot2::theme_minimal(base_size = 11)
  save_ggplot_png(p, "type_counts", figures_dir, width = 9, height = 6)
  p
}

build_viz_type_score_stats <- function(
  scores_long,
  corpus_tcac20,
  min_pct = 0.5
) {
  types_df <- arrow::open_dataset(corpus_tcac20) |>
    dplyr::select(id, type) |>
    dplyr::collect() |>
    dplyr::mutate(type = ifelse(is.na(type) | type == "", "(unknown)", type))

  total <- nrow(types_df)
  popular <- types_df |>
    dplyr::count(type) |>
    dplyr::filter(100 * n / total >= min_pct) |>
    dplyr::pull(type)

  joined <- scores_long |>
    dplyr::inner_join(types_df, by = "id") |>
    dplyr::filter(type %in% popular)

  joined |>
    dplyr::summarise(
      n = dplyr::n(),
      mean = mean(score, na.rm = TRUE),
      q05 = stats::quantile(score, 0.05, na.rm = TRUE),
      q25 = stats::quantile(score, 0.25, na.rm = TRUE),
      median = stats::median(score, na.rm = TRUE),
      q75 = stats::quantile(score, 0.75, na.rm = TRUE),
      q95 = stats::quantile(score, 0.95, na.rm = TRUE),
      .by = c(type, variant)
    ) |>
    dplyr::arrange(variant, dplyr::desc(median))
}

build_viz_type_score_heatmap_fig <- function(
  type_score_stats,
  figures_dir = "output/figures"
) {
  # Order types by overall median (across variants) so winners cluster
  # on one side of the plot.
  type_order <- type_score_stats |>
    dplyr::summarise(m = stats::median(median), .by = type) |>
    dplyr::arrange(dplyr::desc(m)) |>
    dplyr::pull(type)

  d <- type_score_stats |>
    dplyr::mutate(type = factor(type, levels = rev(type_order)))

  p <- ggplot2::ggplot(
    d,
    ggplot2::aes(x = variant, y = type, fill = median)
  ) +
    ggplot2::geom_tile() +
    ggplot2::geom_text(
      ggplot2::aes(
        label = sprintf("%.3f\n(n=%s)", median, format(n, big.mark = ","))
      ),
      colour = "white",
      size = 3,
      lineheight = 0.9
    ) +
    ggplot2::scale_fill_viridis_c(name = "Median\nscore") +
    ggplot2::labs(x = "Variant", y = NULL) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(panel.grid = ggplot2::element_blank())
  save_ggplot_png(p, "type_score_heatmap", figures_dir, width = 8, height = 6)
  p
}

build_viz_type_score_box_fig <- function(
  type_score_stats,
  figures_dir = "output/figures"
) {
  type_order <- type_score_stats |>
    dplyr::summarise(m = stats::median(median), .by = type) |>
    dplyr::arrange(m) |>
    dplyr::pull(type)

  d <- type_score_stats |>
    dplyr::mutate(type = factor(type, levels = type_order))

  p <- ggplot2::ggplot(d, ggplot2::aes(y = type)) +
    ggplot2::geom_boxplot(
      ggplot2::aes(
        xmin = q05,
        xlower = q25,
        xmiddle = median,
        xupper = q75,
        xmax = q95,
        fill = variant
      ),
      stat = "identity",
      alpha = 0.7
    ) +
    ggplot2::facet_wrap(~variant, ncol = 3) +
    ggplot2::scale_fill_brewer(palette = "Set2", guide = "none") +
    ggplot2::labs(
      x = "Max cosine similarity to nearest keypaper (q05–q25–median–q75–q95)",
      y = NULL
    ) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(panel.spacing = ggplot2::unit(1, "lines"))
  save_ggplot_png(p, "type_score_box", figures_dir, width = 13, height = 6)
  p
}

# ---- 5g. Language breakdown -----------------------------------------------

build_viz_language_counts <- function(corpus_tcac20, min_pct = 0.5) {
  arrow::open_dataset(corpus_tcac20) |>
    dplyr::count(language) |>
    dplyr::collect() |>
    dplyr::mutate(
      pct = 100 * n / sum(n),
      popular = pct >= min_pct,
      language = ifelse(is.na(language) | language == "", "(unknown)", language)
    ) |>
    dplyr::arrange(dplyr::desc(n))
}

build_viz_language_fig <- function(
  language_counts,
  figures_dir = "output/figures"
) {
  d <- language_counts |>
    dplyr::mutate(
      language = factor(language, levels = rev(language_counts$language))
    )
  p <- ggplot2::ggplot(
    d,
    ggplot2::aes(x = n, y = language, fill = popular)
  ) +
    ggplot2::geom_col() +
    ggplot2::geom_text(
      ggplot2::aes(
        label = ifelse(pct < 0.01, "< 0.01%", sprintf("%.2f%%", pct))
      ),
      hjust = -0.1,
      size = 3
    ) +
    ggplot2::scale_x_continuous(
      trans = "log10",
      labels = scales::comma,
      expand = ggplot2::expansion(mult = c(0, 0.18))
    ) +
    ggplot2::scale_fill_manual(
      values = c(`TRUE` = "#2C7FB8", `FALSE` = "#BBBBBB"),
      name = "≥ 0.5%",
      labels = c(`TRUE` = "kept", `FALSE` = "long tail")
    ) +
    ggplot2::labs(x = "Number of works (log)", y = NULL) +
    ggplot2::theme_minimal(base_size = 11)
  save_ggplot_png(p, "language", figures_dir, width = 9, height = 5)
  p
}

# ---- 5h. Truncation diagnostic --------------------------------------------
# SPECTER2 silently truncates input above ~512 tokens (~2000 chars).
# Count how many works in each variant exceed plausible thresholds.

build_viz_truncation_stats <- function(
  corpus_tcac20,
  title_cap_combined = 200L,
  sep_token = "[SEP]"
) {
  if (
    !requireNamespace("duckdb", quietly = TRUE) ||
      !requireNamespace("DBI", quietly = TRUE)
  ) {
    stop(
      "Packages 'duckdb' and 'DBI' required for build_viz_truncation_stats()."
    )
  }
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(
    try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE),
    add = TRUE
  )
  sep_len <- nchar(sep_token) + 2L
  q <- function(expr) {
    sprintf(
      "SELECT COUNT(*) AS n FROM read_parquet('%s') WHERE %s",
      corpus_tcac20,
      expr
    )
  }
  total <- as.integer(
    DBI::dbGetQuery(
      con,
      sprintf("SELECT COUNT(*) AS n FROM read_parquet('%s')", corpus_tcac20)
    )$n
  )

  rows <- list(
    list(variant = "title", expr = "length(title) IS NOT NULL"),
    list(variant = "abstract", expr = "length(abstract) IS NOT NULL"),
    list(
      variant = "title_abstract",
      expr = sprintf(
        "LEAST(length(title), %d) + %d + length(abstract) IS NOT NULL",
        title_cap_combined,
        sep_len
      )
    )
  )
  thresholds <- c(1024L, 2048L, 4096L)

  parts <- lapply(rows, function(r) {
    n_var <- as.integer(DBI::dbGetQuery(con, q(r$expr))$n)
    over <- vapply(
      thresholds,
      function(t) {
        len_expr <- switch(
          r$variant,
          title = "length(title)",
          abstract = "length(abstract)",
          title_abstract = sprintf(
            "LEAST(length(title), %d) + %d + length(abstract)",
            title_cap_combined,
            sep_len
          )
        )
        as.integer(DBI::dbGetQuery(con, q(sprintf("%s > %d", len_expr, t)))$n)
      },
      integer(1)
    )
    tibble::tibble(
      variant = r$variant,
      n = n_var,
      `> 1024` = over[[1]],
      `> 2048` = over[[2]],
      `> 4096` = over[[3]],
      `% > 2048` = round(100 * over[[2]] / n_var, 3)
    )
  })
  dplyr::bind_rows(parts)
}

# ---- 5i. Per-keypaper score distribution ----------------------------------
# 105 boxes — one per keypaper — showing the distribution of cosine
# similarities to that keypaper across the whole corpus. Sorted by
# median to surface 'generic' vs 'orphan' keypapers.

build_viz_keypaper_score_dist_data <- function(
  scores_tcac20_title_abstract,
  key_works
) {
  if (
    !requireNamespace("duckdb", quietly = TRUE) ||
      !requireNamespace("DBI", quietly = TRUE)
  ) {
    stop("Packages 'duckdb' and 'DBI' required.")
  }
  f <- scores_tcac20_title_abstract
  if (!file.exists(f)) {
    stop("Scores parquet not found: ", f)
  }

  cols <- names(arrow::open_dataset(f) |> head(0) |> dplyr::collect())
  # See read_scores_long() for why config/variant are excluded alongside id.
  kp_cols <- setdiff(cols, c("id", "config", "variant"))

  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(
    try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE),
    add = TRUE
  )

  # Build one big SELECT with all per-column quantile aggregates.
  qs <- c(0.05, 0.25, 0.50, 0.75, 0.95)
  qnm <- c("q05", "q25", "median", "q75", "q95")
  expr <- unlist(lapply(kp_cols, function(c) {
    c(
      sprintf('quantile_cont("%s", %s) AS "%s__%s"', c, qs, c, qnm),
      sprintf('AVG("%s") AS "%s__mean"', c, c),
      sprintf('COUNT("%s") AS "%s__n"', c, c)
    )
  }))
  sql <- sprintf(
    "SELECT %s FROM read_parquet('%s')",
    paste(expr, collapse = ", "),
    f
  )
  wide <- DBI::dbGetQuery(con, sql)

  # Reshape to long: one row per keypaper × stat.
  long <- tidyr::pivot_longer(
    wide,
    cols = dplyr::everything(),
    names_to = c("keypaper_id", "stat"),
    names_sep = "__",
    values_to = "value"
  )
  stats <- long |>
    tidyr::pivot_wider(names_from = stat, values_from = value)

  # Lookup title + link for the keypaper
  meta <- arrow::open_dataset(key_works) |>
    dplyr::select(id, title, link) |>
    dplyr::collect() |>
    dplyr::mutate(citation = title)

  stats |>
    dplyr::left_join(meta, by = c("keypaper_id" = "id")) |>
    dplyr::arrange(dplyr::desc(median))
}

build_viz_keypaper_score_dist_fig <- function(
  kp_score_dist,
  figures_dir = "output/figures"
) {
  d <- kp_score_dist
  d$y_pos <- seq_len(nrow(d))
  d$label <- ifelse(
    is.na(d$citation) | !nzchar(d$citation),
    d$keypaper_id,
    paste0(d$y_pos, ". ", d$citation)
  )
  d$label_short <- substr(d$label, 1, 90)
  d$href <- ifelse(is.na(d$link) | !nzchar(d$link), NA_character_, d$link)
  d$tick_html <- ifelse(
    is.na(d$href),
    htmltools::htmlEscape(d$label_short),
    sprintf(
      '<a href="%s" target="_blank" rel="noopener">%s</a>',
      d$href,
      htmltools::htmlEscape(d$label_short)
    )
  )
  hover <- sprintf(
    "%s<br>median = %.3f<br>q05 = %.3f  q95 = %.3f<br>q25 = %.3f  q75 = %.3f<br>n = %s",
    htmltools::htmlEscape(d$label_short),
    d$median,
    d$q05,
    d$q95,
    d$q25,
    d$q75,
    format(d$n, big.mark = ",")
  )
  fig_h <- max(500L, as.integer(nrow(d) * 28L) + 220L)
  fig_w <- 900L # explicit width so the x-axis has enough room for trend

  fig <- plotly::plot_ly(width = fig_w, height = fig_h) |>
    plotly::add_segments(
      x = ~q05,
      xend = ~q95,
      y = ~y_pos,
      yend = ~y_pos,
      data = d,
      line = list(color = "#1a4e7a", width = 1.2),
      hoverinfo = "skip",
      showlegend = FALSE
    ) |>
    plotly::add_segments(
      x = ~q25,
      xend = ~q75,
      y = ~y_pos,
      yend = ~y_pos,
      data = d,
      line = list(color = "#377EB8", width = 8),
      hoverinfo = "skip",
      showlegend = FALSE
    ) |>
    plotly::add_markers(
      x = ~median,
      y = ~y_pos,
      data = d,
      marker = list(
        color = "white",
        size = 7,
        line = list(color = "#1a4e7a", width = 1)
      ),
      text = hover,
      hoverinfo = "text",
      hoverlabel = list(align = "left"),
      showlegend = FALSE
    ) |>
    plotly::layout(
      title = list(
        text = sprintf(
          "Per-keypaper score distribution (n = %d keypapers)",
          nrow(d)
        ),
        x = 0
      ),
      xaxis = list(
        title = list(
          text = "Cosine similarity to corpus (q05–q25–median–q75–q95)",
          standoff = 12
        )
      ),
      yaxis = list(
        title = "",
        tickmode = "array",
        tickvals = d$y_pos,
        ticktext = d$tick_html,
        # Tight range removes the empty space above the first and below
        # the last keypaper that plotly adds by default.
        range = list(nrow(d) + 0.5, 0.5),
        tickfont = list(size = 10)
      ),
      margin = list(l = 360, r = 80, t = 60, b = 90)
    )
  save_widget_html(fig, "keypaper_score_dist", figures_dir)
  fig
}

# ---- 5j. Embedding L2-norm distribution -----------------------------------
# Sanity check that the model returned reasonable normalised vectors —
# sampled to keep this cheap (50k rows per leaf is plenty for a
# histogram).

build_viz_emb_norm_data <- function(
  emb_tcac20_title,
  emb_tcac20_abstract,
  emb_tcac20_title_abstract,
  emb_keypapers_title,
  emb_keypapers_abstract,
  emb_keypapers_title_abstract,
  sample_size = 50000L,
  seed = 13L
) {
  leaves <- list(
    list(source = "corpus", variant = "title", path = emb_tcac20_title),
    list(source = "corpus", variant = "abstract", path = emb_tcac20_abstract),
    list(
      source = "corpus",
      variant = "title_abstract",
      path = emb_tcac20_title_abstract
    ),
    list(source = "keypaper", variant = "title", path = emb_keypapers_title),
    list(
      source = "keypaper",
      variant = "abstract",
      path = emb_keypapers_abstract
    ),
    list(
      source = "keypaper",
      variant = "title_abstract",
      path = emb_keypapers_title_abstract
    )
  )
  set.seed(seed)
  parts <- lapply(leaves, function(L) {
    ds <- arrow::open_dataset(L$path)
    ids <- ds |> dplyr::select(id) |> dplyr::collect()
    keep <- if (nrow(ids) > sample_size) {
      ids$id[sample.int(nrow(ids), sample_size)]
    } else {
      ids$id
    }
    df <- ds |>
      dplyr::filter(id %in% keep) |>
      dplyr::select(id, dplyr::starts_with("V")) |>
      dplyr::collect()
    vcols <- grep("^V[0-9]+$", names(df), value = TRUE)
    M <- as.matrix(df[, vcols, drop = FALSE])
    tibble::tibble(
      source = L$source,
      variant = L$variant,
      norm = sqrt(rowSums(M * M))
    )
  })
  dplyr::bind_rows(parts)
}

build_viz_emb_norm_fig <- function(norm_data, figures_dir = "output/figures") {
  p <- ggplot2::ggplot(norm_data, ggplot2::aes(x = norm, fill = source)) +
    ggplot2::geom_histogram(bins = 60, position = "identity", alpha = 0.55) +
    ggplot2::facet_wrap(~variant, ncol = 3, scales = "free_y") +
    ggplot2::labs(
      x = "L2 norm of embedding vector",
      y = "Number of sampled works"
    ) +
    ggplot2::theme_minimal(base_size = 11)
  save_ggplot_png(p, "emb_norm", figures_dir, width = 12, height = 4)
  p
}

# ---- 5k. Citation count vs max similarity ---------------------------------

build_viz_citation_score_data <- function(
  scores_long,
  corpus_tcac20,
  score_bins = 50L,
  citation_bins = 40L
) {
  meta <- arrow::open_dataset(corpus_tcac20) |>
    dplyr::select(id, cited_by_count) |>
    dplyr::collect()
  joined <- scores_long |>
    dplyr::inner_join(meta, by = "id") |>
    dplyr::filter(!is.na(cited_by_count))

  log_cit <- log10(joined$cited_by_count + 1)
  cit_brks <- seq(min(log_cit), max(log_cit), length.out = citation_bins + 1L)
  score_rng <- range(joined$score, na.rm = TRUE)
  score_brks <- seq(score_rng[1], score_rng[2], length.out = score_bins + 1L)

  joined |>
    dplyr::mutate(
      log_cit_plus1 = log10(cited_by_count + 1),
      cit_bin = cut(
        log_cit_plus1,
        cit_brks,
        include.lowest = TRUE,
        labels = FALSE
      ),
      score_bin = cut(score, score_brks, include.lowest = TRUE, labels = FALSE)
    ) |>
    dplyr::count(variant, cit_bin, score_bin) |>
    dplyr::mutate(
      x_mid = (cit_brks[cit_bin] + cit_brks[cit_bin + 1L]) / 2,
      y_mid = (score_brks[score_bin] + score_brks[score_bin + 1L]) / 2
    )
}

build_viz_citation_score_fig <- function(
  cit_score_data,
  figures_dir = "output/figures"
) {
  p <- ggplot2::ggplot(
    cit_score_data,
    ggplot2::aes(x = x_mid, y = y_mid, fill = n)
  ) +
    ggplot2::geom_tile() +
    ggplot2::scale_fill_viridis_c(trans = "log10", name = "Works\n(log)") +
    ggplot2::facet_wrap(~variant, ncol = 3) +
    ggplot2::labs(
      x = "log10(cited_by_count + 1)",
      y = "Max cosine similarity to nearest keypaper"
    ) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(panel.spacing = ggplot2::unit(1, "lines"))
  save_ggplot_png(p, "citation_score", figures_dir, width = 12, height = 4.5)
  p
}

# ---- 6. UMAP coords (used by both interactive UMAP and topics UMAP) --------

viz_umap_coords <- function(
  emb_tcac20_title_abstract,
  emb_keypapers_title_abstract,
  viz_cfg
) {
  seed <- viz_cfg$umap_seed %||% 13L
  sample_size <- viz_cfg$umap_sample_size %||% 50000L
  n_neighbors <- viz_cfg$umap_n_neighbors %||% 15L
  min_dist <- viz_cfg$umap_min_dist %||% 0.1
  metric <- viz_cfg$umap_metric %||% "cosine"

  read_one <- function(leaf, source, n = NULL) {
    ds <- arrow::open_dataset(leaf)
    ids <- ds |> dplyr::select(id) |> dplyr::collect()
    if (!is.null(n) && nrow(ids) > n) {
      set.seed(seed)
      keep_ids <- ids$id[sample.int(nrow(ids), n)]
      df <- ds |>
        dplyr::filter(id %in% keep_ids) |>
        dplyr::select(id, dplyr::starts_with("V")) |>
        dplyr::collect()
    } else {
      df <- ds |>
        dplyr::select(id, dplyr::starts_with("V")) |>
        dplyr::collect()
    }
    df$source <- source
    df
  }
  emb <- dplyr::bind_rows(
    read_one(emb_tcac20_title_abstract, "corpus", sample_size),
    read_one(emb_keypapers_title_abstract, "keypaper", NULL)
  )
  vcols <- grep("^V[0-9]+$", names(emb), value = TRUE)
  vcols <- vcols[order(as.integer(sub("^V", "", vcols)))]
  M <- as.matrix(emb[, vcols, drop = FALSE])
  set.seed(seed)
  u <- uwot::umap(
    M,
    n_neighbors = n_neighbors,
    min_dist = min_dist,
    metric = metric
  )
  tibble::tibble(
    id = emb$id,
    source = emb$source,
    x = u[, 1],
    y = u[, 2]
  )
}

# ---- 7. Interactive UMAP --------------------------------------------------

viz_umap_data <- function(
  umap_coords,
  emb_tcac20_title,
  emb_keypapers_title,
  scores_tcac20_title_abstract,
  corpus_tcac20,
  key_works,
  variant = "title_abstract"
) {
  # Compute max-similarity per id by filtering the scores parquet down to
  # the sampled UMAP ids first (pushdown). Avoids materialising the full
  # ~5.77M × 105 wide -> long pivot.
  keep_ids <- umap_coords |>
    dplyr::filter(source == "corpus") |>
    dplyr::pull(id)
  variant_filter <- variant
  scored <- arrow::open_dataset(
    file.path(scores_tcac20_title_abstract, "..", "..")
  ) |>
    dplyr::filter(variant == variant_filter, id %in% keep_ids) |>
    dplyr::collect()
  score_cols <- setdiff(names(scored), c("id", "variant"))
  max_sim_per_id <- tibble::tibble(
    id = scored$id,
    max_sim = apply(
      as.matrix(scored[, score_cols, drop = FALSE]),
      1,
      max,
      na.rm = TRUE
    )
  )

  title_per_id <- dplyr::bind_rows(
    arrow::open_dataset(emb_tcac20_title) |>
      dplyr::select(id, title_clean) |>
      dplyr::collect(),
    arrow::open_dataset(emb_keypapers_title) |>
      dplyr::select(id, title_clean) |>
      dplyr::collect()
  ) |>
    dplyr::distinct(id, .keep_all = TRUE)

  citation_per_id <- dplyr::bind_rows(
    arrow::open_dataset(corpus_tcac20) |>
      dplyr::select(id, citation) |>
      dplyr::collect(),
    arrow::open_dataset(key_works) |>
      dplyr::select(id, citation = title) |>
      dplyr::collect()
  ) |>
    dplyr::distinct(id, .keep_all = TRUE)

  emb_corpus <- umap_coords |>
    dplyr::filter(source == "corpus") |>
    dplyr::left_join(max_sim_per_id, by = "id") |>
    dplyr::left_join(title_per_id, by = "id") |>
    dplyr::left_join(citation_per_id, by = "id") |>
    dplyr::mutate(
      max_sim_pctl = dplyr::percent_rank(max_sim),
      title_wrap = wrap_for_hover(title_clean, 70),
      citation_wrap = wrap_for_hover(citation, 70)
    )

  emb_keypaper_base <- umap_coords |>
    dplyr::filter(source == "keypaper") |>
    dplyr::left_join(title_per_id, by = "id") |>
    dplyr::left_join(citation_per_id, by = "id") |>
    dplyr::mutate(
      title_wrap = wrap_for_hover(title_clean, 70),
      citation_wrap = wrap_for_hover(citation, 70)
    )

  list(
    emb_corpus = emb_corpus,
    emb_keypaper_base = emb_keypaper_base
  )
}

viz_umap_best_kp <- function(
  umap_data,
  scores_tcac20_title_abstract,
  variant = "title_abstract"
) {
  # Restrict to the visible (sampled) corpus ids before collecting — the
  # full 5.77M × 105 score frame is ~1 GB in memory; the sample is ~1K
  # rows. Result row count = nrow(umap_data$emb_corpus).
  visible_ids <- umap_data$emb_corpus$id
  variant_filter <- variant
  scores_v <- arrow::open_dataset(
    file.path(scores_tcac20_title_abstract, "..", "..")
  ) |>
    dplyr::filter(variant == variant_filter, id %in% visible_ids) |>
    dplyr::collect()
  ref_cols <- setdiff(names(scores_v), c("id", "variant"))
  mtx <- as.matrix(scores_v[, ref_cols])
  best_idx <- max.col(mtx, ties.method = "first")

  ec <- umap_data$emb_corpus
  ek <- umap_data$emb_keypaper_base

  tibble::tibble(
    corpus_id = scores_v$id,
    kp_id = ref_cols[best_idx]
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
      n_corpus = tidyr::replace_na(n_corpus, 0L),
      marker_size = 6 + 20 * sqrt(n_corpus) / max(sqrt(max(n_corpus, 1L)), 1)
    )
}

viz_umap_work_max <- function(scores_long, umap_data) {
  # Restrict to visible (sampled) corpus + keypaper ids before scanning
  # scores_long (17M rows). Result row count = length(visible_ids).
  visible_ids <- unique(c(
    umap_data$emb_corpus$id,
    umap_data$emb_keypaper_base$id
  ))
  scores_long |>
    dplyr::filter(id %in% visible_ids) |>
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
    x = grid_x,
    y = grid_y,
    z = matrix(grid_df$z, nrow = grid_n, ncol = grid_n, byrow = TRUE)
  )
}

build_viz_umap_fig <- function(
  emb_corpus,
  emb_keypaper,
  contour,
  best_kp_df,
  work_max,
  figures_dir = "output/figures"
) {
  sd_corpus <- crosstalk::SharedData$new(
    emb_corpus,
    key = ~id,
    group = "tcac20_works"
  )
  sd_keypaper <- crosstalk::SharedData$new(
    emb_keypaper,
    key = ~id,
    group = "tcac20_works"
  )

  # Restrict the JS lookup payloads to the rows actually rendered.
  # best_kp_df / work_max are corpus-wide (~50 MB each as JSON); the JS
  # click handlers only need entries for points the user can click, which
  # is the sampled corpus subset in emb_corpus plus the keypapers.
  visible_ids <- unique(c(emb_corpus$id, emb_keypaper$id))
  best_kp_df_vis <- best_kp_df |>
    dplyr::filter(corpus_id %in% visible_ids | kp_id %in% visible_ids)
  work_max_vis <- work_max |> dplyr::filter(id %in% visible_ids)

  best_kp_json <- jsonlite::toJSON(
    best_kp_df_vis,
    dataframe = "rows",
    auto_unbox = TRUE
  )
  work_max_json <- jsonlite::toJSON(
    work_max_vis,
    dataframe = "rows",
    auto_unbox = TRUE
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
    best_kp_json,
    work_max_json
  )

  fig <- plotly::plot_ly(height = 600) |>
    plotly::add_trace(
      type = "contour",
      x = contour$x,
      y = contour$y,
      z = contour$z,
      colorscale = "Viridis",
      opacity = 0.35,
      showscale = FALSE,
      contours = list(coloring = "heatmap", showlines = FALSE),
      hoverinfo = "skip",
      name = "contour"
    ) |>
    plotly::add_markers(
      data = sd_corpus,
      x = ~x,
      y = ~y,
      text = ~ paste0(
        "<b>",
        citation_wrap,
        "</b><br><br>",
        title_wrap,
        "<br><br>Max similarity to keypapers: ",
        sprintf("%.3f", max_sim)
      ),
      customdata = ~id,
      hoverinfo = "text",
      hoverlabel = list(align = "left", namelength = -1),
      color = ~max_sim,
      colors = viridisLite::viridis(256),
      marker = list(
        size = 5,
        opacity = 0.7,
        colorbar = list(
          title = "Max similarity",
          len = 0.6,
          y = 0.5,
          yanchor = "middle",
          x = 1.05,
          thickness = 12
        )
      ),
      name = "corpus"
    ) |>
    plotly::add_markers(
      data = sd_keypaper,
      x = ~x,
      y = ~y,
      text = ~ paste0(
        "<b>",
        citation_wrap,
        "</b><br><br>",
        title_wrap,
        "<br><br>",
        n_corpus,
        " corpus matches"
      ),
      customdata = ~id,
      hoverinfo = "text",
      hoverlabel = list(align = "left", namelength = -1),
      marker = list(
        symbol = "triangle-up",
        color = "red",
        opacity = 0.85,
        size = ~marker_size,
        sizemode = "diameter",
        line = list(color = "black", width = 1)
      ),
      name = "keypaper"
    ) |>
    plotly::layout(
      xaxis = list(title = "UMAP 1"),
      yaxis = list(title = "UMAP 2"),
      margin = list(r = 120),
      legend = list(
        orientation = "h",
        x = 0,
        y = -0.12,
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

build_tbl_topics_data <- function(topics_tcac20, emb_tcac20_title) {
  topics_dir <- dirname(topics_tcac20)
  topic_info <- arrow::read_parquet(file.path(topics_dir, "topic_info.parquet"))
  topics_df <- arrow::read_parquet(file.path(topics_dir, "topics.parquet"))

  # Read just (id, title_clean) directly from the corpus title-embedding
  # leaf. This used to take a unified viz_embeddings input, which forced
  # a dependency on ALL six emb_* targets (including abstract). Only the
  # title variant is needed here, so we read it directly — keeps the
  # target buildable when the abstract variant isn't embedded yet.
  corpus_titles <- arrow::open_dataset(
    emb_tcac20_title, # leaf_dir directly — embed_works
    # returns the directory, not a file.
    format = "parquet",
    factory_options = list(exclude_invalid_files = TRUE)
  ) |>
    dplyr::select(id, title_clean) |>
    dplyr::collect() |>
    dplyr::distinct(id, .keep_all = TRUE)

  sample_titles_per_topic <- topics_df |>
    dplyr::filter(source == "corpus") |>
    dplyr::left_join(corpus_titles, by = "id") |>
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
      top_words = vapply(
        top_words,
        function(x) paste(x, collapse = ", "),
        character(1)
      )
    ) |>
    dplyr::transmute(
      topic_id,
      is_relevant,
      n_keypapers,
      n_corpus,
      top_words,
      sample_titles
    )
}

tbl_topics_widget <- function(topics_table_data, tables_dir = "output/tables") {
  w <- DT::datatable(
    topics_table_data,
    rownames = FALSE,
    options = list(
      pageLength = 15,
      autoWidth = TRUE,
      columnDefs = list(list(width = "40%", targets = 4))
    ),
    caption = "Topics ranked by keypaper density. is_relevant = (n_keypapers >= keypaper_threshold)."
  )
  save_widget_html(w, "tbl_topics", tables_dir)
  w
}

build_viz_topics_fig <- function(
  topics_tcac20,
  emb_corpus,
  emb_keypaper,
  figures_dir = "output/figures"
) {
  topics_dir <- dirname(topics_tcac20)
  topics_df <- arrow::read_parquet(file.path(topics_dir, "topics.parquet"))
  corpus_topics <- topics_df |> dplyr::filter(source == "corpus")

  corpus_pts <- emb_corpus |>
    dplyr::left_join(
      corpus_topics |> dplyr::select(id, topic_id),
      by = "id"
    ) |>
    dplyr::mutate(topic_id = factor(topic_id))

  keypaper_topics <- topics_df |> dplyr::filter(source == "keypaper")
  kp_pts <- emb_keypaper |>
    dplyr::left_join(
      keypaper_topics |> dplyr::select(id, topic_id),
      by = "id"
    ) |>
    dplyr::mutate(topic_id = factor(topic_id))

  # id → topic, topic → [ids] lookups for the click handler.
  # Both corpus and keypaper ids participate so a click highlights everything
  # in the topic regardless of source.
  combined_ids <- c(corpus_pts$id, kp_pts$id)
  combined_topics <- c(
    as.character(corpus_pts$topic_id),
    as.character(kp_pts$topic_id)
  )
  id_to_topic <- stats::setNames(combined_topics, combined_ids)
  topic_to_ids <- split(combined_ids, combined_topics)
  id_to_topic_json <- jsonlite::toJSON(as.list(id_to_topic), auto_unbox = TRUE)
  topic_to_ids_json <- jsonlite::toJSON(topic_to_ids, auto_unbox = FALSE)

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
    id_to_topic_json,
    topic_to_ids_json
  )

  sd_corpus_topics <- crosstalk::SharedData$new(
    corpus_pts,
    key = ~id,
    group = "tcac20_topics"
  )
  sd_kp_topics <- crosstalk::SharedData$new(
    kp_pts,
    key = ~id,
    group = "tcac20_topics"
  )

  fig <- plotly::plot_ly(height = 600) |>
    plotly::add_markers(
      data = sd_corpus_topics,
      x = ~x,
      y = ~y,
      color = ~topic_id,
      colors = viridisLite::turbo(nlevels(corpus_pts$topic_id)),
      text = ~ paste0(
        "<b>",
        citation_wrap,
        "</b><br><br>",
        title_wrap,
        "<br><br>Topic: ",
        topic_id,
        "<br>Max similarity to keypapers: ",
        sprintf("%.3f", max_sim)
      ),
      customdata = ~id,
      hoverinfo = "text",
      hoverlabel = list(align = "left", namelength = -1),
      marker = list(
        size = 5,
        opacity = 0.8,
        line = list(color = "rgba(40,40,40,0.4)", width = 0.3)
      ),
      showlegend = FALSE,
      name = "corpus"
    ) |>
    plotly::add_markers(
      data = sd_kp_topics,
      x = ~x,
      y = ~y,
      text = ~ paste0(
        "<b>",
        citation_wrap,
        "</b><br><br>",
        title_wrap,
        "<br><br>Topic: ",
        topic_id,
        "<br>",
        n_corpus,
        " corpus matches"
      ),
      customdata = ~id,
      hoverinfo = "text",
      hoverlabel = list(align = "left", namelength = -1),
      marker = list(
        symbol = "triangle-up",
        color = "red",
        opacity = 0.9,
        size = ~marker_size,
        sizemode = "diameter",
        line = list(color = "black", width = 1)
      ),
      showlegend = FALSE,
      name = "keypaper"
    ) |>
    plotly::layout(
      xaxis = list(title = "UMAP 1"),
      yaxis = list(title = "UMAP 2")
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


# ============================================================================
# Corpus-scale UMAP — density base + cluster polygons + click-to-drill-down
#
# Designed for the full-corpus BERTopic output (~4.6M works, ~200-1500
# topics) where rendering every point client-side is infeasible.
#
# Architecture (see TD_BERTopic_Parameters.md and TD_ShinyMigration.md):
#   1. viz_umap_density()      — KDE grid (default 500x500)
#   2. viz_umap_hulls()        — alpha-shape polygon per cluster
#   3. viz_umap_cluster_pts()  — per-cluster sampled point coords (drilldown)
#   4. viz_umap_clusters_fig() — plotly composition with JS click handler
#
# All four are pure functions of their inputs — directly wireable as
# tar_target()s once the BERTopic run completes. None reference the
# current pipeline state.
# ============================================================================

# 2-D KDE on UMAP coordinates. Returns the same shape as viz_umap_contour()
# but the z-matrix is point density (count per cell) rather than score —
# tells "where are the works?", not "where are the relevant works?".
#
# Tunables:
#   grid_n       grid resolution; 500 is browser-friendly, 1000 is sharper
#                but doubles client memory.
#   bandwidth    NULL = MASS::kde2d default (Silverman's rule); pass a
#                numeric for a fixed kernel width.
viz_umap_density <- function(umap_coords, grid_n = 500L, bandwidth = NULL) {
  stopifnot(all(c("x", "y") %in% names(umap_coords)))
  if (!requireNamespace("MASS", quietly = TRUE)) {
    stop(
      "Package 'MASS' is required for viz_umap_density(). ",
      "Install via: install.packages('MASS')"
    )
  }
  rng_x <- range(umap_coords$x, na.rm = TRUE)
  rng_y <- range(umap_coords$y, na.rm = TRUE)
  args <- list(
    x = umap_coords$x,
    y = umap_coords$y,
    n = grid_n,
    lims = c(rng_x, rng_y)
  )
  if (!is.null(bandwidth)) {
    args$h <- rep(as.numeric(bandwidth), 2L)
  }
  kde <- do.call(MASS::kde2d, args)
  list(x = kde$x, y = kde$y, z = kde$z)
}

# Per-cluster polygon (concave hull / alpha shape) over UMAP coords.
# Inputs:
#   umap_coords  data.frame with `id`, `x`, `y`
#   topics_df    data.frame with `id`, `topic_id` — the topics.parquet read.
#   min_points   clusters smaller than this aren't given hulls (avoid
#                triangle-from-3-points noise; topic_id = -1 is always
#                skipped — that's the BERTopic noise cluster).
#   method       "concave" (default — concaveman) or "convex" (base chull,
#                no extra dependency).
#   concavity    only used when method = "concave"; concaveman's concavity
#                parameter (larger = closer to convex hull; default 2).
#
# Returns a tibble: topic_id, n_points, vertices (list-col of n x 2
# matrices with columns x, y, polygon closed).
viz_umap_hulls <- function(
  umap_coords,
  topics_df,
  min_points = 5L,
  method = c("concave", "convex"),
  concavity = 2
) {
  method <- match.arg(method)
  stopifnot(all(c("id", "x", "y") %in% names(umap_coords)))
  stopifnot(all(c("id", "topic_id") %in% names(topics_df)))

  if (
    method == "concave" &&
      !requireNamespace("concaveman", quietly = TRUE)
  ) {
    message(
      "Package 'concaveman' not installed; falling back to ",
      "method = 'convex'. Install via: install.packages('concaveman')"
    )
    method <- "convex"
  }

  joined <- merge(
    umap_coords[, c("id", "x", "y")],
    topics_df[, c("id", "topic_id")],
    by = "id"
  )
  joined <- joined[!is.na(joined$topic_id) & joined$topic_id >= 0L, ]

  by_topic <- split(joined, joined$topic_id)
  by_topic <- by_topic[vapply(by_topic, nrow, integer(1)) >= min_points]
  if (!length(by_topic)) {
    return(data.frame(
      topic_id = integer(0),
      n_points = integer(0),
      vertices = I(list())
    ))
  }

  hull_of <- function(df) {
    mat <- as.matrix(df[, c("x", "y")])
    if (method == "concave") {
      verts <- concaveman::concaveman(mat, concavity = concavity)
      colnames(verts) <- c("x", "y")
      verts
    } else {
      h <- grDevices::chull(mat[, "x"], mat[, "y"])
      h <- c(h, h[1]) # close the polygon
      mat[h, , drop = FALSE]
    }
  }
  out <- data.frame(
    topic_id = as.integer(names(by_topic)),
    n_points = vapply(by_topic, nrow, integer(1)),
    vertices = I(lapply(by_topic, hull_of))
  )
  out[order(-out$n_points), , drop = FALSE]
}

# Per-cluster sampled point coordinates for the click-to-drill-down layer.
# Inputs as for viz_umap_hulls(). Returns a named list keyed by
# as.character(topic_id), each element a data.frame with id, x, y.
#
# Subsampling is essential at corpus scale: a 500-cluster × full-membership
# embed of points would be tens of MB of JSON. With sample_per_cluster=1000
# the total is bounded at ~500K points (~5 MB JSON gzipped) regardless of
# corpus size.
viz_umap_cluster_pts <- function(
  umap_coords,
  topics_df,
  sample_per_cluster = 1000L,
  seed = 13L
) {
  stopifnot(all(c("id", "x", "y") %in% names(umap_coords)))
  stopifnot(all(c("id", "topic_id") %in% names(topics_df)))
  joined <- merge(
    umap_coords[, c("id", "x", "y")],
    topics_df[, c("id", "topic_id")],
    by = "id"
  )
  joined <- joined[!is.na(joined$topic_id) & joined$topic_id >= 0L, ]

  set.seed(seed)
  by_topic <- split(joined, joined$topic_id)
  sampled <- lapply(by_topic, function(df) {
    if (nrow(df) > sample_per_cluster) {
      df <- df[sample.int(nrow(df), sample_per_cluster), , drop = FALSE]
    }
    df[, c("id", "x", "y")]
  })
  names(sampled) <- as.character(names(by_topic))
  sampled
}

# Composed plotly figure:
#   layer 0 — density heatmap (low alpha, viridis colormap)
#   layer 1 — cluster polygons (one trace; click → JS handler)
#   layer 2 — per-cluster sampled points (added dynamically on click)
#
# JS click handler is wired via htmlwidgets::onRender. On click, the
# handler:
#   1. resets all previously-added point traces
#   2. adds a new trace for the clicked cluster's sampled points
#   3. highlights the clicked polygon (yellow stroke) and dims others
#
# Inputs:
#   density        output of viz_umap_density()
#   hulls          output of viz_umap_hulls()
#   cluster_pts    output of viz_umap_cluster_pts()
#   topic_info_df  data.frame with topic_id, label, n_keypapers,
#                  is_relevant — for hover labels and relevant-cluster
#                  highlighting.
#   figures_dir    where to save the standalone widget HTML; pass NA to
#                  skip saving.
viz_umap_clusters_fig <- function(
  density,
  hulls,
  cluster_pts,
  topic_info_df,
  figures_dir = "output/figures"
) {
  if (!requireNamespace("plotly", quietly = TRUE)) {
    stop("Package 'plotly' is required for viz_umap_clusters_fig().")
  }
  if (!requireNamespace("htmlwidgets", quietly = TRUE)) {
    stop("Package 'htmlwidgets' is required for viz_umap_clusters_fig().")
  }
  stopifnot(all(c("x", "y", "z") %in% names(density)))
  stopifnot(all(c("topic_id", "vertices") %in% names(hulls)))

  # Density base layer — Heatmap trace. Low alpha so polygons sit on top
  # readably.
  fig <- plotly::plot_ly(source = "umap_clusters_fig") |>
    plotly::add_trace(
      type = "heatmap",
      x = density$x,
      y = density$y,
      z = density$z,
      colorscale = "Viridis",
      showscale = FALSE,
      opacity = 0.55,
      hoverinfo = "skip"
    )

  # Polygon traces — one per cluster, all the same trace style so click
  # routing is uniform. customdata carries topic_id so the JS handler
  # knows which cluster was clicked.
  info_lookup <- setNames(
    as.list(seq_len(nrow(topic_info_df))),
    as.character(topic_info_df$topic_id)
  )

  for (i in seq_len(nrow(hulls))) {
    tid <- hulls$topic_id[i]
    verts <- hulls$vertices[[i]]
    info_idx <- info_lookup[[as.character(tid)]]
    label <- if (!is.null(info_idx)) {
      topic_info_df$label[info_idx]
    } else {
      paste0("Topic ", tid)
    }
    n_kp <- if (!is.null(info_idx)) {
      as.integer(topic_info_df$n_keypapers[info_idx])
    } else {
      0L
    }
    relevant <- if (!is.null(info_idx)) {
      isTRUE(topic_info_df$is_relevant[info_idx])
    } else {
      FALSE
    }

    fig <- plotly::add_trace(
      fig,
      x = verts[, "x"],
      y = verts[, "y"],
      type = "scatter",
      mode = "lines",
      fill = "toself",
      fillcolor = if (relevant) {
        "rgba(220,20,60,0.18)"
      } else {
        "rgba(255,255,255,0.05)"
      },
      line = list(
        color = if (relevant) "rgba(220,20,60,0.90)" else "rgba(80,80,80,0.55)",
        width = if (relevant) 1.8 else 0.7
      ),
      hovertemplate = sprintf(
        "<b>topic %d</b><br>%s<br>%s%d keypapers<extra></extra>",
        tid,
        label,
        ifelse(relevant, "<b>relevant</b> · ", ""),
        n_kp
      ),
      customdata = list(tid),
      showlegend = FALSE,
      name = sprintf("topic %d", tid)
    )
  }

  fig <- plotly::layout(
    fig,
    xaxis = list(
      title = "",
      zeroline = FALSE,
      showgrid = FALSE,
      scaleanchor = "y",
      scaleratio = 1
    ),
    yaxis = list(title = "", zeroline = FALSE, showgrid = FALSE),
    margin = list(l = 10, r = 10, t = 10, b = 10),
    plot_bgcolor = "rgba(0,0,0,1)"
  )

  # JS click handler: on polygon click, draw that cluster's sampled
  # points as a new scatter trace; resets previously-drawn points.
  pts_json <- jsonlite::toJSON(
    cluster_pts,
    dataframe = "rows",
    auto_unbox = TRUE
  )
  on_render <- sprintf(
    "
    function(el, x) {
      window._tcacClustersEl = el;
      var clusterPts = %s;
      var basePolyCount = el.data.length;     // density + N polygons
      window.tcacSelectCluster = function (topicId) {
        // strip any previously-added cluster-point traces
        var extra = el.data.length - basePolyCount;
        if (extra > 0) {
          var idx = [];
          for (var i = 0; i < extra; i++) idx.push(basePolyCount + i);
          Plotly.deleteTraces(el, idx);
        }
        var pts = clusterPts[String(topicId)];
        if (!pts || !pts.length) return;
        var xs = pts.map(function (p) { return p.x; });
        var ys = pts.map(function (p) { return p.y; });
        var ids = pts.map(function (p) { return p.id; });
        Plotly.addTraces(el, {
          type: 'scattergl',
          mode: 'markers',
          x: xs, y: ys,
          text: ids,
          marker: { size: 4, color: 'rgba(255,255,0,0.85)',
                    line: { width: 0 } },
          hovertemplate: '%%{text}<extra>topic ' + topicId + '</extra>',
          showlegend: false,
          name: 'cluster ' + topicId
        });
      };
      el.on('plotly_click', function (ev) {
        if (!ev.points || !ev.points.length) return;
        var p = ev.points[0];
        if (p.customdata == null) return;
        window.tcacSelectCluster(p.customdata);
      });
    }
    ",
    pts_json
  )

  fig <- htmlwidgets::onRender(fig, on_render)

  if (!is.na(figures_dir) && nzchar(figures_dir)) {
    save_widget_html(fig, "umap_clusters", figures_dir)
  }
  fig
}
