# Nextflow nf-core/rnaseq: dupRadar Troubleshooting Log

**Author:** Andy Rampersaud  
**Date:** 2025-06-11


## Background

**Client:** Elias (davey-lab)  
**Working directory:** `/projectnb/davey-lab/Elias/PTMomics/NF_rnaseq`  
**Pipeline:** nf-core/rnaseq  
**Issue reported:** Error during transcript mapping stage after concatenating human and viral (EBOV, MARV) reference `.fa` and `.gtf` files.



## Step 1: Confirm the pipeline did not complete

```bash
cd /projectnb/davey-lab/Elias/PTMomics/NF_rnaseq

grep 'Pipeline completed' .nextflow.log
# Jun-11 02:58:45.959 [main] INFO nextflow.Nextflow - -[nf-core/rnaseq] Pipeline completed with errors-

grep 'WorkflowStats' .nextflow.log
# WorkflowStats[succeededCount=373; failedCount=1; pendingCount=40; ...]
```

**Finding:** 373 tasks succeeded, 1 failed, and 40 were left pending (aborted) as a result of the failure.



## Step 2: Identify the failing process

```bash
grep 'error \[nextflow' .nextflow.log
# error [nextflow.exception.ProcessFailedException]: Process
# `NFCORE_RNASEQ:RNASEQ:BAM_QC_RNASEQ:DUPRADAR (MOCK_20HPI_REP2)`
# terminated with an error exit status (1)
```

**Finding:** The failure was in the `DUPRADAR` QC process, not in alignment or quantification.



## Step 3: Locate the work directory for the failed task

```bash
grep 'DUPRADAR' .nextflow.log | grep 'workDir'
# TaskHandler[id: 395; name: NFCORE_RNASEQ:RNASEQ:BAM_QC_RNASEQ:DUPRADAR (MOCK_20HPI_REP2);
# status: COMPLETED; exit: 1;
# workDir: work/7e/04461a984b02ce7b7300927a222383]
```



## Step 4: Inspect the error log for the failed task

```bash
cat work/7e/04461a984b02ce7b7300927a222383/.command.log
# || Annotation : grch38_ebov_marv_agat.filtered.gtf (GTF)
# ...
# ERROR: failed to find the gene identifier attribute in the 9th column of the provided GTF file.
# The specified gene identifier attribute is 'gene_id'
# An example of attributes included in your GTF annotation is 'gene_id "nbis-gene-1";
# transcript_id "gene-ZEBOVgp4"; ...'
# No counts were generated.
```

**Finding:** The error is coming from `featureCounts` (used internally by dupRadar). It cannot parse the `gene_id` attribute in the filtered GTF produced by the pipeline from the client's viral GTF (`grch38_ebov_marv_agat.gtf`).

The GTF passed to dupRadar is a pipeline-generated filtered version: `grch38_ebov_marv_agat.filtered.gtf`.



## Step 5: Inspect the viral GTF entries

The params file confirmed the GTF path:

```bash
cat rnaseq-params.json
# {
#     "input": "samplesheet.csv",
#     "fasta": "/projectnb/davey-lab/Elias/PTMomics/genomes/host_virus/grch38_ebov_marv.fa",
#     "gtf": "/projectnb/davey-lab/Elias/PTMomics/genomes/host_virus/grch38_ebov_marv_agat.gtf",
# ...
```

Checking sequence names in the GTF confirmed the viral entries use NCBI accession IDs:

```bash
cut -f1 /projectnb/davey-lab/Elias/PTMomics/genomes/host_virus/grch38_ebov_marv_agat.gtf | sort -u | grep -v "^#"
# ...
# NC_001608.4   <- MARV
# NC_002549.1   <- EBOV
# ...
```

Checking feature types in the viral entries:

```bash
grep 'NC_002549.1' /projectnb/davey-lab/Elias/PTMomics/genomes/host_virus/grch38_ebov_marv_agat.gtf | awk '{print $3}' | sort -u
# CDS
# exon
# five_prime_utr
# gene
# three_prime_utr
# transcript
```

**Finding:** The viral GTF contains non-standard feature types (`five_prime_utr`, `three_prime_utr` in lowercase) produced by AGAT during the GTF conversion. The `.command.log` also shows that attribute values appear malformed in the filtered GTF (e.g. `transcript_id` contains a gene ID value), which is likely the direct cause of the featureCounts failure.



## Root Cause

`featureCounts` (called internally by dupRadar) cannot correctly parse the `gene_id` attribute in the pipeline-generated filtered GTF derived from the client's AGAT-processed viral GTF. The non-standard formatting of the viral annotations is the likely cause.



## Fix Applied

Since dupRadar appears to be a QC-only step, the simplest fix is to skip it. Added to `rnaseq-params.json`:

```json
"skip_dupradar": true
```

Documented at: https://nf-co.re/rnaseq/3.14.0/parameters/

Rerun command:

```bash
cd /projectnb/davey-lab/Elias/PTMomics/NF_rnaseq/
nextflow run nf-core/rnaseq -resume -params-file rnaseq-params.json
```

The `-resume` flag will attempt to reuse completed tasks.



## Notes

- A more thorough fix would involve reformatting the viral GTF upstream (before passing it to the pipeline) to ensure all entries have properly formatted attributes. This can be revisited if the GTF causes issues in other downstream steps.
- The human GTF entries follow standard Ensembl formatting and are not affected.
- Viral sequences in the GTF are identified by NCBI accessions `NC_002549.1` (EBOV) and `NC_001608.4` (MARV).
