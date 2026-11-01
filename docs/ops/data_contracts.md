---
type: note
status: active
owner: will
contributors: []
updated: 2026-11-01
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
| `NEUTRALISER_RECIPE` | `2` | Version of the leveling method that wrote it (`Neutraliser::Recipe::CURRENT`). The profile says where to aim, the recipe how it gets there. Absent on files stamped before recipes existed: those stay valid (a run counts them done) and `report` lists them as `unversioned`. A newer recipe never re-levels a file by itself; `process --redo-recipe N` (or `unversioned`) is the deliberate re-run |
| `NEUTRALISER_PROFILE` | `livingroom` | Profile name (`reference`, `livingroom`, `night`, or `custom<target>` for `--target-level`, e.g. `custom-18`). **Its presence is what marks a file as processed.** |
| `NEUTRALISER_MODE` | `linear` | `linear` (constant gain, dynamics untouched), `limited` (constant gain plus a peak limiter, `--limit-db`), `compressed` (`--lra-target`: `acompressor`, then constant gain) or `dynamic` (loudnorm compressed the dynamic range) |
| `NEUTRALISER_GAIN_DB` | `-1.50` | Constant gain applied, in dB (before the limiter, for `limited`). Empty for `dynamic` |
| `NEUTRALISER_SOURCE_CODEC` | `eac3` | Primary audio codec before re-encoding |
| `NEUTRALISER_SOURCE_DIALNORM` | `-24` | Only for AC-3 / E-AC-3 sources re-encoded to AC-3 / E-AC-3: the source track's dialnorm in dB, which the output carries too (`-dialnorm`), so it differs from the source by the gain and nothing else. FFmpeg's encoders write -31 otherwise. Empty for other sources, and when the source's could not be read (the output then has -31). Recipe 2 and later |
| `NEUTRALISER_SOURCE_PROFILE` | `Dolby Digital Plus + Dolby Atmos` | What ffprobe called the source track, when it named a profile. After a codec change or `--allow-object-audio-loss` it is the only record of what the file used to hold. Empty on stamps from before 2026-11-02 |
| `NEUTRALISER_PRIOR` | `1:linear,2:compressed/gentle` | Every earlier pass the audio went through, oldest first, each `recipe:mode[/compression]`. Empty on a first pass. `MODE`, `RECIPE` and `GAIN_DB` are this pass's only, so a `linear` here does not mean the audio was never compressed, and a `RECIPE` of 2 does not undo the DRC and dialnorm reset of a `1` listed here (`SOURCE_DIALNORM` then reads that reset value). A run with `--lra-target` won't compress audio this lists as compressed |
| `NEUTRALISER_SOURCE_BITRATE` | `640000` | Source bitrate in bit/s (probed or estimated). Empty if unknown |
| `NEUTRALISER_MEASURED_I` | `-23.10` | Integrated loudness before, LUFS. Empty in `--fast` mode (no analysis pass) |
| `NEUTRALISER_MEASURED_TP` | `-6.00` | True peak before, dBTP. Empty in `--fast` mode |
| `NEUTRALISER_MEASURED_LRA` | `7.25` | Loudness range before, LU. Empty in `--fast` mode |
| `NEUTRALISER_COMPRESSION` | `strong+limiter` | Only for `compressed`: the ladder rung used (`gentle`, `moderate`, `strong`, `heavy`, `severe`, `extreme`), `+limiter` when `--limit-db` also held peaks after levelling. Empty otherwise |
| `NEUTRALISER_CENTRE_BOOST_DB` | `4.00` | Only for `compressed`: dB the 5.1 centre channel was lifted by. `0.00` if none (including `--centre-boost` skipped for a non-5.1 track) |
| `NEUTRALISER_LRA_AFTER` | `9.30` | Only for `compressed`: loudness range of the compressed signal as `loudnorm` measured it before the final encode, LU. An `ebur128` read of the output file ran up to 0.8 LU away on a 32 s fixture |
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
| MP4, M4V, MOV, nothing to lose | no (silently dropped) | yes, via `-movflags +use_metadata_tags` |
| MP4, M4V, MOV, with cover art or descriptive tags | no | no. `use_metadata_tags` replaces the iTunes atoms and loses the cover, so the sidecar is the only record |
| FLV, WMV | yes | yes |
| AVI | no | no. The sidecar is the only record |

`Source#stamp` reads the primary audio stream first and falls back to the container.

### Sidecar cache: `.neutraliser`

JSON in the run's root directory, mapping each file's path (relative to that root) to `{size, mtime, profile, recipe, processed_at}`, plus `tolerance` when the file was left alone for being close enough (a stricter run looks again). A run with `--lra-target N` also writes `lra_target`, and trusts an entry only if it carries a target at least as strict (an entry from a run without one is checked against the file's tags instead). `recipe` is the recipe that made or judged the file (absent on an `import-manifest` entry, whose file the retired script made); a tag hit keeps the file's own, and entries without one are unversioned. After a copy-mode run the entry names the `_normalized` copy, not the original.

A file looked at and left alone on purpose gets a `left` object: `{reason, profile, recipe, message, measured_i, measured_tp, measured_lra}` (`Neutraliser::LeftRecord`), which `neutraliser report` shows. `reason` is `peak_limited` (the peak ceiling leaves under `--min-gain` dB), `object_audio`, `codec_change` (DTS / TrueHD) or `within_tolerance`. The measured levels are present for `peak_limited` and `within_tolerance`; the object-audio and codec checks run before any measurement. For the first three the entry has `{size, mtime, left, recorded_at}` and **no top-level `profile`**, so it never matches as done and the next run decides again (`--limit-db`, `--allow-codec-change` and the rest can change the answer). A `within_tolerance` record rides inside the processed entry. Normalising the file later replaces the entry; a changed size or mtime makes the record stale. A dry run records nothing. `report` reads these from the `.neutraliser` in the file's folder or any folder above it. It is a cache in front of the tag check. A file counts as processed when size, mtime and profile all match. A tag hit refreshes the entry. A sidecar in the file's own folder also counts for a run started above it; `neutraliser import-manifest` writes there.

### Run manifest: `.neutraliser-run-manifest.jsonl`

One JSON line per file event: `timestamp`, `file` (absolute), `status` (`queued`/`done`/`skipped`/`failed`), `profile`, `target_lufs`, `replace`, plus `reason`, `message` and `normalization_type` (`Linear`/`Limited`/`Dynamic`) when known. A dry run writes none. Every queued file gets its `queued` line when the run starts, and its outcome line the moment that file finishes (not at the end of the run), so a run stopped part-way still leaves a manifest `--resume` can use. The last line for a file wins; a file whose last line is still `queued` was not reached or was interrupted. `--resume` trusts only `normalized`, `already_processed`, `no_audio_track` and `unsupported_format`, and only under the same profile, target and `replace`; anything else is checked again.

Skip `reason`s worth knowing (`status` `skipped`): `already_processed`, `within_tolerance`, `peak_limited` (the peak cap leaves under `--min-gain` dB of gain towards target), `object_audio`, `codec_change` (codec can't be kept; `--allow-codec-change`), `low_disk` (`--min-free-gb`; retried next run), `silent` (primary track has no measurable level), `no_audio_track`, `unsupported_format`.

A failed entry's `message` is one line: what failed plus the last stderr line that says why (e.g. `Normalization failed (exit 1): Error opening output files: Permission denied`), never the ffmpeg banner. Failure `reason`s:

| reason | meaning | retry? |
|---|---|---|
| `not_writable` | The file's folder won't take a new file (preflight, before analysis) | after fixing folder permissions |
| `unsupported_subtitle` | A subtitle stream this ffmpeg can't identify, so it can't be copied (preflight, or recognised in the encode's stderr) | after remuxing/removing that track |
| `timeout` | A subprocess ran out of time | yes, with a bigger `NEUTRALISER_*_TIMEOUT` |
| `output_verification_failed` | The output looked corrupt, or its duration (±1 s), stream or chapter counts, or the primary track's channels differ from the source (a 7.1 track through a 5.1-only encoder ends up here); the original is untouched | investigate |
| `source_changed` | The file changed while it was being processed, such as a copy still arriving; it was left as it is | yes, once it has finished changing |
| `unreadable` | ffprobe could not read the file | after checking the file |
| `ffmpeg_error` | Any other ffmpeg/ffprobe failure | investigate |
| `file_manager_error`, `processing_error`, `invalid_result` | Failures outside ffmpeg | investigate |

## Decisions / Rationale
The record lives in the file because the sidecar is tied to the run's root directory: moving a file or starting from another root lost it and could lead to another lossy re-encode. Tags travel with the file.

## Next Actions
- [ ] Document owner contacts.

## References / Links
- docs/design/architecture.md (Stamp section)
- docs/ops/runbook.md

### Change Log
- 2026-11-02 (agent:sceptical-review): Added `NEUTRALISER_SOURCE_PROFILE` and `NEUTRALISER_PRIOR`; `import-manifest` entries carry no `recipe` (they were recording the current one)
- 2026-11-01 (agent:dolby-metadata): Added `NEUTRALISER_SOURCE_DIALNORM`; recipe 2 (AC-3 / E-AC-3 decoded with `-drc_scale 0`, dialnorm carried); analysis cache version 1.2
- 2026-11-01 (agent:no-regret-groundwork): Added `NEUTRALISER_RECIPE`, the sidecar `recipe` and `left` records
- 2026-10-20 (agent:prod-parity): Added `limited` mode, `codec_change`/`low_disk`/`peak_limited` skip reasons, output-match verification, sidecar-in-own-folder rule
- 2026-10-15 (agent:preflight-failures): Documented failure reasons and the one-line failure message
- 2026-10-15 (agent:record-what-was-done): Added the NEUTRALISER_* tag schema, sidecar and run-manifest contracts
- 2025-09-24 (agent:create-project): Created data contracts placeholder
