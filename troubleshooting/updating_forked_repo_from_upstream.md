# Updating a Diverged Fork from Upstream (Merge, Not GitHub's "Sync Fork" Button)

**Author:** Andy Rampersaud
**Date:** 2026-07-20

## When to Use This

Use this procedure when your fork has **local commits of its own** (e.g. BU-SCC-specific config,
troubleshooting docs) *and* is behind upstream — i.e. GitHub shows something like:

```
This branch is 10 commits ahead of and 1075 commits behind nf-core/rnaseq:master
```

If your fork has **zero commits ahead**, GitHub's web "Sync fork" button is fine and simpler. This
procedure is specifically for the case where it isn't.

## Why Not Use GitHub's "Sync Fork" Button Here

For a diverged fork, GitHub's web UI only offers a fast-forward sync. If there are conflicts, it
shows something like:

```
This branch has conflicts that must be resolved
Discard 10 commits to make this branch match the upstream repository.
10 commits will be removed from this branch.
```

**Do not click that.** It permanently deletes your local-only commits so the fork exactly matches
upstream — there is no undo. It also only updates the fork on GitHub, not any local checkout, so
you'd still need to `git pull` afterward regardless. The steps below merge both histories instead of
discarding one, and can be done entirely from the local checkout.

## Step 1: Add the upstream remote (one-time setup)

```bash
git remote add upstream https://github.com/nf-core/rnaseq.git
git remote -v   # should now show both origin (your fork) and upstream (nf-core)
```

This only registers a URL — it doesn't fetch or change anything yet.

## Step 2: Fetch upstream without touching your branch

```bash
git fetch upstream master
```

Downloads upstream's history into a local `upstream/master` ref. Your own `master` is untouched.

## Step 3: Confirm the divergence, and preview what's coming

```bash
git rev-list --left-right --count master...upstream/master   # e.g. "10  1075"
git log --oneline upstream/master -20                        # skim recent upstream commits
```

## Step 4: Merge upstream into your local branch

```bash
git merge upstream/master
```

This creates one merge commit combining your commits with upstream's. Nothing is pushed yet — still
fully reversible with `git merge --abort` if anything looks wrong before committing.

Expect conflicts in files you've customized. In this repo, the only real conflict was `.gitignore`
(both sides had independently added a new ignore line):

```
<<<<<<< HEAD
rnaseq_out_test/
=======
.lineage/
>>>>>>> upstream/master
```

Resolved by keeping both lines and removing the markers — most conflicts on a config-heavy fork like
this are additive rather than truly contradictory.

`nextflow.config` and `README.md` — where most of the BU-specific customizations live — auto-merged
with no conflicts at all in this case, but always verify the result rather than assuming:

```bash
head -25 nextflow.config    # confirm the SGE process{} block is still there
grep -n "BU SCC Instructions\|Troubleshooting" README.md   # confirm custom sections survived
```

## Step 5: Stage resolved files and finish the merge

```bash
git add <resolved-file>       # e.g. git add .gitignore
git status                    # should say "All conflicts fixed but you are still merging"
git commit                    # opens editor with a pre-filled merge message; save and exit as-is
```

The commented `#` lines shown in the editor (file list, "Conflicts:" note) are stripped
automatically — you never need to edit or preserve them. The file list they describe is already
permanently recorded by the commit itself and retrievable later with `git show --stat <hash>`.

## Step 6: Push to your fork

```bash
git push origin master
```

No `--force` needed — this is a normal merge commit, not a history rewrite.

## Why Merge Instead of Rebase

Rebasing would replay your local commits on top of upstream, giving a cleaner linear history, but it
rewrites their hashes. Since this branch is already pushed and tracked as `origin/master`, that would
require a `git push --force` to your own fork afterward. Merge avoids that risk entirely for no real
downside on a personal fork — it's the safer default here.

## Sanity Checks Before/After

```bash
git status                                   # clean tree, "up to date with origin/master" when done
git log --oneline -1 && git log --oneline -1 origin/master   # local and remote HEAD should match
```

## Next Step: Isolate BU-SCC Content from Upstream-Tracked Files

This sync went smoothly (one trivial `.gitignore` conflict), but that was partly luck —
`nextflow.config` and `README.md` both auto-merged cleanly this time, even though both are files
upstream actively edits too and both currently carry BU-specific content injected directly into
them:

- The SGE `process {}` block lives inline at the top of `nextflow.config`.
- The "BU SCC Instructions" and "Troubleshooting" sections live inline inside `README.md`.

Every future sync re-risks a real conflict in these two files, and each conflict has to be resolved
by hand, re-verifying the custom content survived. `troubleshooting/*.md` never has this problem,
because it's a directory name upstream doesn't have — there's nothing for it to collide with.

**Goal:** apply that same isolation to the SGE config and the BU-specific docs, so a future
`git merge upstream/master` only ever touches upstream's own files, never anything BU-specific.

Rough approach for next time:

1. **Move the SGE config out of `nextflow.config` into its own file**, e.g. `bu-scc/scc.config`,
   containing just the existing `process { executor = 'sge'; penv = 'omp'; ... }` block. Load it at
   run time with `-c bu-scc/scc.config` instead of relying on it being baked into `nextflow.config`
   directly — the same `-c`-based pattern already established as the correct way to apply custom
   process config (see the Bowtie2 CPU allocation troubleshooting log). `nextflow.config` itself goes
   back to being pure upstream content, so it should never conflict again.
2. **Move the "BU SCC Instructions" and "Troubleshooting" sections out of `README.md`** into
   `bu-scc/README.md` (or similar), leaving at most a one-line pointer in the main `README.md` (or
   nothing at all, if a short note in the repo description/wiki is enough). This removes the other
   recurring conflict surface.
3. **Consider consolidating** `troubleshooting/` under `bu-scc/troubleshooting/` at the same time, so
   all BU-specific material lives under one clearly-named top-level directory upstream will never
   introduce a same-named file/folder for.
4. Update the BU SCC Instructions themselves (wherever they end up) to reflect the new `-c
   bu-scc/scc.config` invocation instead of "edit nextflow.config directly."

This is a restructuring task for its own session, not something to do as part of a routine sync —
noting it here so it's not lost.
