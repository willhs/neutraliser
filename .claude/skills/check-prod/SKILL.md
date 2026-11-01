---
name: check-prod
description: Check how production audio normalisation is doing on the NAS (the media-server driver, its import queue, sweeps and manifest). Use when the user asks about production status, running jobs, NAS status, whether a show or film has been normalised, or wants to monitor progress.
---

# Check Production Status

Production does **not** run this CLI yet. New media is normalised on the NAS by
media-server's shell fork: Sonarr/Radarr "Neutralise audio on import" ->
`scripts/neutralise-enqueue.sh` -> `neutralise-driver.sh` -> `neutralise.sh`, plus a
weekly sweep kicked hourly from the Mac by a launchd job.
Source of truth for that pipeline: the `media-server` project's
`scripts/neutralise-*.sh` and its `docs/work/notes/neutraliser-audio-normalisation.md`.
Switching it to this CLI is goal 9c9e4d8c (see `docs/research/prod-parity-audit-2026-10.md`).

There is no neutraliser container on the NAS (`neutraliser-movies` was removed
2026-07-14). Don't look for one.

## Setup: where the NAS is

This repo is public, so the NAS's address and paths are **not** in it. Load them from the
gitignored `.claude/skills/check-prod/local.env` (template: `local.env.example` beside it):

```
set -a; . .claude/skills/check-prod/local.env; set +a
```

A worktree doesn't carry gitignored files. If the file is missing there, read it from the
project's primary checkout (read-only, never write there). If it's missing everywhere,
stop and ask: don't guess an address or scan the network for one.

The variables: `NAS_SSH` (user@host, SSH keys already set up), `NAS_STAGE_DIR` (all state
lives here), `NAS_MEDIA_ROOT` (what manifest paths are relative to), `SWEEP_LOG`.

## Steps

1. **Driver status and recent log:**
   ```
   ssh "$NAS_SSH" "cd $NAS_STAGE_DIR && cat driver.status; tail -30 driver.log"
   ```
   `driver.status` is one line: `idle`, `running: import <relpath>`,
   `running: sweep <target> (<relpath>)`, `yielded (neutralise.sh busy)`,
   `failed (disk abort)` or `stopped (signal)`.

2. **Is it alive, and what is queued:**
   ```
   ssh "$NAS_SSH" "cd $NAS_STAGE_DIR && cat .driver.lock/pid 2>/dev/null; wc -l import-queue.txt import-queue.processing 2>/dev/null; ps aux | grep -c '[f]fmpeg'"
   ```

3. **Has a file been handled?** The manifest is append-only JSONL, last entry per
   file wins (statuses: `done`, `skip_tol`, `skip_tp_capped`, `skip_object_audio`,
   `skip_codec`, `skip_diskguard`, `fail_measure`, `fail_encode`, `fail_verify`,
   `rollback`):
   ```
   ssh "$NAS_SSH" "grep -F 'Show Name/Season 01' $NAS_STAGE_DIR/manifest.jsonl | tail -5"
   ```
   Paths are relative to `$NAS_MEDIA_ROOT`. A second storage tier, if there is one, has
   its own `manifest-<tier>.jsonl` in the same directory (`ls $NAS_STAGE_DIR`).

4. **Mac side** (did the hourly kick reach the NAS):
   ```
   tail -20 "$SWEEP_LOG"
   ```

## Report Format

- **Driver**: status line, alive or not, queue length
- **Recent work**: last files done / skipped / failed from `driver.log`
- **Errors**: failures and disk aborts, with the file
- **Gates**: the TV sweep is paused (media-server `SWEEP_TV`, decision 2026-10-20) until
  the driver runs this CLI; only new imports and the movies sweep run
