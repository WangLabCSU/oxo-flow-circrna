#!/usr/bin/env Rscript
# Generate HTML report for circRNA analysis
# Usage: Rscript generate_report.R <input_dir> <output_file>

library(data.table)

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) stop("Usage: Rscript generate_report.R <input_dir> <output_file>")

InDir <- args[1]
OutFile <- args[2]

aggr_files <- list.files(InDir, pattern = "aggr\\.txt$", full.names = TRUE)
if (length(aggr_files) == 0) stop("No aggregation files found")

# zero-calls placeholder lines ("No circRNAs detected for <sample>")
# fread as 1-column tables — treat them as empty aggregates so the
# report renders the zero state instead of strsplit failing on NULL.
read_aggr <- function(f) {
    d <- tryCatch(fread(f, sep = "\t"), error = function(e) NULL)
    if (is.null(d) || nrow(d) == 0 ||
        !all(c("tool", "count", "sample") %in% names(d))) {
        return(data.table(tool = character(0), count = numeric(0),
                          chr = character(0), start = integer(0),
                          end = integer(0), strand = character(0),
                          gene = character(0), sample = character(0)))
    }
    d
}
data <- rbindlist(lapply(aggr_files, read_aggr), use.names = TRUE, fill = TRUE)
samples <- unique(data$sample)

n_circrna <- nrow(data)
n_samples <- length(samples)
methods_used <- unique(unlist(strsplit(data$tool, ",")))

html <- paste0('<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>circRNA Analysis Report</title>
<style>
body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
.container { max-width: 1200px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
h1 { color: #2c3e50; border-bottom: 3px solid #3498db; padding-bottom: 10px; }
h2 { color: #34495e; margin-top: 30px; }
.stats { display: flex; flex-wrap: wrap; gap: 20px; margin: 20px 0; }
.stat-box { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 20px; border-radius: 10px; min-width: 150px; text-align: center; }
.stat-box h3 { margin: 0; font-size: 2em; }
.stat-box p { margin: 5px 0 0; opacity: 0.9; }
table { width: 100%; border-collapse: collapse; margin: 20px 0; }
th, td { padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }
th { background: #3498db; color: white; }
tr:hover { background: #f8f9fa; }
</style>
</head>
<body>
<div class="container">
<h1>circRNA Analysis Report</h1>
<div class="stats">
<div class="stat-box"><h3>', n_samples, '</h3><p>Samples</p></div>
<div class="stat-box"><h3>', n_circrna, '</h3><p>Total circRNAs</p></div>
<div class="stat-box"><h3>', length(unique(data$gene)), '</h3><p>Unique Genes</p></div>
<div class="stat-box"><h3>', length(methods_used), '</h3><p>Methods</p></div>
</div>
<h2>Methods</h2>
<p>Detection methods: ', paste(methods_used, collapse = ", "), '</p>
<h2>Top circRNAs</h2>
<table>
<tr><th>Gene</th><th>Chr</th><th>Start</th><th>End</th><th>Strand</th><th>Avg Count</th><th>Methods</th></tr>
')

top <- data[, .(avg = mean(count)), by = .(gene, chr, start, end, strand, tool)][order(-avg)][1:min(20, nrow(data))]
for (i in 1:nrow(top)) {
  html <- paste0(html, "<tr><td>", top$gene[i], "</td><td>", top$chr[i], "</td><td>",
                 top$start[i], "</td><td>", top$end[i], "</td><td>", top$strand[i],
                 "</td><td>", round(top$avg[i], 1), "</td><td>", top$tool[i], "</td></tr>")
}

html <- paste0(html, "</table>
<h2>Provenance</h2>
<p>Report generated: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "</p>
<p>Pipeline: oxo-flow-circrna v1.0.0</p>
</div>
</body>
</html>")

writeLines(html, OutFile)
message("Report saved to: ", OutFile)
