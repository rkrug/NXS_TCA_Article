# Static landing page linking to the two rendered reports. Deliberately plain
# HTML/CSS (no Quarto render) -- it only needs to exist once both reports have
# been copied into out_dir, and it reads their filenames directly rather than
# duplicating the config-name logic that produced them.
.html_escape <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  x
}

# The TD_*.md docs link to each other by their own filename
# (`[TD_X.md](TD_X.md)`), which is correct for reading them as source on
# GitHub. Quarto's standalone (non-project) render does not rewrite those
# cross-document links, so once copied into out_dir as TD_X.html they would
# 404. Rewrite them post-render instead of touching the source links.
fix_td_cross_links <- function(html_path) {
  txt <- readLines(html_path, warn = FALSE)
  txt <- gsub('href="(TD_[A-Za-z]+)\\.md"', 'href="\\1.html"', txt)
  writeLines(txt, html_path)
  invisible(html_path)
}

build_report_index <- function(
  report_analysis,
  report_citation_comparison,
  td_vectorisation,
  td_runpod_setup,
  out_dir = "output/reports"
) {
  reports <- list(
    list(
      href = basename(report_analysis),
      title = "Linkage TCA Approaches - TCA Actions",
      desc = paste(
        "Definition coherence and keyset linkage: how the TCA Approaches and",
        "TCA Actions definitions relate to one another by semantic",
        "similarity (embeddings) and by shared citations, ending in the",
        "Approach × Action heatmap (semantic similarity, confirmed by",
        "citation overlap) that is the project's central figure."
      )
    ),
    list(
      href = basename(report_citation_comparison),
      title = "Citation Identification Method Comparison",
      desc = paste(
        "Compares the two methods used to extract in-text citations from the",
        "concept definitions -- a deterministic regex parser and an LLM",
        "(OpenRouter) -- including where they agree, where they disagree,",
        "and citations neither could resolve."
      )
    )
  )

  design_docs <- list(
    list(
      href = basename(td_vectorisation),
      title = "TD -- Vectorisation (TEI embeddings)",
      desc = paste(
        "Design note on the embedding model and text handling: which model",
        "is active, how title/abstract are joined, and how the embedding",
        "pipeline is structured."
      )
    ),
    list(
      href = basename(td_runpod_setup),
      title = "TD -- Running the TEI embedding server on RunPod",
      desc = paste(
        "Design note on the RunPod side: starting/stopping the TEI pod that",
        "serves embeddings to the pipeline, and where the pod images come",
        "from."
      )
    )
  )

  render_items <- function(entries) {
    vapply(entries, function(e) {
      sprintf(
        '      <li>\n        <a href="%s" target="_blank" rel="noopener">%s</a>\n        <p>%s</p>\n      </li>',
        .html_escape(e$href), .html_escape(e$title), .html_escape(e$desc)
      )
    }, character(1))
  }

  html <- sprintf(
    '<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>NXS TCA Article -- Reports</title>
<style>
  body { font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
         max-width: 42rem; margin: 3rem auto; padding: 0 1.5rem; color: #222; }
  h1 { font-size: 1.4rem; }
  h2 { font-size: 1rem; color: #666; margin-top: 2.5rem; }
  ul { list-style: none; padding: 0; }
  li { margin: 1.5rem 0; padding: 1rem 1.25rem; border: 1px solid #ddd;
       border-radius: 6px; }
  li a { font-size: 1.1rem; font-weight: 600; text-decoration: none;
         color: #1a5fb4; }
  li a:hover { text-decoration: underline; }
  li p { margin: 0.5rem 0 0; color: #444; }
</style>
</head>
<body>
<h1>NXS TCA Article -- Reports</h1>
<ul>
%s
</ul>
<h2>Design docs</h2>
<ul>
%s
</ul>
</body>
</html>
',
    paste(render_items(reports), collapse = "\n"),
    paste(render_items(design_docs), collapse = "\n")
  )

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  out_file <- file.path(out_dir, "index.html")
  writeLines(html, out_file)
  out_file
}
