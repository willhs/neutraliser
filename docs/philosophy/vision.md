---
type: note
status: active
owner: will
contributors: []
updated: 2026-11-01
review_cycle: 90d
agent_write: false
links: []
summary: "Vision: never reach for the remote; dialogue steady across the library, loud moments within a limit, fidelity second"
tags: ["vision", "quality"]
---
# Vision

Never reach for the remote. Dialogue sits at a steady level across the whole library, and loud moments stay within a limit. Basis: [how streamers handle loudness and dialogue](../research/0002-streaming-loudness-and-dialogue/research.md).

## What it means

- **Dialogue first.** The aim is that speech plays at the same level from one file to the next, and that explosions and music don't leap out of it. Fidelity to the original mix comes second by default.
- **Loud moments are kept within a limit.** How much a file is compressed is decided by how far the programme sits above its dialogue, not by loudness range alone. Today the opt-in `--lra-target` and `--centre-boost` do this by loudness range; the dialogue-based trigger is still to come.
- **One flag gives the original dynamics back.** Constant gain, with nothing compressed, stays available as a single flag.
- **It can't fix everything.** A mumbled, badly mixed or masked line is quiet in the mix itself. Levelling the library can't make it intelligible.
- **Nothing else is touched.** Video, subtitles, chapters and extra audio tracks are copied as-is. `--keep-original-audio` keeps the untouched track alongside.
- **The re-encoded track keeps its quality.** It keeps the source codec and bitrate, and lossless stays lossless ([ADR-0001](../design/adr/0001-smart-codec-selection.md)).
- **Every change is visible.** Each file reports its gain, codec and whether compression was applied.
- **Others' defaults stay cautious.** For anyone else's library, Atmos, DTS and TrueHD stay left alone unless asked.

## Where we are (November 2026)

The default today is still constant gain with no compression, capped at the true-peak ceiling. That is the *old* default, and it does not yet match this vision: the vision's default is compression of loud moments. Compression exists only as opt-in flags. The change is staged, and no default changes until each step is done:

1. Fix the Dolby DRC and dialnorm bugs found in the research.
2. Add a read-only dialogue estimate.
3. Validate on real files.
4. Switch the default only if that holds.

The criteria for tagging 0.1 are in [the roadmap](../work/roadmap.md).
