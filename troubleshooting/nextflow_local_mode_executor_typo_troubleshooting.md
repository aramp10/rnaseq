# Nextflow Running in Local Mode Instead of Submitting SGE Jobs (Typo in `nextflow.config`)

**Ticket:** [INC20925379](https://bu.service-now.com/now/nav/ui/classic/params/target/incident.do)

## Issue

A researcher (Maya) ran the full-size test (`-profile test_full,singularity`) on an interactive
desktop and found that after 3+ hours the pipeline was still running, with the log showing
`executor > local (31)`. This indicated every task was executing on the interactive desktop
itself rather than being submitted as individual jobs to the SCC's SGE scheduler — meaning all
tasks were competing for the same handful of cores instead of running in parallel across the
cluster.

Separately, this local-mode execution also caused the interactive desktop's job to be
terminated for exceeding its allocated core count (the desktop was allocated 3 cores, but
Nextflow's local executor attempted to use more).

## Root Cause

The `process` block in `nextflow.config` had a typo — `executer` instead of `executor`:

```groovy
// Incorrect (typo):
process {
    executer = 'sge'
    penv = 'omp'
    clusterOptions = '-P vmemseq'
    beforeScript = 'source $HOME/.bashrc'
}
```

Nextflow does **not** validate unrecognized keys inside the `process {}` scope. Since `executer`
isn't a real config key, it was silently ignored — no warning or error appeared anywhere in
`.nextflow.log`. Without a valid `executor` directive, Nextflow fell back to its default local
executor, running every task as a subprocess on the machine where `nextflow run` was launched.

## Diagnosis

Confirmed via log inspection (no errors were thrown, so this required checking execution
details directly):

```bash
# Confirm the typo isn't referenced/flagged anywhere in the log (it won't be)
grep -n "executer" .nextflow.log

# Confirm which executor Nextflow actually assigned to each process
# (should read 'sge' when configured correctly — this run showed 'local' throughout)
grep -n "processorType" .nextflow.log

# Cross-check: local-mode tasks are launched via LocalTaskHandler + a plain bash command,
# rather than SgeTaskHandler + qsub
grep -n "LocalTaskHandler\|SgeTaskHandler" .nextflow.log | head -20

# Confirm which config file was actually parsed by Nextflow
grep -n "Parsing config file" .nextflow.log
```

## Fix

Correct the typo (`executer` → `executor`) and indent the block for readability:

```groovy
// Specify process-level configuration to run on the BU SCC
process {
    executor = 'sge'
    penv = 'omp'
    // aramp10 edit: Add your SCC project here
    clusterOptions = '-P vmemseq'
    beforeScript = 'source $HOME/.bashrc'
}
```

Note: indentation is cosmetic only — Nextflow config files use Groovy syntax and aren't
whitespace-sensitive. The typo, not the formatting, was the actual cause of the issue.

## Verification

Re-run using the smaller test profile to confirm tasks now submit as SGE jobs rather than
running locally:

```bash
nextflow run main.nf -profile test,singularity --outdir rnaseq_out_test
```

Check the log again for `processorType: 'sge'` and `SgeTaskHandler` entries to confirm the fix.
