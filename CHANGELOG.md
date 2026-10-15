# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Normalised files now record what was done to them as `NEUTRALISER_*` tags
  (profile, linear/dynamic, gain, source codec/bitrate, measured loudness, date)
  on the audio track and container. A file tagged for the same profile is skipped
  even after it moves or the run starts from a different root.
- `neutraliser report PATH [--format summary|tsv|json]` reads those tags and counts
  linear, dynamic and untouched files and the profile mix.

### Fixed

- Analysis no longer times out on large files. `ANALYSIS_TIMEOUT` was 300s while
  normalisation had 1800s, despite both decoding the whole audio stream — so any
  file too big to *measure* in five minutes failed before reaching the half hour
  allowed to *process* it. On a NAS over SMB that is an ordinary HD episode: a
  491MB file measures in 162s, so anything past roughly 900MB failed. Observed as
  339 spurious failures in a 4,500-episode run. Both budgets are now 1800s and
  every timeout is overridable via `NEUTRALISER_<PHASE>_TIMEOUT`.
- The timeout message no longer claims the file "may be corrupted or have
  unsupported codec". The usual cause is a large file on a slow mount, and the old
  wording sent people hunting for damage that wasn't there.

## [0.1.0] — 2026-08-08

First public release. Run from source (`git clone` + `bundle install`); a RubyGems
release is deferred until v0.1 has had real-world mileage.

### Added

- `process` — EBU R128 two-pass loudness normalisation for a single file or a whole
  directory tree, writing `*_normalized` copies by default or replacing originals with
  `--replace`.
- Three home-theatre profiles — `reference` (−23 LUFS), `livingroom` (−20 LUFS, default),
  and `night` (−16 LUFS) — plus an explicit `--target-level` override.
- Source-matched output codec and bitrate selection, so high-bitrate and lossless sources
  aren't downgraded to a fixed AAC/AC3 target (ADR-0001).
- Full stream preservation: video is stream-copied, and additional audio tracks,
  subtitles, chapters, dispositions, and per-stream metadata are mapped across explicitly.
- Skip-already-normalised via a `.neutraliser` sidecar (size + mtime + profile), with an
  optional 30-second quick-sample estimate as a fallback (`--fast-verify`).
- Loudness analysis caching, with `cache stats` and `cache clean` for maintenance.
- `--resume` — resume an interrupted directory run from
  `.neutraliser-run-manifest.jsonl`.
- `--fast` single-pass normalisation (~30% quicker, marginally less accurate) and
  `--local-stage` for slow or high-latency network mounts (ADR-0002).
- `--linear-only` — constant-gain normalisation only, never falling back to dynamic
  compression.
- `analyze-plex` — audit loudness across Plex libraries via Plex's own stream, with
  `table`, `csv`, and `json` output and `--sample-percent` for large libraries.
- `profiles` and `version` commands.
- Atomic writes and signal-safe cleanup, so an interrupted run never leaves a truncated
  file in place of the original.

[Unreleased]: https://github.com/willhs/neutraliser/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/willhs/neutraliser/releases/tag/v0.1.0
