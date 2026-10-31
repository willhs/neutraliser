# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — 2026-10-31

First public release. Run from source (`git clone` + `bundle install`) or with the
Docker image; a RubyGems release is deferred until v0.1 has had real-world mileage.

### Added

- `process` — EBU R128 loudness normalisation for a single file or a whole directory
  tree, writing `*_normalized` copies by default or replacing originals with `--replace`.
- Three home-theatre profiles — `reference` (−23 LUFS), `livingroom` (−20 LUFS, default),
  and `night` (−16 LUFS) — plus an explicit `--target-level` override.
- **Constant gain by default.** The level moves by one gain (an ffmpeg `volume` filter),
  capped so true peak stays under the profile ceiling, so dynamic range is preserved
  exactly. A quiet-but-peaky file lands shy of target and the log says by how much.
  Compression is opt-in: `--allow-dynamic` (two-pass `loudnorm`, which may go dynamic),
  or the `night` profile, which implies it. `--fast` is always dynamic, so it needs one
  of those too. `--linear-only` is now a deprecated no-op.
- `--limit-db` — opt-in peak limiter so quiet-but-peaky files can reach target (stamped
  `limited`), and `--min-gain` for the skip threshold on peak-capped files.
- **Atmos / DTS:X are skipped, not silently flattened.** Files whose primary track is
  object audio are skipped (`object_audio`); `--allow-object-audio-loss` processes them
  anyway. Files whose codec can't be re-encoded to itself (DTS, TrueHD ...) are skipped
  (`codec_change`); `--allow-codec-change` restores the FLAC/E-AC-3 fallback.
- **Every change is recorded in the file.** Normalised files carry `NEUTRALISER_*` tags
  (profile, linear/dynamic, gain, source codec/bitrate, measured loudness, date) on the
  audio track and container. A file tagged for the same profile is skipped even after it
  moves or the run starts from a different root.
- `neutraliser report PATH [--format summary|tsv|json]` reads those tags and counts
  linear, dynamic and untouched files and the profile mix.
- `--keep-original-audio` — stream-copy the untouched original track into the output as a
  non-default extra track, so processing is reversible even with `--replace`.
- Preflight failures: an unwritable folder (`not_writable`) or a subtitle stream ffmpeg
  can't copy (`unsupported_subtitle`) fails fast, before analysis, with a one-line
  classified message and a per-reason count in the run summary.
- The audio track that is normalised is the default-disposition one (else the first
  English track, else the first), and it is measured by that same index.
- Source-matched output codec and bitrate selection, so high-bitrate and lossless sources
  aren't downgraded to a fixed AAC/AC3 target (ADR-0001).
- Full stream preservation: video is stream-copied, and additional audio tracks,
  subtitles, chapters, dispositions, and per-stream metadata are mapped across explicitly.
- Skip-already-normalised via the in-file stamp, cached in a `.neutraliser` sidecar
  (size + mtime + profile), with an optional 30-second quick-sample estimate as a
  fallback (`--fast-verify`).
- Loudness analysis caching, with `cache stats` and `cache clean` for maintenance.
- `--resume` — resume an interrupted directory run from
  `.neutraliser-run-manifest.jsonl`.
- `--fast` single-pass normalisation (~30% quicker, marginally less accurate) and
  `--local-stage` for slow or high-latency network mounts (ADR-0002).
- `analyze-plex` — audit loudness across Plex libraries via Plex's own stream, with
  `table`, `csv`, and `json` output and `--sample-percent` for large libraries.
- `profiles` and `version` commands.
- Atomic writes and signal-safe cleanup, so an interrupted run never leaves a truncated
  file in place of the original.
- Parity with the NAS's `neutralise.sh`: `--min-free-gb` / `--abort-free-gb` (exit 4),
  `--lock-file` (exit 3), and `neutraliser import-manifest` for its history. See
  `docs/research/prod-parity-audit-2026-10.md`.
- A `Dockerfile` (Ruby 3.2, FFmpeg 7.1+) and a GitHub Actions workflow publishing
  `ghcr.io/willhs/neutraliser`; README "Run with Docker" section.

### Changed

- Output is checked against the source (duration, audio stream count) before it
  replaces the original; the new file keeps the original's owner when permitted.
- The within-tolerance skip message now logs the measured level.

### Fixed

- A quiet file whose peaks sat over the ceiling was re-encoded quieter (negative
  capped gain passed the tolerance check). Peak-capped files now need a gain
  towards target of at least `--min-gain`.
- MP4 data named `.mkv` failed on `mov_text` subtitles; the real container is now used.
- Video and subtitle stream metadata was dropped during `--replace`.
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

[Unreleased]: https://github.com/willhs/neutraliser/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/willhs/neutraliser/releases/tag/v0.1.0
