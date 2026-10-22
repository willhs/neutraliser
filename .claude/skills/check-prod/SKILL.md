---
name: check-prod
description: Check how production audio normalisation is doing on the NAS (the media-server driver, its import queue, sweeps and manifest). Use when the user asks about production status, running jobs, NAS status, whether a show or film has been normalised, or wants to monitor progress.
---

# Check Production Status

Production does **not** run this CLI yet. New media is normalised on the NAS by
media-server's shell fork: Sonarr/Radarr "Neutralise audio on import" ->
`scripts/neutralise-enqueue.sh` -> `neutralise-driver.sh` -> `neutralise.sh`, plus a
weekly sweep kicked hourly from the Mac (LaunchAgent `com.will.neutralise-sweep`).
Source of truth for that pipeline: `~/projects/media-server/scripts/neutralise-*.sh`
and `~/projects/media-server/docs/work/notes/neutraliser-audio-normalisation.md`.
Switching it to this CLI is goal 9c9e4d8c (see `docs/research/prod-parity-audit-2026-10.md`).

There is no neutraliser container on the NAS (`neutraliser-movies` was removed
2026-07-14). Don't look for one.

## Steps

All state lives in `/volume2/neutraliser-stage/` on `admin@192.168.69.217`
(SSH keys set up; only `sudo docker` is passwordless, not other `sudo`).

1. **Driver status and recent log:**
   ```
   ssh admin@192.168.69.217 'cd /volume2/neutraliser-stage && cat driver.status; tail -30 driver.log'
   ```
   `driver.status` is one line: `idle`, `running: import <relpath>`,
   `running: sweep <target> (<relpath>)`, `yielded (neutralise.sh busy)`,
   `failed (disk abort)` or `stopped (signal)`.

2. **Is it alive, and what is queued:**
   ```
   ssh admin@192.168.69.217 'cd /volume2/neutraliser-stage && cat .driver.lock/pid 2>/dev/null; wc -l import-queue.txt import-queue.processing 2>/dev/null; ps aux | grep -c "[f]fmpeg"'
   ```

3. **Has a file been handled?** The manifest is append-only JSONL, last entry per
   file wins (statuses: `done`, `skip_tol`, `skip_tp_capped`, `skip_object_audio`,
   `skip_codec`, `skip_diskguard`, `fail_measure`, `fail_encode`, `fail_verify`,
   `rollback`):
   ```
   ssh admin@192.168.69.217 'grep -F "Show Name/Season 01" /volume2/neutraliser-stage/manifest.jsonl | tail -5'
   ```
   Paths are relative to `/volume1/media`. The USB tier (`/share/USB3-2`, e.g.
   `/share/USB3-2/TV Shows/Lost`) has its own manifest, `manifest-usb3-2.jsonl`.

4. **Mac side** (did the hourly kick reach the NAS):
   ```
   tail -20 ~/Library/Logs/neutralise-sweep.log
   ```

## Report Format

- **Driver**: status line, alive or not, queue length
- **Recent work**: last files done / skipped / failed from `driver.log`
- **Errors**: failures and disk aborts, with the file
- **Gates**: the TV sweep is paused (media-server `SWEEP_TV`, decision 2026-10-20) until
  the driver runs this CLI; only new imports and the movies sweep run
