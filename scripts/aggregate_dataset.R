#!/usr/bin/env Rscript
# Aggregate circRNA results across multiple samples
# Usage: Rscript aggregate_dataset.R <input_dir> <output_dir> [sample_list]

library(data.table)

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
    stop("Usage: Rscript aggregate_dataset.R <input_dir> <output_dir> [sample_list]")
}

InDir <- args[1]
OutDir <- args[2]
AllSampleList <- if (length(args) >= 3) args[3] else NULL

stopifnot(dir.exists(InDir))
if (!dir.exists(OutDir)) dir.create(OutDir, recursive = TRUE)

message("Scanning result files...")
fileList <- list.files(InDir, pattern = "aggr\\.txt$", full.names = TRUE)
fileList <- fileList[file.info(fileList)$size > 0]
if (length(fileList) == 0) stop("No aggregation files found")

sample_ids <- gsub("\\.aggr\\.txt$", "", basename(fileList))
message("Samples: ", length(sample_ids))

if (!is.null(AllSampleList) && nchar(AllSampleList) > 0) {
    # Accept comma-separated list or CSV file path
    if (grepl(",", AllSampleList)) {
        all_samples <- strsplit(AllSampleList, ",")[[1]]
    } else if (file.exists(AllSampleList)) {
        all_samples <- fread(AllSampleList, header = FALSE, sep = "\t")[[1]]
    } else {
        all_samples <- AllSampleList
    }
    diff_samples <- setdiff(all_samples, sample_ids)
    if (length(diff_samples) > 0) message("Missing samples: ", paste(diff_samples, collapse = ", "))
}

message("Merging results...")
read_one <- function(f) {
    d <- tryCatch(fread(f, sep = "\t"), error = function(e) NULL)
    if (is.null(d) || nrow(d) == 0 ||
        !all(c("gene", "strand", "chr", "start", "end") %in% names(d))) {
        # per-sample aggregate wrote the zero-calls placeholder
        # ("No circRNAs detected for <sample>") — nothing to merge
        return(data.table(gene = character(0), strand = character(0),
                          chr = character(0), start = integer(0),
                          end = integer(0), count = numeric(0),
                          sample = character(0)))
    }
    d
}
AllData <- rbindlist(lapply(fileList, read_one), use.names = TRUE, fill = TRUE)

out_path <- file.path(OutDir, paste0(basename(InDir), "_circRNA.tsv.gz"))
if (nrow(AllData) == 0) {
    # zero calls across all samples — emit the canonical empty matrix
    message("No circRNAs in any sample — writing an empty matrix")
    fwrite(data.table(id = character(0), gene = character(0),
                      strand = character(0), chrom = character(0),
                      startUpBSE = integer(0), endDownBSE = integer(0),
                      tool = character(0)),
           file = out_path, sep = "\t")
    message("Output: ", out_path)
    message("Total circRNAs: 0")
    quit(save = "no", status = 0)
}

AllData[, id := paste(gene, strand, chr, start, end, sep = ":")]
AllData[, tool := "four_methods"]
AllData <- dcast(AllData, id + gene + strand + chr + start + end + tool ~ sample, value.var = "count", fill = 0)
colnames(AllData)[1:7] <- c("id", "gene", "strand", "chrom", "startUpBSE", "endDownBSE", "tool")

if (!is.null(AllSampleList) && file.exists(AllSampleList) && length(diff_samples) > 0) {
    message("Filling missing samples with 0...")
    AllData[, (diff_samples) := 0]
}

out_path <- file.path(OutDir, paste0(basename(InDir), "_circRNA.tsv.gz"))
fwrite(AllData, file = out_path, sep = "\t")
message("Output: ", out_path)
message("Total circRNAs: ", nrow(AllData))
