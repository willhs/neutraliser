# Neutraliser - Video Audio Volume Normalisation CLI

> `AGENTS.md` is a symlink to `.gent/rules.md`: edit `.gent/rules.md` (BSD `sed -i` refuses the symlink).

## Project Overview
A Ruby CLI tool that normalises audio volume in video files using industry-standard EBU R128 loudness normalization to create consistent playback levels throughout your video library.

## Technical Context
- **Language**: Ruby
- **Type**: Command-line interface with Thor
- **Purpose**: EBU R128 video audio volume normalisation
- **Dependencies**: FFmpeg for video/audio processing (CI runs 4.2.2 and 7.1; `--limit-db` and the `reference` profile's LRA 50 under `--allow-dynamic` need 5.1+, Atmos/DTS:X detection needs 7.1+)
- **Status**: ✅ **FULLY IMPLEMENTED** - Production ready

## Architecture Overview

### Core Components
- **`Processor`**: Main orchestration class handling file/directory processing
- **`SkipDecider`**: Single authority for "already normalised?" — the in-file `NEUTRALISER_*` stamp for the same profile, cached in one `.neutraliser` sidecar (size+mtime+profile), quick LUFS sampling as an internal fallback
- **`Stamp`**: Value object for the `NEUTRALISER_*` tags written on the normalised track and container (schema: `docs/ops/data_contracts.md`)
- **`Compression`**: Opt-in `--lra-target` / `--centre-boost`. A ladder of six `acompressor` rungs (thresholds relative to the file's loudness); the gentlest rung whose measured LRA is within target + tolerance is found by bisection (each candidate is one `loudnorm` read through a `pre_filter`), then `GainPlan` levels the compressed signal. Stamped `compressed`. Off by default; refuses `--allow-dynamic`, `--fast`, `--fast-verify`, the night profile
- **`GainPlan`**: The constant-gain decision for one measurement — applied gain, shortfall, whether a limiter is needed (`--limit-db`), `worthwhile?(min_gain)` direction-aware skip
- **`DiskGuard`** / **`RunLock`**: `--min-free-gb`/`--abort-free-gb` floors; `--lock-file` flock run lock
- **`ManifestImport`**: `neutraliser import-manifest` — carries the retired `neutralise.sh` manifest into `.neutraliser` sidecars
- **`Report`**: `neutraliser report PATH` — reads stamps and left-alone records, counts linear/dynamic/untouched, profiles and recipes, and the remote-free rate (`--measure` reads the files instead of computing from the records)
- **`Recipe`**: version of the leveling method (`NEUTRALISER_RECIPE`); a run never re-levels a file because of it, only `process --redo-recipe` does (files from before recipes are `unversioned`)
- **`LeftRecord`**: why a file was left alone (peak-limited, object audio, codec change, within tolerance) and its measured levels, kept in the sidecar with no top-level `profile` so it never counts as done
- **`FinalLevels`** / **`RemoteFreeRate`**: where a file ends up, and the share within 2 LU of target at or under an LRA limit; a `limited` file is not computed (a limiter lands short), only measured
- **`RateHarness`**: `neutraliser rate-sample ROOT...` — a recipe run on copies of a random sample (equal share per root), library only read
- **`FFmpegWrapper`**: Two-pass loudnorm implementation, ffprobe, source-matched codec selection; the primary track is the default-disposition audio track (else the first `eng` one, else a:0), normalised in place and measured by the same index
- **`ObjectAudio`**: Detects Atmos / DTS:X on the primary track (ffprobe profile, name-hinted mid-file probe) so it is skipped, not silently flattened
- **`AudioAnalyser`**: Full loudnorm measurement coordination with sidecar caching
- **`Measurement`**: Value object for loudnorm measurement results
- **`Profiles`**: Normalization profile system (reference/livingroom/night)
- **`FileManager`**: Atomic file operations with integrity verification
- **`CacheManager`**: Sidecar `.loudnorm_{profile}.json` caching system for analysis results
- **`LocalStager`**: Stages files to local disk (`--local-stage`) before processing, copies results back
- **`PlexAnalyzer`**: Plex library integration for media analysis, routed through FFmpegWrapper/Measurement/Profiles; samples five 60s windows per title (`--full` reads end to end). Show libraries are read as episodes (`/all?type=4`). Tested against `spec/support/fake_plex_server.rb`, not a real Plex, for TV
- **`LoudnessEstimate`**: A title's loudness plus the range the truth can lie in; sampled estimates give a verdict only when the whole range clears the tolerance band, else `unclear` (research: `docs/research/plex-sampling-error-2026-10.md`)
- **`VideoFiles`**: The one directory walk: literal paths, supported extensions, leftover temp detection
- **`PlexEnv`**: Reads `PLEX_TOKEN`/`PLEX_SERVER_URL` from `.env` for `analyze-plex` only. Never add dotenv back: it runs `$(...)` from a file in the working directory, which may be a media folder
- **`CLI`**: Thor-based command-line interface with comprehensive options

### Processing Pipeline
0. **Preflight**: the file's folder must take a new file (`not_writable`) and every subtitle stream must be one ffmpeg can copy (`unsupported_subtitle`) — both fail fast, before analysis
1. **Skip Decision**: `SkipDecider` checks the `.neutraliser` sidecar (or a quick LUFS sample fallback) — already-normalised files are skipped
2. **Analysis Pass**: FFmpeg loudnorm measurement → sidecar JSON cache (skipped in `--fast` mode)
3. **Normalization Pass**: Constant gain (`volume` filter, peak-capped) by default; `--allow-dynamic` uses two-pass loudnorm (may go dynamic); `--fast` uses single-pass dynamic mode
4. **Codec Intelligence**: Matches source codec/bitrate where encodable, falls back to FLAC/EAC3/AC3 for non-encodable surround formats — see [ADR-0001](docs/design/adr/0001-smart-codec-selection.md)
5. **Atomic Operations**: Safe file replacement with integrity verification

## Implementation Details

### EBU R128 Two-Pass Workflow
- **Measurement**: `ffmpeg -af loudnorm=print_format=json -f null -`
- **Application**: `ffmpeg -af loudnorm=measured_I=X:measured_TP=Y:...`
- **Accuracy**: Achieves exact LUFS targets (tested: -20.00 LUFS achieved)

### Normalization Profiles
- **Reference** (-23 LUFS, 50 LRA): Home theater/broadcast standard
- **Livingroom** (-20 LUFS, 12 LRA): TV/soundbar optimal (default)
- **Night** (-16 LUFS, 10 LRA): Reduced dynamics for quiet listening; `dynamic: true` profile flag, so implies `--allow-dynamic`

### Smart Features
- **Intelligent Caching**: Profile-specific sidecar JSON with file integrity checks
- **Codec Selection**: Matches source codec/bitrate where encodable; falls back to FLAC/EAC3/AC3 for non-encodable surround formats (see ADR-0001)
- **Metadata Preservation**: Chapters, subtitles, and metadata fully preserved
- **Multi-track Handling**: Normalizes primary audio, copies others unchanged
- **Performance**: `SkipDecider` skips already-normalised files; `--fast` and `--local-stage` trade accuracy/IO for speed (see ADR-0002)

## CLI Commands (Fully Implemented)

### Primary Commands
- `neutraliser process PATH` - Main processing command
- `neutraliser report PATH [--format summary|tsv|json] [--measure]` - What was done to each file, from its tags, why untouched files were left, and the remote-free rate
- `neutraliser rate-sample ROOT... [--sample N --seed S --plan]` - Try a recipe on copies of a random sample and report its remote-free rate
- `neutraliser import-manifest MANIFEST --root DIR` - Mark files a `neutralise.sh` manifest recorded as done as already processed
- `neutraliser profiles` - List normalization profiles
- `neutraliser analyze-plex [--full]` - Plex library loudness triage (sampled estimates; `--full` for exact, slow)
- `neutraliser cache stats/clean` - Cache management

### Key Options
- `--profile reference|livingroom|night` - Normalization profile
- `--replace` - Replace originals (atomic operations)
- `--tolerance N.N` - Skip threshold in LU (default: 1.0)
- `--dry-run` - Analysis only mode
- `--cache/--no-cache` - Toggle sidecar caching
- `--fast` - Single-pass normalization (faster, always dynamic; errors unless `--allow-dynamic` or night profile)
- `--local-stage` - Copy files to local disk before processing
- `--resume` - Resume a prior directory run, skipping completed files
- `--allow-object-audio-loss` - Process Atmos / DTS:X primary tracks anyway (skipped by default; re-encoding drops the objects)
- `--allow-dynamic` - Opt in to loudnorm two-pass, which may go dynamic (default is constant gain, peak-capped)
- `--keep-original-audio` - Also keep the untouched original track (stream copy, not default) so processing is reversible
- `--min-gain N` - Peak-capped files are re-encoded only if the gain towards target is at least N dB (default: `--tolerance`)
- `--limit-db N` - Opt-in peak limiter: gain may exceed the peak headroom by N dB (stamped `limited`)
- `--lra-target N` / `--centre-boost DB` - Opt-in compression: files whose LRA is over N get `acompressor` (gentlest of six rungs that reaches N), then level to target; `--centre-boost` lifts a 5.1 centre channel first. Off by default
- `--allow-codec-change` - Process DTS/TrueHD/etc. (codec can't be kept); skipped by default
- `--min-free-gb N` / `--abort-free-gb N` - Disk floors (skip file / stop run, exit 4); `--lock-file PATH` - one run at a time (exit 3)
- `--redo-recipe N,unversioned` - Process again files an older recipe made (a run never does this by itself)
- `--linear-only` - Deprecated no-op alias (constant gain is the default)

## Testing Strategy ✅ COMPLETED

### Comprehensive Test Suite (Phase 4)
- **Unit Tests**: All components (FFmpegWrapper, AudioAnalyser, Profiles, etc.)
- **Integration Tests**: Real media processing with mocked FFmpeg
- **Golden round trip**: `spec/round_trip_spec.rb` (tag `:real_ffmpeg`, `rspec --tag real_ffmpeg`) runs a real `process --replace` on generated mkv/mp4 clips and checks stream tags, dispositions, chapters, stamps and which track was normalised
- **Error Handling**: Edge cases, corrupted files, permission errors
- **Performance**: Memory usage, concurrency, resource cleanup
- **Validation**: EBU R128 accuracy, metadata preservation

## Production Readiness

### Quality Assurance
- ✅ Industry-standard EBU R128 implementation
- ✅ Comprehensive error handling and recovery
- ✅ Atomic file operations with rollback capability
- ✅ Memory-efficient streaming processing
- ✅ Extensive test coverage with real media files

### Performance Characteristics
- **Between-files normalization**: Excellent (eliminates volume remote juggling)
- **Within-file compression**: Minimal and content-appropriate
- **Cache effectiveness**: 10-50x speedup on repeat analysis
- **Resource usage**: Stable memory, proper cleanup

## Running tests
- `bundle exec rspec` (about a minute) and `bundle exec rubocop`. `bundle exec rspec --tag '~real_ffmpeg'` skips the real-media regressions (about 6 s). Ruby is rbenv 3.2.3.
- Manager job shells may not have rbenv's shims on PATH, so `ruby`/`bundle` resolve to macOS system Ruby 2.6 (`RubyGems version (3.0.3.1) has a bug`, `LoadError thor`). Run `export PATH="$HOME/.rbenv/shims:$PATH" LANG=en_US.UTF-8` first; don't hunt through `~/.rbenv/versions` or Homebrew Ruby.

- Never commit private network details (hosts, addresses, NAS paths): `spec/no_private_details_spec.rb` fails on them. The `check-prod` skill reads them from a gitignored `.claude/skills/check-prod/local.env`.

## Development Guidelines
- **Architecture**: Modular design with clear separation of concerns
- **Error Handling**: Comprehensive with user-friendly messages
- **Testing**: TDD approach with both unit and integration tests
- **CLI UX**: Thor framework with intuitive command structure
- **Performance**: Intelligent caching and tolerance-based skipping
- **Quality**: Industry-standard EBU R128 compliance

## Future Enhancements
- Additional normalization profiles
- Advanced Plex integration features
- GUI interface consideration

## docs/ Knowledge Base

Before starting significant work, read `docs/index.md` — it maps the full knowledge base.

All docs use YAML front matter (`id`, `type`, `purpose`). Validate against `docs/front-matter-schema.json`.

When you create or significantly update a doc:
1. Update `docs/index.md` if a doc was added, removed, or renamed.
2. Append to `docs/log.md`: `## [YYYY-MM-DD] <verb> | <title>` (verbs: create, update, delete, lint, synthesise, ingest).

When answering a question that synthesised **3+ docs/**, offer to save it as a research note in `docs/research/`.
