# ============================================================
# Template: downstream DESeq2 analysis on nf-core/rnaseq output
# (Bowtie2+Salmon / prokaryotic profile, gene-level counts)
#
# See ../deseq2_batch_correction_faq.md for the discussion this
# script accompanies (replicate-as-covariate design, PCA vs. actual
# DE results, and using limma::removeBatchEffect for visualization).
#
# Update the paths in Section 1/2/3 for your own project before running.
# ============================================================

library(DESeq2)
library(tidyverse)
library(pheatmap)
library(rtracklayer)
library(ggplot2)
library(ggrepel)
library(dplyr)

# ============================================================
# 1. Read count matrix
# ============================================================

counts_full <- read.delim(
"/path/to/your/rnaseq_output/bowtie2_salmon/salmon.merged.gene_counts.tsv"
)

# Keep annotation information separately
gene_annotation <- counts_full %>%
select(gene_id, gene_name)

# Set gene IDs as row names for annotation lookup
rownames(gene_annotation) <- gene_annotation$gene_id


# Extract count matrix only
counts <- counts_full %>%
select(-gene_id, -gene_name)

rownames(counts) <- counts_full$gene_id


# ============================================================
# 2. Add NCBI product annotations from GFF
# ============================================================

gff <- import(
"/path/to/your/ncbi_dataset/data/GCF_XXXXXXXXX.X/genomic.gff"
)

gff_df <- as.data.frame(gff)


# Products are stored on CDS entries
product_annotation <- gff_df %>%
filter(type == "CDS") %>%
select(
locus_tag,
product
) %>%
distinct()


# Match NCBI locus tags to Salmon gene IDs
product_annotation <- product_annotation %>%
mutate(
gene_id = paste0("gene-", locus_tag)
) %>%
select(
gene_id,
product
)


# Merge product annotation with gene names
gene_annotation <- gene_annotation %>%
left_join(
product_annotation,
by = "gene_id"
)


# Restore row names
rownames(gene_annotation) <- gene_annotation$gene_id


# Check annotation
head(gene_annotation)


# ============================================================
# 3. Read metadata
# ============================================================

metadata <- read.csv(
"/path/to/your/metadata/rnaseq_metadata.csv",
row.names = 1
)


metadata$condition <- factor(metadata$condition)
metadata$time <- factor(metadata$time)
metadata$replicate <- factor(metadata$replicate)

metadata$time <- factor(
metadata$time,
levels = c("1", "2", "3")
)


# ============================================================
# 4. Match samples
# ============================================================

colnames(counts) <- gsub("\\.", "-", colnames(counts))

# Check sample matching
colnames(counts)
rownames(metadata)

counts <- counts[, rownames(metadata)]

all(colnames(counts) == rownames(metadata))


# ============================================================
# 5. Create DESeq2 object
# ============================================================

# NOTE: including `replicate` here accounts for replicate-to-replicate
# variation in the actual DE testing (results()/contrasts below), but it
# does NOT remove that variation from the PCA further down -- see the FAQ
# doc for why, and for the optional removeBatchEffect() visualization step.
dds <- DESeqDataSetFromMatrix(
countData = round(counts),
colData = metadata,
design = ~ replicate + time + condition + time:condition
)


# ============================================================
# 6. Run DESeq2
# ============================================================

dds <- DESeq(dds)

resultsNames(dds)

# function
analyze_DESeq_result <- function(dds,
gene_annotation,
padj_cutoff = 0.05,
lfc_cutoff = 1,
...) {

# Extract DESeq2 results
res <- results(dds, ...)

# Convert to dataframe
res_df <- as.data.frame(res)

# Store gene IDs as a column
res_df$gene_id <- rownames(res_df)

# Add gene names
res_df$gene <- gene_annotation[res_df$gene_id, "gene_name"]

# Add significance
res_df$significant <- "no"

res_df$significant[
!is.na(res_df$padj) &
res_df$padj < padj_cutoff &
abs(res_df$log2FoldChange) > lfc_cutoff
] <- "yes"

# Add direction
res_df$direction <- "NS"

res_df$direction[
res_df$significant == "yes" &
res_df$log2FoldChange > 0
] <- "up"

res_df$direction[
res_df$significant == "yes" &
res_df$log2FoldChange < 0
] <- "down"

return(res_df)
}
# DMSO time comparisons
dmso_time2 <- analyze_DESeq_result(
dds,
gene_annotation = gene_annotation,
name = "time_2_vs_1"
)

dmso_time3 <- analyze_DESeq_result(
dds,
gene_annotation = gene_annotation,
name = "time_3_vs_1"
)

dmso_time3_vs2 <- analyze_DESeq_result(
dds,
gene_annotation = gene_annotation,
contrast = list(
c("time_3_vs_1"),
c("time_2_vs_1")
)
)

# val time comparisons
val_time2 <- analyze_DESeq_result(
dds,
gene_annotation = gene_annotation,
contrast = list(
c("time_2_vs_1",
"time2.conditionvalinomycin")
)
)

val_time3 <- analyze_DESeq_result(
dds,
gene_annotation = gene_annotation,
contrast = list(
c("time_3_vs_1",
"time3.conditionvalinomycin")
)
)

val_time3_vs2 <- analyze_DESeq_result(
dds,
gene_annotation = gene_annotation,
contrast = list(
c("time_3_vs_1",
"time3.conditionvalinomycin"),
c("time_2_vs_1",
"time2.conditionvalinomycin")
)
)

#compare across conditions
# Valinomycin vs DMSO at time 2
val_vs_dmso_time2 <- analyze_DESeq_result(
dds,
gene_annotation = gene_annotation,
contrast = list(
c("condition_valinomycin_vs_DMSO",
"time2.conditionvalinomycin")
)
)

# Valinomycin vs DMSO at time 3
val_vs_dmso_time3 <- analyze_DESeq_result(
dds,
gene_annotation = gene_annotation,
contrast = list(
c("condition_valinomycin_vs_DMSO",
"time3.conditionvalinomycin")
)
)

# changes specific to valinomycin over time
val_blocks_dmso_time2 <- analyze_DESeq_result(
dds,
gene_annotation = gene_annotation,
name = "time2.conditionvalinomycin"
)
val_blocks_dmso_time3 <- analyze_DESeq_result(
dds,
gene_annotation = gene_annotation,
name = "time3.conditionvalinomycin"
)

# ============================================================
# 7. PCA checks
# ============================================================
# 1. Variance-stabilize the counts
vsd <- vst(dds, blind = FALSE)
# 2. PCA colored by condition
plotPCA(vsd, intgroup = "condition")
# 3. PCA colored by time
plotPCA(vsd, intgroup = "time")
#4. PCA colored by condition and time
vsd$group <- paste(vsd$condition, vsd$time, sep = "_")
plotPCA(vsd, intgroup = "group")

# Get PCA coordinates
pcaData <- plotPCA(
vsd,
intgroup = c("condition", "time", "exp"),
returnData = TRUE
)

# Percent variance explained
percentVar <- round(100 * attr(pcaData, "percentVar"))

ggplot(
pcaData,
aes(
x = PC1,
y = PC2,
color = condition,
shape = time
)
) +
geom_point(size = 4) +
geom_text_repel(
aes(label = exp),
size = 4,
max.overlaps = Inf
) +
xlab(paste0("PC1: ", percentVar[1], "% variance")) +
ylab(paste0("PC2: ", percentVar[2], "% variance")) +
theme_classic()

# --- Optional: visualize with replicate effect removed ---------------
# Only for the PCA plot -- never feed the corrected matrix back into
# DESeq()/results(). `design` below must include every term of interest
# EXCEPT the batch/replicate factor being removed, or you risk stripping
# out real time/condition signal along with it.
#
# mm <- model.matrix(~ time + condition + time:condition, colData(vsd))
# mat_corrected <- limma::removeBatchEffect(assay(vsd), batch = vsd$replicate, design = mm)
# assay(vsd) <- mat_corrected
# plotPCA(vsd, intgroup = "condition")
# -----------------------------------------------------------------------


# volcano plots fun
plot_volcano <- function(res_df, title = "", top_n = 50) {

# Remove genes without statistics
res_df <- res_df[
!is.na(res_df$padj) &
!is.na(res_df$log2FoldChange),
]

# Select top significant genes for labeling
label_df <- res_df %>%
filter(significant == "yes") %>%
arrange(padj) %>%
slice_head(n = top_n)

p <- ggplot(res_df,
aes(x = log2FoldChange,
y = -log10(padj),
color = direction)) +

geom_point(alpha = 0.6, size = 1.5) +

scale_color_manual(values = c(
up = "red",
down = "blue",
NS = "grey70"
)) +

geom_vline(
xintercept = c(-1, 1),
linetype = "dashed"
) +

geom_hline(
yintercept = -log10(0.05),
linetype = "dashed"
) +

geom_text_repel(
data = label_df,
aes(label = gene),
size = 3,
max.overlaps = Inf
) +

labs(
title = title,
x = "Log2 Fold Change",
y = "-Log10 Adjusted P-value"
) +

theme_classic()
return(p)

}

val_blocks_dmso_time2_vol <- plot_volcano(
val_blocks_dmso_time2,
"Valinomycin blocks DMSO response (Time 2 interaction)",
top_n = 50
)

val_blocks_dmso_time3_vol <- plot_volcano(
val_blocks_dmso_time3,
"Valinomycin blocks DMSO response (Time 3 interaction)",
top_n = 50
)
