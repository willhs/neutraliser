---
title: "Plex Library Audio Volume Analysis Guide"
created: 2025-09-25
updated: 2026-08-07
status: complete
owner: claude
contributors: []
review_cycle: 90d
agent_write: true
links: ["docs/work/tasks/0001-plex-library-analysis.md"]
summary: "Comprehensive guide for analyzing and normalizing Plex library audio levels"
tags: [plex, audio-analysis, user-guide]
---

# Plex Library Audio Volume Analysis Guide

## Overview

The `neutraliser analyze-plex` command provides comprehensive audio volume analysis for your entire Plex media library. This feature helps you identify media files with inconsistent audio levels before running batch normalization operations.

## Why Audio Analysis Matters

Different content types in your Plex library may have vastly different audio levels:

- **Movies**: Often mastered for theatrical presentation with wide dynamic range
- **TV Shows**: Typically normalized for consistent home listening
- **Mixed Content**: May have varying standards depending on source and age

Without analysis, you risk:
- Over-normalizing content that's already at appropriate levels
- Applying incorrect targets (e.g., TV show levels to movies)
- Wasting time processing files that don't need adjustment

## Audio Level Standards

### Target Levels: One Authority, Shared with `process`

`analyze-plex` no longer keeps its own per-content-type target table. It uses
the exact same `--profile`/`--tolerance` options as `neutraliser process`, so
whatever the report flags as "needs adjustment" is guaranteed to match what a
follow-up `process` run would actually do — no more separate movie/TV/other
numbers that disagreed with the profile system.

Available profiles (see `neutraliser profiles`):

| Profile      | Target LUFS | Notes                                   |
|--------------|-------------|------------------------------------------|
| `reference`  | -23.0       | Home theater / broadcast standard        |
| `livingroom` | -20.0       | TV/soundbar (default)                    |
| `night`      | -16.0       | Reduced dynamics for quiet listening     |

`--tolerance` (default `1.0` LU) controls how far a file can drift from the
target before it's flagged — same meaning, same default, as `process
--tolerance`.

If you want different targets for movies vs TV shows, run `analyze-plex`
(and the matching `process`) once per library with the profile that fits
that content, rather than relying on a built-in per-type table:

```bash
neutraliser analyze-plex --library "Movies" --profile reference
neutraliser analyze-plex --library "TV Shows" --profile livingroom
```

### What is LUFS?

LUFS (Loudness Units relative to Full Scale) measures perceived loudness, accounting for how human hearing responds to different frequencies. Unlike simple volume measurements, LUFS provides a more accurate representation of how loud content actually sounds to listeners.

## Getting Started

### Prerequisites

1. **Plex Media Server** running and accessible
2. **FFmpeg** installed on your system
3. **Plex Authentication Token** (for API access)

### Getting Your Plex Token

**Step 1: Access Plex Web Interface**
1. Open your browser and go to your Plex server: `http://localhost:32400/web`
   - Or replace `localhost` with your server's IP address
2. Sign in to your Plex account if prompted

**Step 2: Navigate to Account Settings**
1. Click your profile icon (top right corner)
2. Select "Account" from the dropdown menu
3. You'll be redirected to the Plex account page

**Step 3: Get Your Token**
1. Scroll down to find the "Authentication" section
2. Look for "X-Plex-Token" - this is your authentication token
3. Copy the long string of letters and numbers

**Step 4: Set Up .env File**
```bash
# Copy the example file
cp .env.example .env

# Edit the .env file and add your token
echo "PLEX_TOKEN=your_actual_token_here" > .env
```

**Alternative: Get Token from URL**
If you can't find the token in settings:
1. Go to any page in your Plex web interface
2. Look at the URL - it will contain `X-Plex-Token=abc123...`
3. Copy everything after the `=` sign

## Command Usage

### Basic Analysis

**Using .env file (recommended):**
```bash
neutraliser analyze-plex
```

**Requires .env file with PLEX_TOKEN=your_token**

### Full Command Options

```bash
neutraliser analyze-plex [OPTIONS]

Options:
  --server-url URL          Plex server URL (default: http://localhost:32400)
  --token TOKEN            Plex authentication token (overrides .env)
  --library NAME           Specific library to analyze (default: all video libraries)
  --output-format FORMAT   Report format: table, csv, json (default: table)
  --sample-percent N       Analyze only N% of files for large libraries (default: 100)
  --profile NAME           Normalization profile: reference, livingroom, night (default: livingroom)
  --tolerance N.N          Flag files within this many LU of target as OK (default: 1.0) — same as `process --tolerance`

Token Resolution:
1. --token option (overrides .env file)
2. PLEX_TOKEN from .env file (default)
```

### Example Commands

**Basic analysis with .env file:**
```bash
neutraliser analyze-plex --library "Movies"
```

**Quick sample analysis of large library:**
```bash
neutraliser analyze-plex --sample-percent 25 --library "TV Shows"
```

**Generate CSV report for external analysis:**
```bash
neutraliser analyze-plex --output-format csv
```

**Remote Plex server analysis:**
```bash
neutraliser analyze-plex --server-url http://192.168.1.100:32400
```

**Override token (not recommended for regular use):**
```bash
neutraliser analyze-plex --token abc123 --library "Movies"
```

## Understanding the Report

### Summary Statistics

The report begins with an overview:
- **Total files analyzed**: Number of media files processed
- **Files needing adjustment**: Count and percentage requiring normalization
- **Files within target range**: Already at appropriate levels
- **Breakdown by content type**: Statistics for movies vs TV shows vs other

### Detailed Results Table

Files requiring adjustment are listed with:
- **Title**: Media file name (truncated for readability)
- **Type**: Content classification (Movie, TV, Other)
- **Current**: Measured LUFS level
- **Target**: Recommended target level for content type
- **Diff**: Difference in dB (+ means too loud, - means too quiet)
- **Status**: Classification (Too Loud, Too Quiet, OK)

### Recommendations

The report concludes with:
- Count of files that are too loud/quiet
- Specific commands for normalization by content type
- Storage impact estimates (for copy mode)

## Practical Workflow

### Step 1: Setup .env File
Store your Plex token in .env:
```bash
cp .env.example .env
# Edit .env and add: PLEX_TOKEN=your_actual_token
```

### Step 2: Initial Analysis
Start with a sample analysis to understand your library:
```bash
neutraliser analyze-plex --sample-percent 10
```

### Step 3: Profile Strategy
Based on results, decide on approach:

**Mixed Library**: Analyze and process each type with the profile that fits it
```bash
# Movies: home-theater/broadcast standard
neutraliser analyze-plex --library "Movies" --profile reference
neutraliser process /path/to/movies --profile reference

# TV shows: soundbar/living-room standard (the default)
neutraliser analyze-plex --library "TV Shows" --profile livingroom
neutraliser process /path/to/tv --profile livingroom
```

**Consistent Playback**: Use a single profile for everything
```bash
neutraliser analyze-plex --profile livingroom
neutraliser process /path/to/library --profile livingroom
```

### Step 4: Full Analysis
Run complete analysis before batch processing:
```bash
neutraliser analyze-plex --output-format csv
```

### Step 5: Batch Processing
Process files by priority (most problematic first):
- Files with largest deviations
- Most frequently watched content
- New acquisitions

## Performance Considerations

### Large Libraries

For libraries with 1000+ files:

**Use Sampling**: Analyze a representative sample first
```bash
neutraliser analyze-plex --sample-percent 20
```

### System Requirements

- **CPU**: More cores help with concurrent analysis
- **Memory**: 2GB+ recommended for large libraries
- **Storage**: Temporary space for analysis files
- **Network**: Fast connection to Plex server recommended

## Troubleshooting

### Connection Issues

**Error: Cannot connect to Plex server**
- Verify server URL and port (usually 32400)
- Check if server is accessible: `http://server:32400/web`
- Ensure server allows API access

**Error: No Plex token found**
- Check .env file exists: `ls -la .env`
- Verify token in .env file: `cat .env` (should show PLEX_TOKEN=...)
- Ensure no extra whitespace around the token
- Try generating a new token from Plex web interface

### Analysis Issues

**Error: No audio tracks found**
- Some video files may lack audio streams
- These files are automatically skipped
- Consider separate processing for video-only files

**Warning: could not analyze loudness / item skipped**
- A measurement failure (timeout, network error, unreadable stream) makes
  `analyze-plex` skip that item and log the error — it never fabricates a
  placeholder LUFS value, so a skipped item never shows up disguised as a
  real (and wrong) measurement in the report
- Consider updating FFmpeg to latest version

### Performance Issues

**Analysis taking too long**
- Use sampling for initial assessment
- Reduce concurrent jobs if system struggles
- Consider analyzing specific libraries separately

**High memory usage**
- Reduce concurrent jobs
- Process smaller libraries separately
- Close other applications during analysis

## Advanced Usage

### Integration with Scripts

The CSV and JSON output formats enable integration with custom scripts:

**Python processing example:**
```python
import pandas as pd

# Load analysis results
df = pd.read_csv('plex_audio_analysis_20250925_143022.csv')

# Find most problematic files
worst_files = df[df['Level Difference (dB)'].abs() > 5]
print(f"Files needing urgent attention: {len(worst_files)}")
```

### Custom Target Levels

`--target_level` still works on `process` for a one-off numeric LUFS target
that doesn't match any named profile (`analyze-plex` doesn't expose this —
it reports against a named `--profile`, matching what `process` will do by
default):

```bash
neutraliser process /library --target_level -27
```

## Best Practices

1. **Always analyze before normalizing** - Understanding your library's current state prevents unnecessary processing

2. **Use appropriate targets by content type** - Movies and TV shows have different mastering standards

3. **Start with samples** - Large libraries should be sampled first to understand scope

4. **Process incrementally** - Normalize most problematic files first, then work through remaining content

5. **Backup before processing** - Use copy mode initially, only use replace mode after verification

6. **Monitor system resources** - Adjust concurrent jobs based on system performance

7. **Document your approach** - Keep records of targets used for different content types

## Technical Notes

### LUFS Measurement Accuracy

- Streams straight off the Plex server and measures via the same
  `FFmpegWrapper` executor `process` uses for local files — no shell string,
  no temp file. Each item samples the first 60s of audio (a fast preview
  across a whole library, not the definitive measurement `process` performs
  on the full file when you actually normalize).
- A failed or timed-out measurement is skipped and logged, never replaced
  with a fabricated/placeholder LUFS value.
- Measurements align with broadcast and streaming industry standards.

### Content Type Detection

- Movies: Detected from Plex library type and metadata
- TV Shows: Episodes and series from TV library sections
- Other: Mixed content, music videos, home recordings
- Content type is used for report grouping only — it no longer selects a
  different target level per type (see "Target Levels" above).

### File Processing

- Preserves video streams (copy mode for efficiency)
- Only re-encodes audio tracks for normalization
- Maintains original video quality and compression

### Security: Plex Token Handling

- The token is never embedded in the streaming URL or joined into a shell
  string. It's sent as an HTTP header for the Plex API and as an `ffmpeg
  -headers` argument (not part of the URL/argv) for stream measurement, so
  it never appears in `ps` output or shell history.

## Change Log

- 2026-08-07: Folded into the main pipeline (FFmpegWrapper/Measurement/Profiles/Logger); fixed the token-in-shell and sentinel-float bugs. `--concurrent-jobs`/`--cache-results` (never implemented) removed from docs; `--profile`/`--tolerance` added, replacing the old per-content-type target table.
- 2025-09-25: Initial guide creation with comprehensive usage instructions