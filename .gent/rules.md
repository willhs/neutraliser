# Neutraliser - Video Audio Volume Normalisation CLI

## Project Overview
A Ruby CLI tool that normalises audio volume in video files using industry-standard EBU R128 loudness normalization to create consistent playback levels throughout your video library.

## Technical Context
- **Language**: Ruby
- **Type**: Command-line interface with Thor
- **Purpose**: EBU R128 video audio volume normalisation
- **Dependencies**: FFmpeg 4.2+ for video/audio processing
- **Status**: ✅ **FULLY IMPLEMENTED** - Production ready

## Architecture Overview

### Core Components
- **`Processor`**: Main orchestration class handling file/directory processing
- **`SkipDecider`**: Single authority for "already normalised?" — the in-file `NEUTRALISER_*` stamp for the same profile, cached in one `.neutraliser` sidecar (size+mtime+profile), quick LUFS sampling as an internal fallback
- **`Stamp`**: Value object for the `NEUTRALISER_*` tags written on the normalised track and container (schema: `docs/ops/data_contracts.md`)
- **`Report`**: `neutraliser report PATH` — reads stamps, counts linear/dynamic/untouched and profiles
- **`FFmpegWrapper`**: Two-pass loudnorm implementation, ffprobe, source-matched codec selection
- **`ObjectAudio`**: Detects Atmos / DTS:X on the primary track (ffprobe profile, name-hinted mid-file probe) so it is skipped, not silently flattened
- **`AudioAnalyser`**: Full loudnorm measurement coordination with sidecar caching
- **`Measurement`**: Value object for loudnorm measurement results
- **`Profiles`**: Normalization profile system (reference/livingroom/night)
- **`FileManager`**: Atomic file operations with integrity verification
- **`CacheManager`**: Sidecar `.loudnorm_{profile}.json` caching system for analysis results
- **`LocalStager`**: Stages files to local disk (`--local-stage`) before processing, copies results back
- **`PlexAnalyzer`**: Plex library integration for media analysis, routed through FFmpegWrapper/Measurement/Profiles
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
- `neutraliser report PATH [--format summary|tsv|json]` - What was done to each file, from its tags
- `neutraliser profiles` - List normalization profiles
- `neutraliser analyze-plex` - Plex library analysis
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
- `--linear-only` - Deprecated no-op alias (constant gain is the default)

## Testing Strategy ✅ COMPLETED

### Comprehensive Test Suite (Phase 4)
- **Unit Tests**: All components (FFmpegWrapper, AudioAnalyser, Profiles, etc.)
- **Integration Tests**: Real media processing with mocked FFmpeg
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
