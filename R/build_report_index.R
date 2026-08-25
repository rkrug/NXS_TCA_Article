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

build_report_index <- function(
  report_analysis,
  report_citation_comparison,
  out_dir = "output/reports"
) {
  entries <- list(
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

  items <- vapply(entries, function(e) {
    sprintf(
      '      <li>\n        <a href="%s">%s</a>\n        <p>%s</p>\n      </li>',
      .html_escape(e$href), .html_escape(e$title), .html_escape(e$desc)
    )
  }, character(1))

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
</body>
</html>
',
    paste(items, collapse = "\n")
  )

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  out_file <- file.path(out_dir, "index.html")
  writeLines(html, out_file)
  out_file
}
