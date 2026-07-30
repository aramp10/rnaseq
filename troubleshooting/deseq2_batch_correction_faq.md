# Does nf-core/rnaseq Do Batch Correction? (PCA Outlier / Replicate-as-Covariate)

**Author:** Andy Rampersaud
**Date:** 2026-07-30

## Ticket Information

- **Ticket:** INC20925379 (same ticket as the Bowtie2 CPU allocation issue; this is a follow-up analysis question from the same client)
- **Client:** Maya (mkostman@bu.edu)
- **Working directory:** `/projectnb/vmemseq/MPK/rnaseq`
- **Pipeline:** nf-core/rnaseq v3.26.0, `-profile prokaryotic`
- **Date Resolved:** 2026-07-30

## Question

Client was looking at a PCA plot from her downstream DESeq2 analysis and noticed one biological
replicate appeared to be an outlier. She asked two things:

1. Does the nf-core/rnaseq pipeline do any batch correction for biological replicates?
2. Does having `replicate` in her DESeq2 design formula already account for that outlier?

## Answer

**No — the pipeline itself does no batch correction anywhere.** Walking through every stage listed in
the [output docs](https://nf-co.re/rnaseq/3.26.0/docs/output/):

- Preprocessing, alignment/quantification (STAR/Salmon/Kallisto/RSEM, Bowtie2+Salmon, HISAT2), and
  post-processing (SAMtools, UMI-tools, picard) are read/alignment-level steps with no concept of
  batch/replicate adjustment.
- QC tools (RSeQC, Qualimap, dupRadar, Preseq, Kraken2/Bracken, Sylph) are diagnostic/contamination
  screens, not statistical correction.
- The one place "batch" is conceptually relevant — the pipeline's own DESeq2 QC step
  (`modules/local/deseq2_qc`, script `bin/deseq2_qc.r`) — explicitly runs with `design=~1`
  (intercept-only, equivalent to `blind=TRUE`). Per the [pipeline docs](https://nf-co.re/rnaseq/3.26.0/docs/output/#deseq2-qc):
  this PCA/sample-distance step exists to help *reveal* batch effects and outliers, not correct for
  them. No covariate of any kind is used.

Confirmed via repo-wide grep that no batch-correction tool (`ComBat`, `sva`, `limma::removeBatchEffect`,
`RUVSeq`) is wired into any module — the only hits are prose in
`docs/usage/differential_expression_analysis/theory.md` explaining the *concept* of adding a batch term
to a design formula for users doing their own downstream analysis.

**The client's own downstream script already partially handles this — but not for the PCA.**
Her design formula:

```r
design = ~ replicate + time + condition + time:condition
```

does make DESeq2's actual statistical testing (`DESeq()`, `results()`, contrasts) account for
replicate-to-replicate variation. That part is correct.

However, her PCA is generated from `vst(dds, blind = FALSE)`, and `blind=FALSE` is easy to
misinterpret. Per DESeq2's own FAQ
(["Why after VST are there still batches in the PCA plot?"](https://bioconductor.org/packages/release/bioc/vignettes/DESeq2/inst/doc/DESeq2.html)):

> [The vst/rlog transformations use] the design formula to calculate the within-group variability (if
> blind=FALSE) ... It does not use the design to remove variation in the data. It therefore does not
> remove variation that can be associated with batch or other covariates.

So `blind=FALSE` only improves the dispersion-trend estimate used by `vst()` — it does **not** strip the
replicate effect out of the values that get plotted. An outlier replicate can still show up on the PCA
even though the design formula is already correctly specified for the actual DE results. This is
confirmed directly by DESeq2's maintainer (Michael Love) in
[this Bioconductor Support thread](https://support.bioconductor.org/p/121408/): put batch/replicate in
the design for testing; use `limma::removeBatchEffect()` separately, only for visualization.

## Fix / Recommendation

Two independent, non-conflicting options, both legitimate:

1. **Rerun excluding the outlier replicate** as a sensitivity check — confirms whether the interaction
   contrasts (e.g. `time3.conditionvalinomycin`) are being driven by that one replicate.
2. **Visualize with the replicate effect removed**, without touching the actual DE results, using the
   DESeq2-vignette-recommended pattern:

   ```r
   mm <- model.matrix(~ time + condition + time:condition, colData(vsd))
   mat <- limma::removeBatchEffect(assay(vsd), batch = vsd$replicate, design = mm)
   assay(vsd) <- mat
   plotPCA(vsd, intgroup = "condition")
   ```

   The `design` argument must include every term of interest *except* the factor being removed
   (`replicate`), or real `time`/`condition` signal risks being stripped out along with the replicate
   effect. **Never** feed the corrected matrix back into `DESeq()`/`results()` — it's for plotting only.

Despite `limma`'s microarray-era name, `removeBatchEffect()` operates on any log-scale expression
matrix (confirmed via its own [package documentation](https://rdrr.io/bioc/limma/man/removeBatchEffect.html):
"a numeric matrix, or any data object... containing log-expression values") and is the standard tool for
this in RNA-seq workflows too.

## Companion Script

See [`scripts/annotate_and_run_deseq2_template.R`](scripts/annotate_and_run_deseq2_template.R) — a
genericized version of the client's actual downstream analysis script (paths replaced with
placeholders), annotated with the design-formula note above and the optional `removeBatchEffect`
visualization step (commented out by default).

## References

- [nf-core/rnaseq 3.26.0 output docs](https://nf-co.re/rnaseq/3.26.0/docs/output/)
- [nf-core/rnaseq differential expression theory docs](https://github.com/nf-core/rnaseq/blob/3.26.0/docs/usage/differential_expression_analysis/theory.md)
- [DESeq2 vignette FAQ: "Why after VST are there still batches in the PCA plot?"](https://bioconductor.org/packages/release/bioc/vignettes/DESeq2/inst/doc/DESeq2.html)
- [Bioconductor Support: Michael Love on design vs. removeBatchEffect](https://support.bioconductor.org/p/121408/)
- [limma `removeBatchEffect` documentation](https://rdrr.io/bioc/limma/man/removeBatchEffect.html)
