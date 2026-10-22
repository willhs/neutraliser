---
type: runbook
status: draft
owner: will
contributors: []
updated: 2026-10-22
review_cycle: 30d
agent_write: false
links: []
summary: "Operational procedures and recovery steps"
tags: []
---
## Context / Purpose
Document how to operate, monitor, and recover the system during incidents.

## Current State

### Reading a run's failures
A directory run ends with `Failed by reason: not_writable=…, unsupported_subtitle=…` and lists every folder it couldn't write to. Each failure is also a line in `.neutraliser-run-manifest.jsonl` with a `reason` and a one-line `message` (reasons: `docs/ops/data_contracts.md`). To count them after the fact:

```sh
jq -r 'select(.status=="failed") | .reason' .neutraliser-run-manifest.jsonl | sort | uniq -c
```

After fixing the cause, `--resume` retries only what didn't finish (failed files are never terminal).

### `not_writable`: fix folder permissions
Before analysing a file, neutraliser creates and deletes a temp file in its folder (once per folder per run). If that fails, every file in the folder fails as `not_writable` in milliseconds instead of after a full loudness pass each. The fix is on the storage side: give the user neutraliser runs as write access to the folder (on the NAS, the share/folder ACLs for whole shows such as The Simpsons, Futurama, Bob's Burgers in the Aug 2026 run). `--dry-run` writes nothing and skips the check.

### `unsupported_subtitle`: a subtitle track ffmpeg can't copy
Subtitles are always copied, never dropped. A stream ffmpeg can't identify (`Subtitle: none`) can't be copied either, so the file fails before analysis with the stream named, e.g. `subtitle stream 2 (S_TEXT/WEBVTT) can't be copied by this ffmpeg`. The common case is WebVTT muxed by mkvmerge, which writes the Matroska ID `S_TEXT/WEBVTT`; ffmpeg only knows the older `D_WEBVTT/*` IDs.

**Upgrading ffmpeg does not fix this.** Checked 2026-10-15 against FFmpeg source: `libavformat/matroska.c` on `release/7.1`, `release/8.0` and `master` maps only `D_WEBVTT/SUBTITLES|CAPTIONS|DESCRIPTIONS|METADATA`, and the 7.1.1 Homebrew build fails the copy with `Subtitle codec 0 is not supported`. So there is no minimum ffmpeg version to require and no startup version check. To process such a file, remux the track (e.g. `mkvmerge` it back out, or convert it to SRT) or remove it by hand, then `--resume`.

PGS (`hdmv_pgs_subtitle`) tracks log `Could not find codec parameters … unspecified size` when the probe window holds no subtitle packets. That is a probe warning, not by itself a failure: the codec is known, so the preflight lets it through. Not reproduced locally (ffmpeg can't encode a PGS fixture); if a PGS file does fail, the manifest's one-line message now shows the real cause instead of the warning buried in a dump.

### Where production runs
Production does not run this CLI yet. New media is normalised on the NAS by media-server's shell fork: Sonarr/Radarr import -> `scripts/neutralise-enqueue.sh` -> `neutralise-driver.sh` -> `neutralise.sh`, plus a weekly sweep kicked hourly from the Mac. Its state (`driver.status`, `driver.log`, `manifest.jsonl`, the import queue) is in `/volume2/neutraliser-stage/`; the `check-prod` skill reads it. Moving the driver onto this CLI is goal 9c9e4d8c ([parity audit](../research/prod-parity-audit-2026-10.md)).

### Container image
The `neutraliser-movies` container (wedged 2026-02-15) and its image were removed from the NAS on 2026-07-14, and no Dockerfile for it ever existed in this repo, so it is retired. The repo `Dockerfile` (FFmpeg 7.1+ checked at build) publishes `ghcr.io/willhs/neutraliser`; see README "Run with Docker". Nothing in production uses that image until the driver switch lands.

### ffmpeg version
FFmpeg 4.2+ works; 7.1+ is needed for Atmos/DTS:X detection (see `docs/research/object-audio-detection.md`). Which host and ffmpeg the Aug 2026 library run used is not recorded: its manifests use `/mnt/nas/media/...` paths, a Linux SMB mount (see task 0005), so it was not the MacBook.

### Timeouts
`timeout` failures on large files over a network mount are usually the budget, not the file. Raise `NEUTRALISER_ANALYSIS_TIMEOUT` / `NEUTRALISER_NORMALIZATION_TIMEOUT` (seconds). The 343 Aug 2026 timeouts predate the 2026-08-10 budget fix (analysis 300s → 1800s).

## Decisions / Rationale
Preflight checks run before the loudness pass because that pass is the expensive part (minutes per file over SMB); a failure we can predict from a folder permission or an ffprobe should cost one cheap check. Failure messages keep one line and a reason so a 4,000-file run's failures can be counted and grouped, not read one ffmpeg dump at a time.

## Next Actions
- [ ] Capture deployment checklists.
- [ ] Define escalation paths.

## References / Links
- docs/ops/quality.md
- docs/ops/data_contracts.md

### Change Log
- 2026-10-22 (agent:agent-experience): Added "Where production runs" (media-server's NAS driver, not this CLI); dropped the unsupported MacBook claim for the Aug run
- 2026-10-15 (agent:preflight-failures): Added failure triage, permissions, unsupported subtitles, ffmpeg version and timeouts
- 2025-09-24 (agent:create-project): Created runbook placeholder
