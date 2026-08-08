---
type: note
status: active
owner: will
contributors: []
updated: 2026-08-09
review_cycle: 90d
agent_write: false
links: []
summary: "Pre-release validation run over a slice of the real NAS/Plex library — one bug found and fixed"
tags: [research, release, quality]
---

## Context / Purpose

Pre-release confidence pass before the public launch: run neutraliser over a representative
slice of the real media library (mixed codecs, containers, multi-track/subtitled files, awkward
filenames) and log anything a stranger would hit.

## Method

Copying whole BluRay-remux files (1.4–6.2 GB each) over the home network was slow, so each
selected file was **remuxed to a ~2 minute clip on the NAS itself first** (`ffmpeg -ss 60 -t 120
-c copy`, stream copy only — no re-encode, no quality loss, real codec/container/stream
structure preserved) and only the small clip was pulled to a local scratch dir. This kept the
run fast while still exercising the real files' actual streams, tags, and edge-case filenames.
NAS originals were never touched — `--dry-run` first, then `--replace` only on the local scratch
copies.

Selected 8 files from `/volume1/media/movies` for codec/container/filename variety:

| File | Container | Audio codec | Notes |
|---|---|---|---|
| Amélie (2001) | mkv | ac3 (dual track) | unicode filename, 3 subtitle tracks, 16 chapters |
| Brüno (2009) | mp4 | aac | unicode filename |
| Casablanca [Ultimate Collector's Edition] | avi | aac | brackets + apostrophe in filename |
| Fritz.The.Cat.1972...-[YTS.MX] | mp4 | aac | brackets in filename |
| Kill Bill Vol. 1 (2003) | mkv | eac3 (DDP) 640k | |
| Madagascar - Escape 2 Africa (2008) | mkv | truehd 3091k, 7.1 | Atmos, DoVi/HDR10 |
| Star Wars Episode VII (2015) | mkv | dts | |
| The Mask (1994) | mkv | eac3 (Atmos) 768k | 3 audio tracks, 45 subtitle tracks, DoVi/HDR10 |

## Result: dry-run + normalise pass

All 8 files processed cleanly — **no crashes, no failed files.** Skip decisions were sensible
(2 of 8 already within tolerance of -20 LUFS livingroom target, correctly skipped both in
dry-run and the real run). Codec selection matched source codec/bitrate everywhere it could
(ac3→ac3, aac→aac, eac3→eac3 including Atmos-tagged DDP), and TrueHD correctly fell back to
lossless FLAC per [ADR-0001](../design/adr/0001-smart-codec-selection.md) — expected, not a bug
(file grew ~23% as a result, which is the documented lossless-fallback tradeoff, not corruption).
Unicode, brackets, and apostrophes in filenames/paths caused no issues anywhere in the pipeline.

## Bug found and fixed: video/subtitle stream metadata silently dropped

**Before → after diff on the Amélie file** (fresh clip vs. the `--replace`d copy) showed:

- Video stream's `language`/`title` tags (`fre` / "1080p - x265") — **dropped**
- All 3 subtitle streams' `language`/`title` tags (eng/English, spa/Spanish, fre/French) —
  **dropped**
- The tagged (non-primary) audio track's tags — preserved correctly
- Chapters (16, with titles), container title, and all disposition flags — preserved correctly

Confirmed on The Mask (1994) too: all 45 subtitle tracks lost their language/title tags.

This directly contradicted the README's advertised feature: *"Full stream preservation — every
audio/subtitle track, per-stream metadata (titles, languages)... survive the round trip."*
Neither ADR-0001 nor ADR-0002 documents metadata/subtitle handling as a decision — the README
claim wasn't backed by a design record, and the implementation didn't actually do it for two of
the three stream types it claimed to cover.

**Root cause** (`lib/neutraliser/ffmpeg_wrapper.rb`, `build_complete_ffmpeg_command`): the
primary audio track goes through `filter_complex` into a synthetic `[norm]` stream with no
implicit source-stream link, so it needs an explicit `-map_metadata:s:a:N` back to its source
index — and once *any* stream-scoped `-map_metadata` is present, ffmpeg disables its default
implicit per-stream metadata auto-copy for the **entire command**, not just the streams that
got an explicit mapping. The audio loop covered every audio output stream, but there was no
equivalent loop for video or subtitle streams — both are stream-copied (`-c:v copy`, `-c:s
copy`) and lost their tags as a side effect of the audio-track fix, even though neither one was
touched by that logic.

**Fix**: added `FFmpegWrapper.stream_counts` (a best-effort ffprobe count of video/subtitle
streams) and extended `build_complete_ffmpeg_command` to emit `-map_metadata:s:v:N` /
`-map_metadata:s:s:N` for every video/subtitle output stream, mirroring the existing audio loop.
Verified against the real Amélie file post-fix: video and all 3 subtitle tracks now round-trip
their language/title tags correctly. Added regression coverage: a unit test asserting the new
mapping args, and extended the existing real-ffmpeg integration test
(`spec/ffmpeg_wrapper_spec.rb`) with a video-tagged, subtitle-tagged fixture. Full suite green
(183 examples, 0 failures).

## Takeaway

The core normalisation/codec-selection/skip-decision pipeline is solid against real-world files
— zero crashes or wrong skip decisions across the slice. The one real bug found was a
metadata-preservation gap that would have hit anyone with a subtitled or multi-language library
(a large fraction of the target audience) and directly contradicted an advertised README
feature. Worth another slice pass after any future change to `build_complete_ffmpeg_command`,
since this class of bug (ffmpeg's implicit-copy-disabling behaviour) is easy to reintroduce.
