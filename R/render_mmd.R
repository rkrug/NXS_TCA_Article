# Render Mermaid diagram sources (.mmd) to SVG + PNG via mermaid-cli (mmdc).
#
# Used by the `mmd_figs` target. Pre-rendering with mermaid-cli (rather than
# embedding raw ```{mermaid} blocks in the report) is what lets the diagrams
# use features Quarto's bundled browser-mermaid doesn't support — notably the
# `layout: elk` engine and custom themes set in the .mmd frontmatter.
#
# Requires mermaid-cli on the machine: either `mmdc` on PATH
# (npm i -g @mermaid-js/mermaid-cli) or `npx @mermaid-js/mermaid-cli`
# (needs a Chromium for Puppeteer). Errors loudly if it can't produce output.
#
# Returns the vector of produced files (one .svg and one .png per input),
# so the target is format = "file".

render_mmd <- function(mmd_files, out_dir = "output/figures/mmd") {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  mmdc <- Sys.which("mmdc")
  run <- if (nzchar(mmdc)) {
    function(args) system2(mmdc, args, stdout = TRUE, stderr = TRUE)
  } else {
    function(args) {
      system2("npx", c("-y", "@mermaid-js/mermaid-cli", args),
              stdout = TRUE, stderr = TRUE)
    }
  }

  outs <- character(0)
  for (f in mmd_files) {
    stem <- tools::file_path_sans_ext(basename(f))
    for (fmt in c("svg", "png")) {
      out <- file.path(out_dir, paste0(stem, ".", fmt))
      res <- run(c("--input", f, "--output", out))
      status <- attr(res, "status")
      if ((!is.null(status) && status != 0L) || !file.exists(out)) {
        stop(
          "mermaid-cli (mmdc) failed to render ", f, " -> ", out,
          ". Is mermaid-cli installed (npm i -g @mermaid-js/mermaid-cli)?\n",
          paste(res, collapse = "\n")
        )
      }
      outs <- c(outs, out)
    }
  }
  outs
}
