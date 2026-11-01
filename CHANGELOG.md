# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Stamps record a **recipe version** (`NEUTRALISER_RECIPE`, also in the sidecar). Files stamped
  before this stay valid and show as `unversioned` in `report`. A run never re-levels a file
  because its recipe is older; `process --redo-recipe 1,unversioned` is the deliberate re-run.
- Files left alone on purpose are recorded in the sidecar with the reason and, where it was
  measured, their levels: peak-limited, Atmos / DTS:X, DTS / TrueHD codec change, and within
  tolerance. `report` shows them (`tsv` and `json` carry the levels). They never count as done.
- `report` shows the **remote-free rate**: the share of files within 2 LU of target and at or
  under 12 LU of loudness range (`--within`, `--lra-limit`). Levels are computed from the
  records, or measured from the files with `--measure`.
- `rate-sample ROOT...` runs a recipe on copies of a random sample (an equal share per root, so
  films aren't drowned by episodes) and reports that rate. The library is only read.
- `--lra-target N` — opt-in compression, off by default. A file whose loudness range is over N LU
  (by more than `--tolerance`) goes through `acompressor` at the gentlest of six settings that
  brings it under N, then is levelled to the profile target (with `--limit-db` limiting as
  needed). Stamped `compressed` with the setting and the range before and after
  (`NEUTRALISER_COMPRESSION`, `NEUTRALISER_LRA_AFTER`). `--centre-boost DB` lifts a 5.1 centre
  channel first. Refuses `--allow-dynamic`, `--fast`, `--fast-verify` and the `night` profile.
  The default and the profiles are unchanged. Measured on a synthetic fixture only:
  `docs/research/compression-ladder-fixtures-2026-11.md`.

## [0.1.0] — 2026-10-31

First public release. Run from source (`git clone` + `bundle install`) or with the
Docker image; a RubyGems release is deferred until v0.1 has had real-world mileage.

### Security

- A `.env` in the working directory no longer runs commands or reaches ffmpeg. `dotenv` is
  gone: `analyze-plex` reads `PLEX_TOKEN` and `PLEX_SERVER_URL` from it literally, and nothing
  else does. Unused `plex-ruby` and `nokogiri` are removed too.

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
- `analyze-plex` — audit loudness across Plex movie and TV libraries (episodes, named
  `Show S01E02 Title`) via Plex's own stream, with `table`, `csv`, and `json` output and
  `--sample-percent` for large libraries. Checked against a fake Plex server
  (`spec/plex_fake_server_spec.rb`), not a real one.
- `profiles` and `version` commands.
- Atomic writes and signal-safe cleanup, so an interrupted run never leaves a truncated
  file in place of the original.
- Parity with the NAS's `neutralise.sh`: `--min-free-gb` / `--abort-free-gb` (exit 4),
  `--lock-file` (exit 3), and `neutraliser import-manifest` for its history. See
  `docs/research/prod-parity-audit-2026-10.md`.
- A `Dockerfile` (Ruby 3.2, FFmpeg 7.1+) and a GitHub Actions workflow publishing
  `ghcr.io/willhs/neutraliser`; README "Run with Docker" section.

### Changed

- `analyze-plex` no longer gives a confident per-file verdict from a sample. Titles are
  estimated from five 60-second windows spread across the runtime (combined on energy,
  not by averaging LUFS), and a title is flagged Too Loud / Too Quiet only when the whole
  error range measured on real films (up to 6.5 LU quieter, 1.0 LU louder than the full
  reading, each widened by 0.5 LU) is clear of the tolerance. Everything else is listed as Unclear with the range
  it could be in. On 10 films the old middle-window verdict disagreed with the full
  measurement 6 times; the new rule contradicted it 0 times. The report also shows the
  spread of estimated levels, and the CSV/JSON gain `Measured` and range columns
  ([research note](docs/research/plex-sampling-error-2026-10.md)).
- `analyze-plex --full` measures every title end to end for a firm verdict (slow: it reads
  each whole file over HTTP).
- Files whose codec can't be re-encoded to itself (DTS, TrueHD ...) are skipped by
  default (`codec_change`); `--allow-codec-change` restores the FLAC/E-AC-3 fallback.
- With no default-flagged audio track, the first English track is normalised, not a:0.
- Output is checked against the source (duration, audio stream count) before it
  replaces the original; the new file keeps the original's owner when permitted.
- The within-tolerance skip message now logs the measured level.
- `--fast-verify` is now off by default. A 30-second sample could record a film 9 LU off
  target as finished, and `--no-fast-verify` couldn't undo that afterwards.
- Temp outputs are hidden, so media scanners don't pick up a half-written file.
- `--dry-run` no longer writes a run manifest. Its analysis caches stay.
- `--target-level` keeps the chosen profile's other settings and names its profile from the
  target (`custom-18`).
- MP4 files with cover art or descriptive tags no longer get an in-file stamp, because it
  cost them the cover and their iTunes tags. The sidecar holds their record.

### Fixed

- On ffmpeg older than 5.1 (4.2 was checked), every file failed under the `reference`
  profile: `loudnorm` rejects the profile's loudness range of 50. It now gets 20 there, which
  changes nothing for constant gain. `--limit-db` needs 5.1 or newer, so older builds now
  refuse it up front instead of failing inside ffmpeg. CI runs ffmpeg 4.2.2 and 7.1.
- The `process` run manifest (`.neutraliser-run-manifest.jsonl`) recorded each file's outcome
  only after the whole run finished, so a run stopped part-way (Ctrl-C, SIGTERM, a crash)
  left only `queued` lines and `--resume` had nothing to skip. Outcomes are now written as
  each file finishes.
- `analyze-plex` read a window with no audio (loudnorm's `-inf`, e.g. a failed Plex read) as
  0 LUFS, the loudest possible level. Such windows are now dropped, and a title with too few
  readable windows is left out rather than given an invented level.
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
- `--replace` lost MKV attachments (subtitle fonts), MP4 cover art and iTunes atoms, and the
  primary track's dispositions other than default.
- `--replace` overwrote a file that was still being written. It now fails with
  `source_changed`.
- SIGTERM and `docker stop` hung while ffmpeg kept running, then orphaned the temp output.
  Exit is now prompt, with code 130 or 143.
- Copy mode wrote directly to the final name and could destroy an earlier `_normalized` file
  on failure.
- `--replace` through a symlink replaced the link and left the real file untouched.
- Output verification now checks every stream, chapters and the primary track's channels,
  so a silent 7.1 downmix is refused.
- `--resume` trusted dry-run and low-disk records, and ignored a changed profile.
- A copy-mode run stopped a later `--replace`; a second `--target-level` was skipped; a
  peak-limited or within-tolerance verdict outlived the options that produced it.
- The measurement cache gave old figures to swapped files and same-named siblings.
- Silent tracks were re-encoded as "0 LUFS".
- Directories with `[`, `{` or `*` in their name read as empty. A relative name with a colon
  was read as an ffmpeg protocol. A file name that isn't valid UTF-8 aborted the whole run.
- An unwritable `HOME`, as under `docker --user`, crashed at startup. A missing ffmpeg now
  gives one error, and an unreadable file fails instead of reading as "no audio".

[0.1.0]: https://github.com/willhs/neutraliser/releases/tag/v0.1.0
