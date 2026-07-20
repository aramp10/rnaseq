# Bowtie2 Alignment Killed by SGE Reaper for Exceeding Allocated Cores (Prokaryotic Profile)

**Author:** Andy Rampersaud
**Date:** 2026-07-20

## Ticket Information

- **Ticket:** INC20925379 (second, separate issue logged under this ticket)
- **Client:** Maya (mkostman@bu.edu)
- **Working directory:** `/projectnb/vmemseq/MPK/rnaseq`
- **Pipeline:** nf-core/rnaseq, `-profile prokaryotic,singularity`
- **Cluster:** BU Shared Computing Cluster (SCC)
- **Scheduler:** SGE
- **Date Resolved:** 2026-07-20

## Issue

The client ran nf-core/rnaseq on a Bacillus subtilis sample using `-profile prokaryotic,singularity`,
which aligns with Bowtie2+Salmon rather than STAR/HISAT2. The SCC process reaper terminated the job
(`6690045.1`, PE `omp12`) with:

```
The following batch job, running on SCC-WM2, has been terminated
because it was using 13.4 processors but was allocated only 12.
```

The client suspected this was related to temporary file storage and requested more cores (16) for the
`BOWTIE2_ALIGN` process via a custom config, but wasn't sure this was the correct process or the
correct file to edit.

## Root Cause

`BOWTIE2_ALIGN` carries `label 'process_high'` (`modules/nf-core/bowtie2/align/main.nf`), which
`conf/base.config` maps to `cpus = 12` by default — exactly matching the client's `omp12` allocation.
The 13.4-vs-12 overage is normal overhead from Bowtie2 piped directly into `samtools sort` (both need
brief CPU headroom above the declared `task.cpus`), not excessive temp-file usage as the client
suspected.

A complicating factor during diagnosis: this repo's fork (`aramp10/rnaseq`) was pinned at nf-core/rnaseq
v3.21.0, 10 commits ahead / 1075 commits behind upstream `master`. `-profile prokaryotic` and the
Bowtie2 alignment path were only added upstream in **v3.23.0** (PR #1688, 2026-02-27). At v3.21.0, the
process the client referenced (`ALIGN_BOWTIE2:BOWTIE2_ALIGN`) genuinely did not exist anywhere in the
fork's history, which initially looked like a fabricated process name. The fork was merged with
upstream `master` (merge commit `99633822`) to resolve this — see `git log` for that commit for the
full diff. Local BU SCC customizations (SGE `process{}` block, README sections) survived the merge.

## Diagnosis

Confirmed via the SCC process reaper archive and `qacct` that the terminated job really was the
Bowtie2 alignment step:

```bash
# Reaper archive: note the @scc.bu.edu address, not @bu.edu
grep -c "mkostman@scc.bu.edu" /usr1/scv/reaper/archive
grep -C 30 "mkostman@scc.bu.edu" /usr1/scv/reaper/archive | less
# job 6690045.1: owner: mkostman pe: omp12 type: "Single node batch" slots: 12

qacct -j 6690045.1
# jobname nf-NFCORE_RNASEQ_RNASEQ_ALIGN_BOWTIE2_BOWTIE2_ALIGN_(val-3-F0987)
```

Confirmed the process path (`NFCORE_RNASEQ:RNASEQ:ALIGN_BOWTIE2:BOWTIE2_ALIGN`) matches the client's
`withName` selector exactly, once the fork was synced to a version that includes it
(`subworkflows/local/align_bowtie2/main.nf`, `conf/modules/align_bowtie2.config`).

Confirmed the client's fix was actually loaded (not silently ignored) by checking her own
`.nextflow.log` in `/projectnb/vmemseq/MPK/rnaseq`:

```bash
head .nextflow.log
# $> nextflow run main.nf --outdir mpk_rnaseq_output_ncbi --input samplesheet.csv \
#    --email mkostman@bu.edu --fasta ... --gff ... \
#    -profile prokaryotic,singularity -c my_resources.config --skip_biotype_qc
#
# Found config local: /projectnb/vmemseq/MPK/rnaseq/nextflow.config
# User config file: /projectnb/vmemseq/MPK/rnaseq/my_resources.config
```

`User config file:` confirms Nextflow loaded `my_resources.config` via `-c`, so the override took effect.

## Fix

Client's custom config (`my_resources.config`, in her run directory), passed via `-c`:

```groovy
process {
    withName: '.*:ALIGN_BOWTIE2:BOWTIE2_ALIGN' {
        cpus = 16
    }
    withName: '.*:SUBREAD_FEATURECOUNTS' {
        ext.args = '-g gene_id -t CDS'
    }
}
```

Run command:

```bash
nextflow run main.nf --outdir mpk_rnaseq_output_ncbi --input samplesheet.csv \
  --email mkostman@bu.edu \
  --fasta /projectnb/vmemseq/MPK/ncbi_dataset/data/GCF_002055965.1/GCF_002055965.1_ASM205596v1_genomic.fna \
  --gff /projectnb/vmemseq/MPK/ncbi_dataset/data/GCF_002055965.1/genomic.gff \
  -profile prokaryotic,singularity -c my_resources.config --skip_biotype_qc
```

Per nf-core convention (`docs/usage.md`), resource overrides like this belong in a standalone config
passed via `-c`, not edited directly into the pipeline's own `conf/modules/align_bowtie2.config` —
which is what the client correctly did.

**Note:** bumping `cpus = 16` only helps if the SGE allocation can satisfy it — the top-level
`nextflow.config` process block sets `penv = 'omp'`, so Nextflow's SGE executor auto-requests
`-pe omp 16` for this task. Confirm the `omp` PE has 16-slot capacity available, not just 12.

## Verification

`.nextflow.log`'s `User config file:` line (see Diagnosis) confirms the override loaded correctly for
the run that produced `mpk_rnaseq_output_ncbi`.

## Notes

- `featurecounts_override.config` in the client's directory is an earlier draft of just the
  `SUBREAD_FEATURECOUNTS` portion above; superseded by `my_resources.config`, not referenced on the
  confirmed run.
- `my_resources.config.save` is an earlier backup containing only the Bowtie2 `cpus` override,
  predating the featureCounts addition.
- The client also passed `--skip_biotype_qc` directly on the command line, which skips the
  featureCounts biotype-QC step entirely (see `docs/usage.md#prokaryotic-genome-annotations`). This
  makes the `SUBREAD_FEATURECOUNTS` `ext.args` override in `my_resources.config` currently inert
  (harmless, just unused), since the step it targets doesn't run under that flag.
- Reference: [nf-core/rnaseq prokaryotic genome annotations docs](https://github.com/aramp10/rnaseq/blob/master/docs/usage.md#prokaryotic-genome-annotations)
