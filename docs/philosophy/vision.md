---
type: note
status: active
owner: will
contributors: []
updated: 2026-10-15
review_cycle: 90d
agent_write: false
links: []
summary: "Vision: consistent volume across your media library, with the least lossy audio processing possible"
tags: ["vision", "quality"]
---
# Vision

Consistent volume across your media library, at the smallest possible cost to quality. Never reach for the remote between films again.

## Least lossy

Neutraliser does one job: level the volume between files. Everything else is left alone.

- **Constant gain by default.** The whole file moves up or down by one amount, so the mix keeps its original dynamics
- **Compression is a choice.** Profiles that narrow dynamic range (like `night`) are opt-in, named for what they do and reported when they run
- **Nothing else is touched.** Video, subtitles, chapters and extra audio tracks are copied as-is
- **The re-encoded track keeps its quality.** It keeps the source codec and bitrate, and lossless stays lossless ([ADR-0001](../design/adr/0001-smart-codec-selection.md))
- **Every change is visible.** Each file reports its gain, codec and whether compression was applied

## Where we are (October 2026)

The default `livingroom` profile still lets FFmpeg's loudnorm fall back to dynamic compression when a file's loudness range is over 12 LU or its peaks won't fit. On the NAS TV library, 2,026 of 3,208 processed files (63%) were compressed. Making constant gain the default closes that gap.
