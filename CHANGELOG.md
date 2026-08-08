# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

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
