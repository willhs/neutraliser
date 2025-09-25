---
title: "Plex Library Audio Volume Analysis"
created: 2025-09-25
updated: 2025-09-25
status: in_progress
assignee: claude
priority: high
estimated_effort: "4-6 hours"
related_issues: []
tags: [plex, audio-analysis, feature]
---

# Plex Library Audio Volume Analysis

## Overview

Add a command to analyze a user's Plex library and report on media library audio volume levels, identifying files that are significantly off from ideal levels.

## Problem Statement

Users need to understand the current state of their entire Plex media library's audio levels before running batch normalization operations. Without this analysis, they risk:

- Over-normalizing content that's already at good levels
- Not knowing which content types (movies vs TV) need different treatment
- Lack of visibility into the scope of normalization work needed

## Solution Design

### Audio Level Standards & Targets

Based on industry research, we recommend the following target levels:

**Movies & Films:**
- Target: -27 LUFS (Netflix standard for theatrical content)
- Acceptable range: -25 to -29 LUFS
- Rationale: Movies are typically mastered with wider dynamic range for theatrical presentation

**TV Shows & Series:**
- Target: -23 LUFS (broadcast television standard ITU-R BS.1770-4)
- Acceptable range: -21 to -25 LUFS
- Rationale: TV content is typically mastered for consistent home listening

**General Streaming Content:**
- Target: -14 LUFS (modern streaming platform standard)
- Acceptable range: -12 to -16 LUFS
- Rationale: Most streaming platforms normalize to this level

### Practical Implementation Approach

1. **Library Access:** Use Plex API via Ruby gem (safer than direct SQLite access)
2. **Content Type Detection:** Distinguish between movies, TV shows, and other content
3. **Batch Analysis:** Process files in chunks to avoid overwhelming the system
4. **Intelligent Targeting:** Apply different target levels based on content type
5. **Reporting:** Generate actionable reports with recommendations

### Command Interface Design

```bash
neutraliser analyze-plex [OPTIONS]

Options:
  --server-url URL          Plex server URL (default: http://localhost:32400)
  --token TOKEN            Plex authentication token
  --library NAME           Specific library to analyze (default: all video libraries)
  --output-format FORMAT   Report format: table, csv, json (default: table)
  --sample-percent N       Analyze only N% of files for large libraries (default: 100)
  --concurrent-jobs N      Number of concurrent analysis jobs (default: 4)
  --cache-results          Cache analysis results to avoid re-analyzing
```

### Analysis Report Format

The report should include:

1. **Library Overview:**
   - Total files analyzed
   - Content type breakdown (movies vs TV vs other)
   - Overall audio level distribution

2. **Target Recommendations:**
   - Files significantly below target (-3 LUFS or more)
   - Files significantly above target (+3 LUFS or more)
   - Files within acceptable range

3. **Actionable Summary:**
   - Estimated normalization time
   - Storage space impact (if creating copies)
   - Recommended batch processing order

## Technical Implementation Plan

### Phase 1: Library Connection & Discovery
- [ ] Add plex-ruby gem dependency
- [ ] Implement Plex server connection
- [ ] Discover video libraries
- [ ] Extract file paths and metadata

### Phase 2: Audio Analysis Engine
- [ ] Integrate proper LUFS measurement (ffmpeg-normalize or similar)
- [ ] Replace placeholder analyze_loudness method
- [ ] Add content type detection logic
- [ ] Implement batch processing with progress reporting

### Phase 3: Reporting & Recommendations
- [ ] Design report data structures
- [ ] Implement multiple output formats
- [ ] Add target level recommendations based on content type
- [ ] Calculate processing estimates

### Phase 4: CLI Integration
- [ ] Add analyze-plex command to Thor CLI
- [ ] Implement authentication handling
- [ ] Add progress indicators and error handling
- [ ] Add caching for large libraries

## Risks & Mitigations

**Risk: Plex API authentication complexity**
- Mitigation: Provide clear setup instructions, support both token and interactive auth

**Risk: Large libraries causing performance issues**
- Mitigation: Implement sampling, chunked processing, and caching

**Risk: Inaccurate LUFS measurement**
- Mitigation: Use proven tools like ffmpeg-normalize, validate against known test files

**Risk: Different content requiring different treatments**
- Mitigation: Content type detection and configurable targets per type

## Success Criteria

1. Successfully connects to and analyzes Plex libraries
2. Accurately measures LUFS levels using industry-standard tools
3. Provides actionable recommendations with different targets for movies vs TV
4. Generates clear reports in multiple formats
5. Handles large libraries (1000+ files) efficiently
6. Caches results to avoid re-analysis

## Change Log

- 2025-09-25: Initial task creation and research completion