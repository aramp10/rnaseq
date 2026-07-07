# Nextflow nf-core/rnaseq: StringTie Segfault Troubleshooting Log

**Author:** Andy Rampersaud
**Date:** 2026-05-27

## Ticket Information

- **Ticket:** INC20898027
- **Client:** Alejandra Camargo (acamargo@bu.edu), mullenl group
- **Pipeline:** nf-core/rnaseq v3.26.0
- **Cluster:** BU Shared Computing Cluster (SCC)
- **Scheduler:** SGE
- **Date Resolved:** 2026-05-27

---

## Problem Description

The client's nf-core/rnaseq pipeline was failing at the StringTie step with a segmentation fault:

```
.command.sh: line 11: 40 Segmentation fault stringtie BSC1-3-2.markdup.sorted.bam \
  --rf -G blackglaucus_annotation.clean.filtered.gtf \
  -o BSC1-3-2.transcripts.gtf -A BSC1-3-2.gene.abundance.txt \
  -C BSC1-3-2.coverage.gtf -b BSC1-3-2.ballgown -p 12 -v -e
```

- **Failed sample:** BSC1-3-2
- **Exit code:** 139 (segfault)
- **StringTie version:** 2.2.3
- **Pipeline work directory:** `/projectnb/mullenl/alejandra/analysis/rnaseq/nfcore/rnaseq/`

---

## Investigation Steps

### Step 1: Rule Out BAM Corruption

```bash
samtools quickcheck BSC1-3-2.markdup.sorted.bam  # BAM OK
samtools view -c BSC1-3-2.markdup.sorted.bam      # 61,228,460 reads
```

BAM file was intact and not corrupted.

### Step 2: Check Chromosome Name Consistency

```bash
samtools view -H BSC1-3-2.markdup.sorted.bam | grep "^@SQ" | awk '{print $2}' | sed 's/SN://' | head -20
grep -v "^#" blackglaucus_annotation.clean.filtered.gtf | awk '{print $1}' | sort -u | head -20
```

Both BAM and GTF used `scaffold_N` naming — no mismatch.

### Step 3: Check Memory Usage via qacct

Retrieved SGE job ID from Nextflow log:

```bash
grep "e6/799c" /projectnb/mullenl/alejandra/analysis/rnaseq/nfcore/rnaseq/.nextflow.log.1 | grep -i "jobid\|submitted\|stringtie"
# jobId: 5789966
qacct -j 5789966
```

**Key qacct fields:**

| Field | Value | Notes |
|---|---|---|
| `hostname` | scc-pf4.scc.bu.edu | Node the job ran on |
| `exit_status` | 139 | Segfault confirmed |
| `failed` | 0 | SGE itself did not kill the job |
| `ru_wallclock` | 717s | Job ran ~12 minutes |
| `ru_maxrss` | 5,908,488 KB (~5.6 GB) | Peak RAM (more reliable than maxvmem) |
| `mem` | 8712.526 GB·s ÷ 717s = ~12 GB | Average RAM usage (most reliable) |
| `maxvmem` | 9.919G | **Not reliable, ignore** |
| `slots` | 16 | Cores granted |
| `granted_pe` | omp16 | Parallel environment |

**Conclusion:** The job used only ~12 GB of RAM despite being allocated 128 GB. Memory was **not** the cause of the segfault.

#### Finding the SGE Job ID from Nextflow Logs — Procedure

1. Get the work directory from the Nextflow error output
2. Note the short prefix (e.g. `e6/799c`)
3. Find the right log file by matching timestamps: `ls -lh /path/to/nextflow/.nextflow.log*`
4. Search the log: `grep "e6/799c" .nextflow.log.1 | grep -i "jobid\|submitted"`
5. Look for: `[SGE] submitted process ... > jobId: XXXXXXX`
6. Run: `qacct -j XXXXXXX`

### Step 4: Identify the Problematic Bundle (First Pass)

From `.command.err`, StringTie crashed while processing:

```
scaffold_8:3685006-14276347 done (48840 processed potential transcripts)  # first run
scaffold_9:3404796-6288965                                                 # second run
```

The crash location varied between runs, suggesting the root cause was not scaffold-specific but rather bundle complexity.

### Step 5: Investigate the GTF File

```bash
# Check feature types
grep -v "^#" blackglaucus_annotation.clean.filtered.gtf | awk '{print $3}' | sort | uniq -c | sort -rn
# 3724508 transcript
#  107087 exon
#  103762 CDS

# Check annotation sources
awk '{print $2}' blackglaucus_annotation.clean.filtered.gtf | sort | uniq -c | sort -rn
# 1616316 repeat_gff:repeatmasker
# 1402186 protein_gff:protein2genome
#  378032 est_gff:est2genome
#  243009 maker
#  213164 snap_masked
#   98795 augustus_masked
#      167 repeat_gff:repeatrunner
```

**Key finding:** Roughly 40% of the GTF (1.6 million out of 3.95 million entries) were RepeatMasker entries, not gene models. These were inflating bundle sizes by connecting distant genomic regions. (Note: the feature-type tally above sums to ~3.94M vs. the ~3.95M total line count — the annotation-source tally accounts for the full total exactly, so the discrepancy is a minor gap in the feature-type capture, not in the underlying diagnosis.)

### Step 6: Memory Configuration Fix (Attempted, Not Root Cause)

Added to `nextflow.config`:

```groovy
process {
    withName: "STRINGTIE_STRINGTIE" {
        memory = 128.GB
        cpus   = 16
    }
}
```

This increased memory from 36 GB (`process_medium`) to 128 GB. The job still segfaulted, confirming memory was not the issue.

**Note on BU SCC memory tiers:**

| Memory needed | qsub options |
|---|---|
| ≤ 128 GB | `-pe omp 16` |
| ≤ 256 GB | `-pe omp 16 -l mem_per_core=16G` |
| ≤ 384 GB | `-pe omp 28 -l mem_per_core=13G` |
| ≤ 512 GB | `-pe omp 28 -l mem_per_core=18G` |

### Step 7: Reproduce the Issue Manually

Input files copied from client's work directory:

```bash
# As client (beuser acamargo):
mkdir -p $TMPDIR/$USER/to_aramp10
cp /projectnb/mullenl/alejandra/analysis/rnaseq/nfcore/rnaseq/work/41/364c5e5b4a509122d14e242f8b12bb/BSC1-3-2.markdup.sorted.bam $TMPDIR/$USER/to_aramp10/
cp /projectnb/mullenl/alejandra/analysis/rnaseq/nfcore/rnaseq/work/f5/276be9edd9fdea9d2f78977e6426cd/blackglaucus_annotation.clean.filtered.gtf $TMPDIR/$USER/to_aramp10/

# As myself:
cp /net/scc4/scratch/acamargo/to_aramp10/* /projectnb/ar-rcs/client/acamargo/INC20898027_Nextflow_RNAseq/rnaseq/StringTie_test/
```

Test command (using same container as pipeline):

```bash
cd /projectnb/ar-rcs/client/acamargo/INC20898027_Nextflow_RNAseq/rnaseq/StringTie_test

time singularity exec \
    --no-home --pid \
    -B /projectnb/ar-rcs/client/acamargo/INC20898027_Nextflow_RNAseq/rnaseq/StringTie_test \
    /projectnb/mullenl/alejandra/analysis/rnaseq/nfcore/rnaseq/work/singularity/depot.galaxyproject.org-singularity-stringtie-2.2.3--h43eeafb_0.img \
    stringtie \
    BSC1-3-2.markdup.sorted.bam \
    --rf \
    -G blackglaucus_annotation.clean.filtered.gtf \
    -o test.gtf \
    -A test.gene.abundance.txt \
    -C test.coverage.gtf \
    -b test.ballgown \
    -p 16 \
    -v -e > test.log 2>&1
```

**Note:** Always use `.command.run` as reference for the exact Singularity bind mounts used by Nextflow:

```bash
cat .command.run | grep "nxf_launch"
# -B /projectnb/mullenl/alejandra/analysis/rnaseq/nfcore/rnaseq/work
```

### Step 8: Identify the Problematic Bundle (Reproduced)

All test runs were consistently killed while processing:

```
scaffold_4:19496-15890108 [4,059,805 alignments (691,468 distinct), 5,777 junctions, 170,822 guides]
```

- Spans ~15.9 Mb — nearly the entire scaffold
- 170,822 GTF annotation features (guides)
- The `>bundle` line appeared but the corresponding `^bundle done` line never appeared before the crash

### Step 9: GTF Filtering — Root Cause Fix

```bash
# Filter GTF to retain only gene model sources
grep -E "maker|augustus_masked|snap_masked" \
    blackglaucus_annotation.clean.filtered.gtf > \
    blackglaucus_annotation.gene_models_only.gtf

# Verify
wc -l blackglaucus_annotation.gene_models_only.gtf
# 554,968 (down from 3,951,669)

awk '{print $2}' blackglaucus_annotation.gene_models_only.gtf | sort | uniq -c
#  98795 augustus_masked
# 243009 maker
# 213164 snap_masked
```

**Effect on problematic bundle:**

| Metric | Original GTF | Filtered GTF |
|---|---|---|
| Total lines | 3,951,669 | 554,968 |
| scaffold_4 guides | 170,822 | 19,218 |
| Runtime | Crashed | ~3 minutes |
| Result | Segfault | ✅ Success |

Test run with filtered GTF completed successfully in **3m 8s** with all output files generated:

```
test_filtered_gtf.gtf                 87M
test_filtered_gtf.gene.abundance.txt  5.4M
test_filtered_gtf.coverage.gtf        20M
test_filtered_gtf.ballgown/           71M (all 5 ctab files populated)
```

---

## Root Cause

The GTF file `blackglaucus_annotation.clean.filtered.gtf` contained 1.6 million RepeatMasker and EST/protein alignment entries in addition to actual gene models. These entries caused StringTie to create an abnormally large genomic bundle on scaffold_4 with 170,822 features, which StringTie could not process, resulting in a segmentation fault.

This is a known issue with StringTie when processing non-model organism genomes with complex or inflated annotations. See:
- https://github.com/gpertea/stringtie/issues/203
- https://github.com/nf-core/rnaseq/issues/1506 (open request to update StringTie to v3 in nf-core/rnaseq)

---

## Resolution

### Step 1: Generate Filtered GTF

```bash
grep -E "maker|augustus_masked|snap_masked" \
    blackglaucus_annotation.clean.filtered.gtf > \
    blackglaucus_annotation.gene_models_only.gtf
```

### Step 2: Update Nextflow Run Command

Replace the original GTF path with the filtered GTF path in the `nextflow run` command.

### Step 3: Rerun the Pipeline

Since the GTF is used in multiple steps, rerun the full pipeline (do not use `-resume`):

```bash
nextflow run main.nf \
    --gtf blackglaucus_annotation.gene_models_only.gtf \
    [other parameters]
```

---

## Client Confirmation

> "I tried your fix and it worked! Thank you so much for your help!" — Alejandra, 2026-05-27

---

## Related Notes

### StringTie Container Location

```
/projectnb/mullenl/alejandra/analysis/rnaseq/nfcore/rnaseq/work/singularity/depot.galaxyproject.org-singularity-stringtie-2.2.3--h43eeafb_0.img
```

### Verify StringTie Version

```bash
singularity exec <container.img> stringtie --version
# 2.2.3
```

### Pulling a New Singularity Container on BU SCC

```bash
ssh scc-i01
mkdir $TMPDIR/$USER
SING_DIR=$TMPDIR/$USER
singularity pull $SING_DIR/stringtie-3.0.3.sif \
    https://depot.galaxyproject.org/singularity/stringtie:3.0.3--h29c0135_0
singularity exec $SING_DIR/stringtie-3.0.3.sif stringtie --version
mv $SING_DIR/stringtie-3.0.3.sif /projectnb/<your_project>/
rm -rf $SING_DIR
exit
```

### Nextflow Log Rotation

Nextflow rotates logs as `.nextflow.log`, `.nextflow.log.1`, `.nextflow.log.2`, etc. Match timestamps from work directory (`ls -alht`) to find the right log file.
