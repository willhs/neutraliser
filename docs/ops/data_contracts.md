---
type: note
status: active
owner: will
contributors: []
updated: 2026-10-15
review_cycle: 30d
agent_write: true
links: []
summary: "Schemas, SLAs, and backward-compatibility expectations"
tags: []
---
## Context / Purpose
Detail data contracts and SLAs so breaking changes are spotted early.

## Current State

### In-file record: `NEUTRALISER_*` tags

Every file neutraliser writes carries a record of what was done to it. `Neutraliser::Stamp` (`lib/neutraliser/stamp.rb`) is the only code that knows these names. Consumers: `SkipDecider` (skip a file tagged for the same profile) and `neutraliser report`.

| Tag | Example | Meaning |
|---|---|---|
| `NEUTRALISER_VERSION` | `0.1.0` | neutraliser version that wrote it |
| `NEUTRALISER_PROFILE` | `livingroom` | Profile name (`reference`, `livingroom`, `night`, or `custom` for `--target-level`). **Its presence is what marks a file as processed.** |
| `NEUTRALISER_MODE` | `linear` | `linear` (constant gain, dynamics untouched) or `dynamic` (loudnorm compressed the dynamic range) |
| `NEUTRALISER_GAIN_DB` | `-1.50` | Constant gain applied, in dB. Empty for `dynamic` |
| `NEUTRALISER_SOURCE_CODEC` | `eac3` | Primary audio codec before re-encoding |
| `NEUTRALISER_SOURCE_BITRATE` | `640000` | Source bitrate in bit/s (probed or estimated). Empty if unknown |
| `NEUTRALISER_MEASURED_I` | `-23.10` | Integrated loudness before, LUFS. Empty in `--fast` mode (no analysis pass) |
| `NEUTRALISER_MEASURED_TP` | `-6.00` | True peak before, dBTP. Empty in `--fast` mode |
| `NEUTRALISER_MEASURED_LRA` | `7.25` | Loudness range before, LU. Empty in `--fast` mode |
| `NEUTRALISER_DATE` | `2026-10-15T10:14:10Z` | When it was written, UTC ISO 8601 |

Encoding rules:
- Values are strings. Floats have 2 decimals and integers are plain.
- Every key is written on every run. An empty value deletes that key, so values left from an earlier run (carried over by `-map_metadata 0`) don't survive a re-run.
- Readers match keys case-insensitively. MKV and MP4 report key case differently.
- Readers ignore keys they don't know. New fields can be added without a version bump. Renaming or removing a field is a breaking change.

Where the tags live:

| Container | Primary audio stream | Container (format) |
|---|---|---|
| MKV, WebM | yes | yes |
| MP4, M4V, MOV | no (silently dropped) | yes, via `-movflags +use_metadata_tags` |
| FLV, WMV | yes | yes |
| AVI | no | no. The sidecar is the only record |

`FFmpegWrapper.read_stamp` reads stream `a:0` first and falls back to the container.

### Sidecar cache: `.neutraliser`

JSON in the run's root directory, mapping each file's path (relative to that root) to `{size, mtime, profile, processed_at}`. It is a cache in front of the tag check. A file counts as processed when size, mtime and profile all match. A tag hit refreshes the entry.

### Run manifest: `.neutraliser-run-manifest.jsonl`

One JSON line per file event: `timestamp`, `file` (absolute), `status` (`queued`/`done`/`skipped`/`failed`), `profile`, `target_lufs`, plus `reason`, `message` and `normalization_type` (`Linear`/`Dynamic`) when known. `--resume` reads it.

## Decisions / Rationale
The record lives in the file because the sidecar is tied to the run's root directory: moving a file or starting from another root lost it and could lead to another lossy re-encode. Tags travel with the file.

## Next Actions
- [ ] Document owner contacts.

## References / Links
- docs/design/architecture.md (Stamp section)
- docs/ops/runbook.md

### Change Log
- 2026-10-15 (agent:record-what-was-done): Added the NEUTRALISER_* tag schema, sidecar and run-manifest contracts
- 2025-09-24 (agent:create-project): Created data contracts placeholder
