# TD — Future Shiny Migration

Notes for a possible later port of the TCAC 2.0 visualisations from the
static Quarto report ([TCAC 2.0 Vectorisation.qmd](TCAC 2.0 Vectorisation.qmd))
to a Shiny app. Not implemented; this captures the design decisions to
keep current so a future port is cheap.

Companion to [TD_BERTopic_Parameters.md](TD_BERTopic_Parameters.md) (the
visualisation layer consumes the BERTopic outputs documented there) and
[cloud_storage_migration.md](cloud_storage_migration.md) (Phase 2 R2
migration enables the easiest Shiny deployment model — see below).

## Why this is cheap

plotly + Shiny is a first-class integration in the R ecosystem. The
`viz_*` (data) and `fig_*` (rendered plotly) targets already produced by
the pipeline are directly usable from a Shiny app — the app would just
call `tar_read()` (or `tar_load()`) at startup or reactively.

### What ports for free

Every plotly figure built via R's plotly API (whether wrapped in
`ggplotly()` or built natively with `plot_ly()`) drops straight into
Shiny without code changes:

```r
# In ui:
plotlyOutput("umap_plot")

# In server:
output$umap_plot <- renderPlotly({
  tar_read(fig_umap)        # the qs2 object the QMD already uses
})
```

That's it. Nothing in [_targets.R](_targets.R) needs to change.

## What Shiny adds over the QMD

The QMD is **static HTML**: any interactivity has to be wired in
client-side JS (e.g. the polygon click handler discussed in the
density+polygons design for `fig_umap_clusters`). Shiny is
**server-driven**: a click is a Shiny event, the server handles it in R
and pushes the diff back to the client.

| Aspect | QMD + JS handler | Shiny server-driven |
|---|---|---|
| Implementation | ~50 lines of JS in the QMD per interaction | ~30 lines of R server logic per interaction |
| Where the cluster-points live | All clusters' points pre-loaded client-side (heavy) | Server-side, only the clicked cluster's points sent (light) |
| Filters / sliders | Each needs its own JS hook | Wired as Shiny inputs (~3 lines each) |
| Cross-filtering between plots | Painful — manual JS state | Trivial — reactive expressions |
| Deployment | Static HTML on any web host | Needs a Shiny server (shinyapps.io, Posit Connect, your own) |

**Rule of thumb**: QMD + JS is enough for one click event + one zoom
level. Shiny pays for itself within an hour of dev once you have
≥2 widgets with cross-filtering, brushing, or per-cluster server-side
data fetching.

## Reading plotly click events in Shiny

```r
# In server:
selected <- reactive({
  event_data("plotly_click", source = "umap_plot")
})

output$cluster_detail <- renderPlotly({
  click <- selected()
  if (is.null(click)) return(NULL)
  topic_id <- click$customdata     # whatever you packed into the polygon trace
  pts <- tar_read(viz_umap_cluster_pts)[[as.character(topic_id)]]
  plot_ly(pts, x = ~x, y = ~y, mode = "markers")
})
```

Full click-to-drill-down logic — ~15 lines.

## Recommended layout

```
TCAC 2.0/
  shiny/
    app.R                       <- tar_read() loads the figs at startup
    R/                          <- helpers used by app.R
  _targets.R                    <- unchanged; produces the viz_/fig_ targets
  TCAC 2.0 Vectorisation.qmd    <- unchanged; static report
```

`shiny/app.R` is independent of the QMD. Both consume the same targets
cache. No duplication.

## Performance note — heavy figures + renderPlotly

`renderPlotly()` re-serialises the figure on each render. For very
large plotly objects (millions of points, even via WebGL), the
Shiny round-trip cost can dominate user-perceived latency.

Solution: build the heavy base figure once at server startup as a
reactive value, and use `plotlyProxy()` to push *diffs* (add traces,
update styles) on user events — that avoids re-serialisation.

```r
# Build once
base_fig <- reactive({
  build_umap_clusters_base(viz_umap_density, viz_umap_hulls)
})

# Update with diffs
observeEvent(event_data("plotly_click"), {
  click <- event_data("plotly_click")
  plotlyProxy("umap_plot", session) |>
    plotlyProxyInvoke("addTraces", make_cluster_pts_trace(click$customdata))
})
```

Three-line cost for big speedup on big figures.

## Build figures with native `plot_ly()`, not `ggplotly()`, where possible

`ggplotly()` works in Shiny but click events on ggplot-converted plots
are flakier than native plotly traces — keypaper coordinates sometimes
don't round-trip cleanly into `event_data("plotly_click")`. For figures
that *might* later need Shiny click interactivity:

- Build them with `plot_ly() |> add_trace(...)` natively.
- Attach `customdata` per point/polygon for click-event payload.
- Set `source` on each plot so `event_data(source = ...)` can target it.

For figures that will only ever be static report content, `ggplotly()`
is fine and simpler.

## Deployment considerations

### QMD report (current)

Self-contained HTML via `embed-resources: true` in the front matter.
Any web host. No backend.

### Shiny app (future)

Needs:

- A Shiny server: shinyapps.io's free tier is fine for a paper
  supplement; the EU instance is GDPR-clean. Alternative: Posit Connect
  (paid), your own EC2/Hetzner box (~€5/mo).
- The `_targets/` cache shipped alongside the app, OR read from cloud
  storage if Phase 2 of [cloud_storage_migration.md](cloud_storage_migration.md)
  is done.

If Phase 2 R2 migration is complete and the Shiny route is taken,
deployment becomes "Shiny app + R2 read-only credentials" — anyone with
the URL gets live, click-through analysis without needing to clone the
repo or have the targets cache locally.

## What to do now to keep the option open

1. **Build new figures with native `plot_ly()`** where Shiny click
   interactivity is a possibility. `ggplotly()` only for static-only
   figures.
2. **Attach `customdata` to clickable traces** when authoring `fig_*`
   targets — e.g. for cluster polygons, set
   `customdata = ~topic_id`. Costs nothing if Shiny never happens;
   makes the port trivial if it does.
3. **Keep `viz_*` (data) and `fig_*` (render) targets distinct**
   (already the convention) so the Shiny app can reach into the raw
   data when it needs server-side filtering.
4. **Don't bake large data into figures**. If a figure target needs
   reference to 4.6M points, store the points in a separate `viz_*`
   target and reference by ID in the figure — the Shiny app then
   loads on demand.

These are zero-cost good habits even if Shiny never happens. They just
align the data flow with how a server-driven app would consume it.

## Open questions for if/when Shiny becomes real

1. **Deployment target**: shinyapps.io free tier (limited connection
   hours), Posit Connect (paid, full SLA), or self-hosted? Depends on
   expected audience size for the paper supplement.
2. **Persistence**: do users get URL-shareable state (e.g.
   pre-selected cluster)? `shiny::bookmarkButton()` or
   `enableBookmarking("url")` covers this in ~5 lines.
3. **Auth**: public, or gated behind reviewer credentials? Posit
   Connect handles auth; shinyapps.io doesn't.
4. **Data freshness**: app reads `_targets/` snapshot at startup
   (stale until restart) or polls/refetches on every request (slower
   but always current)? Probably "snapshot at startup; manual
   redeploy on data refresh" is fine for a paper artefact.
