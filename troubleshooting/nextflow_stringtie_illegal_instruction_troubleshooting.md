# StringTie Fails with "Illegal instruction" (Exit 132) on Older SCC Nodes

**Author:** Andy Rampersaud
**Date:** 2026-09-28

## Run Information

- **Ticket:** None. Found while testing commands in preparation for the Intro to Nextflow on the SCC
  tutorial.
- **Pipeline:** nf-core/rnaseq v3.27.0 (StringTie 3.0.3 container), a fresh clone of upstream
  nf-core/rnaseq. This fork has since been synced to v3.27.0, and the fix below is included in the
  fork's `nextflow.config`.
- **Nextflow:** 26.04.6 (`module load nextflow/26.04.6`)
- **Cluster:** BU Shared Computing Cluster (SCC)
- **Scheduler:** SGE
- **Run command:**

```bash
nextflow run main.nf -profile test,singularity --outdir rnaseq_out_test -config scc_sge.config
```

## Issue

The test run finished with "Pipeline completed successfully", but the summary still reported failures:

```
Succeeded   : 234
Failed      : 3
```

All 3 failures were first attempts of `STRINGTIE_STRINGTIE`. Nextflow retried each one, and every
retry succeeded, so no output was missing. The failure can come back on any run, though, depending
on which node SGE picks.

## Root Cause

Every failed attempt ran on an **Ivy Bridge** node. Every successful attempt ran on a newer node
(Broadwell or Cascade Lake). Exit code 132 is 128 + 4 (`SIGILL`): the StringTie binary in the
container uses CPU instructions that Ivy Bridge processors don't have, so it crashes as soon as it
starts processing.

| SGE job | Node | `cpu_arch` | Exit |
|---|---|---|---|
| 7769831 | scc-pi3 | ivybridge | 132 |
| 7769850 | scc-mh3 | ivybridge | 132 |
| 7770279 | scc-pi1 | ivybridge | 132 |
| 7769885 | scc-gc4 | cascadelake | 0 |
| 7769921 | scc-gr3 | cascadelake | 0 |
| 7770297 | scc-wg4 | broadwell | 0 |

## Diagnosis

Run from the pipeline directory.

```bash
# 1. List failed tasks (column 2 = work dir prefix, column 3 = SGE job ID, column 6 = exit code)
grep FAILED rnaseq_out_test/pipeline_info/execution_trace_*.txt

# 2. Check whether each failed task was retried and succeeded
grep STRINGTIE rnaseq_out_test/pipeline_info/execution_trace_*.txt | cut -f4,5,6

# 3. Read the error for one failed task (use the prefix from column 2)
cat work/75/b6ab53*/.command.err
# ... line 12:    42 Illegal instruction     stringtie -o RAP1_UNINDUCED_REP1.transcripts.gtf ...

# 4. Find which node the job ran on (use the job ID from column 3)
qacct -j 7769831 | grep -E "hostname|exit_status"

# 5. Check that node's CPU architecture
qhost -F cpu_arch -h scc-pi3
```

## Fix

Keep StringTie off Ivy Bridge nodes by adding a `withName` block inside the `process {}` block of the
custom config (`scc_sge.config`):

```groovy
// Specify process-level configuration
process {
  executor = 'sge'
  penv = 'omp'
  // aramp10 edit: Add your SCC project here
  clusterOptions = '-P ar-rcs'
  beforeScript = 'source $HOME/.bashrc'
  // StringTie binary crashes with "Illegal instruction" on older Ivy Bridge nodes
  withName: 'STRINGTIE_STRINGTIE' {
    clusterOptions = '-P ar-rcs -l cpu_arch=!ivybridge'
  }
}
```

**Note:** `clusterOptions` inside `withName` *replaces* the general `clusterOptions`; it doesn't add
to it. Keep `-P <your_project>` on both lines.

The full file is saved in this folder as [scc_sge.config](scc_sge.config). Now that the fork's own
`nextflow.config` includes these SGE settings and the StringTie fix, you don't need
`-c scc_sge.config` when running the fork. It's still useful with a fresh clone of nf-core/rnaseq,
which is how the tutorial test was run.

## Verification

```bash
# 1. Nextflow merges the setting (and nothing else overrides it)
nextflow -c scc_sge.config config -profile test,singularity | grep -A12 "withName:STRINGTIE_STRINGTIE"

# 2. SGE accepts the resource request (-w v validates only, nothing is submitted)
echo true | qsub -w v -P ar-rcs -l cpu_arch=!ivybridge -pe omp 4
# verification: found suitable queue(s)

# 3. Dry run of the full command
nextflow run main.nf -profile test,singularity --outdir rnaseq_out_test -config scc_sge.config -preview
```

All three checks passed. **Confirmed 2026-10-01:** the failed StringTie task (job 7770279, exit 132
on `scc-pi1`, Ivy Bridge) was resubmitted with `qsub -l cpu_arch=!ivybridge .command.run`. It ran
on `scc-va4` (Broadwell) and exited 0, producing the transcript and abundance files.

## Related Notes

### Passing a custom config

- `-c` and `-config` are the same option. It can go anywhere on the command line (including at the
  end); single-dash options belong to Nextflow and double-dash options (`--outdir`) are pipeline
  parameters.
- Settings in `-c` files override the pipeline's `nextflow.config`, including profile settings.
  When several `-c` files set the same option, the last one wins.
- Confirm the file was loaded: `grep "User config file" .nextflow.log`

### CPU requirements per step

```bash
grep -n "withLabel\|cpus" conf/base.config          # CPUs per label
grep -rn "label 'process_" modules/                 # label used by each step
grep -rn "cpus" conf/modules/                       # steps that override cpus directly
grep -n "resourceLimits" -A4 nextflow.config        # per-profile cap (test = 4 CPUs)
```

| Label | CPUs |
|---|---|
| `process_single` | 1 |
| `process_low` | 2 |
| `process_medium` | 6 |
| `process_high` | 12 |

The `test` profile caps every step at `resourceLimits.cpus`. When running in local mode (without the
SGE config), request at least that many cores for the interactive session. Otherwise Nextflow stops
with an error that the step needs more CPUs than are available. Extra cores only let more steps run
in parallel.
