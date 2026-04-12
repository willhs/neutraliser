---
type: note
status: active
owner: will
contributors: []
updated: 2026-04-12
review_cycle: 90d
agent_write: false
links: []
summary: "Entry point and contribution map for neutraliser"
tags: []
---

> **Agents**: Read this file before starting any significant work.

## Purpose
Entry point and navigation map for the neutraliser documentation set. Neutraliser is a Ruby CLI tool for EBU R128 audio volume normalisation of video libraries.

## Philosophy
- [`philosophy/vision.md`](philosophy/vision.md) — North star: consistent volume for your media library
- [`philosophy/form.md`](philosophy/form.md) — Shape of the tool: Ruby CLI, volume pipeline, copy or replace

## Design
- [`design/architecture.md`](design/architecture.md) — Normalisation pipeline, codec selection, component table, performance flags
- [`design/adr/0001-smart-codec-selection.md`](design/adr/0001-smart-codec-selection.md) — Decision: match source codec and bitrate instead of hardcoding AAC/AC3
- [`design/adr/0002-performance-flags.md`](design/adr/0002-performance-flags.md) — Decision: `--fast` and `--local-stage` flags; benchmark results
- [`design/plex-analysis-guide.md`](design/plex-analysis-guide.md) — User guide for the `analyze-plex` command

## Operations
- [`ops/runbook.md`](ops/runbook.md) — Operational procedures and recovery steps
- [`ops/quality.md`](ops/quality.md) — Quality strategy, SLOs, and testing approach
- [`ops/data_contracts.md`](ops/data_contracts.md) — Schemas, SLAs, and backward-compatibility expectations

## Research
- [`research/landscape.md`](research/landscape.md) — Market and prior-art survey

## Tasks
- [`tasks/0001-plex-library-analysis/task.md`](tasks/0001-plex-library-analysis/task.md) — Plex library audio analysis command (complete)
- [`tasks/0002-video-volume-normalisation/task.md`](tasks/0002-video-volume-normalisation/task.md) — Core video normalisation implementation (complete)
- [`tasks/0002-video-volume-normalisation/plan.md`](tasks/0002-video-volume-normalisation/plan.md) — Implementation plan for EBU R128 two-pass upgrade
- [`tasks/0003-performance-optimization/task.md`](tasks/0003-performance-optimization/task.md) — Performance investigation for large media batches
- [`tasks/0003-performance-optimization/plan.md`](tasks/0003-performance-optimization/plan.md) — Performance optimization implementation plan
- [`tasks/0004-preserve-audio-quality/task.md`](tasks/0004-preserve-audio-quality/task.md) — Preserve audio quality by matching source codec/bitrate (complete)
- [`tasks/0004-preserve-audio-quality/plan.md`](tasks/0004-preserve-audio-quality/plan.md) — Implementation plan for smart codec selection
- [`tasks/0005-local-staging-and-fast-mode/task.md`](tasks/0005-local-staging-and-fast-mode/task.md) — Local NVMe staging and single-pass fast mode (complete)
- [`tasks/0005-local-staging-and-fast-mode/plan.md`](tasks/0005-local-staging-and-fast-mode/plan.md) — Implementation plan for staging and fast mode

## Doc Schema
- [`front-matter-schema.json`](front-matter-schema.json) — JSON Schema for validating doc frontmatter

### Change Log
- 2025-09-24 (agent:create-project): Created initial documentation index scaffold
- 2026-04-12 (agent:docs-lint): Rebuilt with agent notice, linked entries, orphaned files added, broken links removed
