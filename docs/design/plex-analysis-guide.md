---
title: "Plex Library Audio Volume Analysis Guide"
created: 2025-09-25
updated: 2025-09-25
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

### Target Levels by Content Type

**Movies & Films: -27 LUFS**
- Based on Netflix theatrical content standard
- Preserves intended dynamic range for cinematic experience
- Acceptable range: -25 to -29 LUFS

**TV Shows & Series: -23 LUFS**
- Based on broadcast television standard (ITU-R BS.1770-4)
- Optimized for consistent home viewing
- Acceptable range: -21 to -25 LUFS

**General/Mixed Content: -14 LUFS**
- Modern streaming platform standard (Spotify, YouTube, etc.)
- Good for general purpose content
- Acceptable range: -12 to -16 LUFS

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
  --concurrent-jobs N      Number of concurrent analysis jobs (default: 4)
  --cache-results          Cache analysis results to avoid re-analyzing

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

### Step 3: Content Type Strategy
Based on results, decide on approach:

**Mixed Library**: Use content-specific targets
```bash
# Normalize movies to cinema standard
neutraliser process /path/to/movies --target-level -27

# Normalize TV shows to broadcast standard
neutraliser process /path/to/tv --target-level -23
```

**Consistent Playback**: Use single standard
```bash
# Normalize everything to streaming standard
neutraliser process /path/to/library --target-level -14
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

**Concurrent Processing**: Adjust based on system resources
```bash
neutraliser analyze-plex --concurrent-jobs 8  # More powerful systems
neutraliser analyze-plex --concurrent-jobs 2  # Slower systems
```

**Enable Caching**: Avoid re-analyzing unchanged files
```bash
neutraliser analyze-plex --cache-results
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

**Warning: Could not analyze loudness**
- Fallback analysis will be used
- Results may be less accurate
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

Override default targets for specific use cases:

**Home Theater Setup**: Use cinema levels for all content
```bash
neutraliser process /library --target-level -27
```

**Apartment Living**: Use TV levels to avoid disturbing neighbors
```bash
neutraliser process /library --target-level -23
```

**Background Listening**: Use streaming levels for consistency
```bash
neutraliser process /library --target-level -14
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

- Uses FFmpeg's `loudnorm` filter for precise LUFS measurement
- Falls back to RMS-based approximation if primary measurement fails
- Measurements align with broadcast and streaming industry standards

### Content Type Detection

- Movies: Detected from Plex library type and metadata
- TV Shows: Episodes and series from TV library sections
- Other: Mixed content, music videos, home recordings

### File Processing

- Preserves video streams (copy mode for efficiency)
- Only re-encodes audio tracks for normalization
- Maintains original video quality and compression

## Change Log

- 2025-09-25: Initial guide creation with comprehensive usage instructions