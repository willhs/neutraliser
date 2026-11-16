---
id: 71-and-atmos-real-files
type: note
purpose: "Does the 7.1 and Atmos path behave on real library files as the specs say? Counts of 7.1 / Atmos tracks in the Plex library, and 8 real tracks run through the current measure and plan path, read-only."
scope:
  - "The Plex library's audio streams (JSON metadata only): how many 8-channel, Atmos and DTS:X tracks exist"
  - "8 real tracks measured on a scratch copy of the primary audio: current meter, loudnorm alone, plain ffmpeg ebur128, an independent numpy BS.1770 meter, `process --dry-run` (default, --ladder, --ladder with both allow flags), `analyze-plex`"
  - "Three more 7.1 films (two E-AC-3, one HE-AAC) as 240 s slices through a real `process --replace`, scratch only"
non_goals:
  - "No library write, remux, stamp or sidecar next to media; no Plex or NAS change; no code change in `lib/`"
  - "Four of the twelve planned files were not completed (see Not done)"
tags: ["research", "7.1", "atmos", "validation", "side-channels"]
related:
  - "docs/research/0005-dialogue-estimate-real-files/research.md"
  - "docs/research/object-audio-detection.md"
  - "docs/ops/runbook.md"
---

# 7.1 and Atmos on real files

Run 2026-11-16 to 17 on the Mac that did research 0005 (Plex and `.env` reachable; Plex idle-gated before every read, one Plex read at a time). Vision alignment: Release neutraliser publicly (7.1 has so far been checked on fixtures only).

## Verdict

**Mostly yes, with two real mismatches.** On the 5 real 7.1 and Atmos tracks measured end to end, the current meter agrees with two independent readings (within 0.1 LU on loudness and range, 0.05 against a numpy BS.1770 meter), the side-channel fix matters by 0.15 to 0.4 LU as the runbook says, Atmos tracks are skipped as `object_audio` before any measuring, and a title whose *name* claims Atmos but whose stream does not is processed with a note. Two things do not match the specs:

1. **E-AC-3 7.1 under `--ladder` is re-encoded and then rejected** (`output_verification_failed`, 8 channels to 5), and `--dry-run` says it would work. Fails safe (original untouched), but every such file costs a full encode per sweep. This is the parked skip/convert item. Task `00481ce5`.
2. **`analyze-plex` reads the first audio stream and Plex's channel count, a sweep reads the default-flagged track.** They differ on 57 titles in the library, including a Dolby Atmos film whose Atmos track a sweep never touches. Task `a9d2e20a`.

| Question | Answer | Confidence |
|---|---|---|
| How many 8-channel audio tracks does the library have? | **13**, all on films, none on TV: TrueHD 4 (all Atmos), E-AC-3 4, AAC 3, FLAC 2 (the two FLAC are two Plex entries of one 25.5 GB title). 12 are the title's selected track | [Direct] `data/scan.jsonl`, `data/scan_summary.json` |
| How many Atmos tracks? | **39** carry an Atmos profile in Plex's stream data (10 films, 29 episodes): 4 TrueHD (7.1) and 35 E-AC-3 JOC (5.1 bed). A further 14 tracks only *say* Atmos in a name or title | [Direct] same files |
| DTS-HD MA 7.1, DTS:X? | **None.** All DTS-HD MA tracks are 6 channels; no DTS:X profile anywhere | [Direct] |
| Do the side channels change the reading on real 7.1? | Yes: loudness 0.15 to 0.37 LU higher than loudnorm alone (4 tracks), range 0.1 to 0.2 LU wider | [Direct] table below |
| Does the current meter match an independent one? | Yes: plain ffmpeg `ebur128` within 0.1 LU (I, LRA, TP); numpy BS.1770-4 within 0.05 LU on all 8 | [Direct] |
| Does a sweep do what the specs say with Atmos? | Yes: TrueHD Atmos 7.1 and E-AC-3 JOC both `object_audio` skip, ahead of measuring; with `--allow-object-audio-loss --allow-codec-change --ladder` the dry run plans compression and level | [Direct] `cli_*` lines in `data/results.jsonl` |

## Counting the library

Query: every title's stream list from Plex's metadata API (`lab/scan.rb`, 811 films and 8,503 episodes, 10,958 audio tracks; JSON only, no media bytes). A track is counted when it has 7 or more channels, or its Plex stream profile or title says Atmos, DTS:X or JOC.

| | Films | Episodes |
|---|---|---|
| Titles | 811 | 8,503 |
| 8-channel tracks | 13 | 0 |
| Atmos by stream profile | 10 (4 TrueHD, 6 E-AC-3) | 29 (E-AC-3 JOC) |
| Tracks whose name or title says Atmos, stream profile does not | 6 (5 titles) | 8 (Andor S1: title "TrueHD 7.1 Atmos", stream E-AC-3 5.1) |

Note the Plex profile is Plex's own. For the 8 tracks measured, ffprobe's profile on the stream-copied scratch file matched Plex's (see `object_audio` in the data).

## Per-file results

Eight tracks, primary track copied to scratch (one Plex read each). Loudness in LUFS, peaks in dBTP. "Cur" is the current path (loudnorm plus ebur128 over all channels above six); "LN" is loudnorm alone, which is what 7.1 got before 13 Nov; "EB" plain `ffmpeg -af ebur128`; "NP" is `lab/bs1770.py`.

| Title (kind) | Primary track | Cur I / TP / LRA | LN I / LRA | EB I / LRA | NP I / LRA | Sweep: default | Sweep: `--ladder` |
|---|---|---|---|---|---|---|---|
| Madagascar 2 (film) | TrueHD Atmos 7.1 | -22.0 / -0.1 / 16.1 | -22.37 / 15.9 | -22.0 / 16.1 | -21.96 / 16.14 | skip `object_audio` | skip `object_audio` (allow flags: compress gentle+limiter, LRA 16.1 to 10.6) |
| Forrest Gump (film) | TrueHD Atmos 7.1 | -25.1 / +0.1 / 21.8 | -25.25 / 21.7 | -25.1 / 21.8 | -25.08 / 21.82 | skip `object_audio` | skip `object_audio` (allow: compress strong+limiter, 21.8 to 14.0) |
| Matrix Resurrections (film) | TrueHD Atmos 7.1 | -18.9 / +0.4 / 22.8 | -19.26 / 22.6 | -18.9 / 22.8 | -18.88 / 22.78 | skip `object_audio` | skip `object_audio` (allow: compress strong+limiter, 22.8 to 12.9) |
| The Martian (film) | E-AC-3 7.1 | -21.8 / +16.5 / 16.5 | -22.09 / 16.5 | -21.8 / 16.5 | -21.81 / 16.54 | `peak_limited` skip | would compress gentle+limiter (real run fails, below) |
| Godzilla (film) | a:0 AC-3 5.1 (the 7.1 E-AC-3 is a:1, not default) | -20.0 / -1.4 / 7.7 | same | -20.0 / 7.7 | -19.97 / 7.7 | `within_tolerance` | `within_tolerance` |
| Andor S2E10 (TV) | E-AC-3 JOC Atmos 5.1 | -20.66 / -0.5 / 21.7 | same | -20.6 / 21.8 | -20.62 / 21.77 | skip `object_audio` | skip `object_audio` (allow: compress moderate+limiter, 21.7 to 13.4) |
| Andor S1E1 (TV) | E-AC-3 5.1, title says "TrueHD 7.1 Atmos" | -20.15 / -0.8 / 10.5 | same | -20.1 / 10.6 | -20.12 / 10.61 | note "name suggests object audio but ffprobe found none", then `within_tolerance` | same |
| The Little Mermaid (film) | **Spanish** E-AC-3 5.1 (default); the English Atmos track is a:0 but not default | -20.66 / -1.75 / 15.2 | same | -20.6 / 15.3 | -20.63 / 15.27 | name-hint note, `within_tolerance` | name-hint note, compress gentle+limiter (15.2 to 9.7) |

(The Martian's +16.5 dBTP is over the whole film with DRC off, the product's setting. A 4-minute slice from the middle read -25.5 LUFS and -1.4 dBTP with DRC off, -29.5 and -5.2 with DRC on. The film has a few very loud events its DRC words pull down.)

What the table shows:

- **Meters agree.** Across the 8, current vs plain `ebur128`: loudness equal to within 0.1, range within 0.1; vs numpy: loudness within 0.05, range within 0.05. That checks wiring, DRC handling and channel weighting for 7.1 (numpy applies 1.41 to the four surround channels and drops the LFE).
- **Side channels move 7.1 up 0.15 to 0.37 LU** (Madagascar +0.37, Matrix +0.36, Martian +0.29, Gump +0.15) and widen the range by 0.1 to 0.2 LU, so the old meter read these tracks low by that much. Matches the runbook's "up to ~1.8 LU in the fixture; more with loud sides" qualitatively; the real films are at the low end. The old meter would not have flipped any decision here (`decision_if_old_meter` in the data equals the current one on all eight).
- **Object audio skip fires before measuring** for TrueHD Atmos and E-AC-3 JOC, as `docs/design/architecture.md` says, and the allow flags lift it.
- **Name-only claims are not trusted**: Andor S1E1 and The Little Mermaid's primary (Spanish) get the "suspected" note and are processed on their measured level.
- **Ladder rung 3 triggers on every title with LRA above 13**: six of the 8 measured (LRA 15.2 to 22.8). Expected from the ladder spec; worth noticing that these real films and episodes often have LRA 16 to 23.

## Atmos, the TrueHD container question

On the three TrueHD Atmos files the ffprobe profile on the stream-copied scratch mkv was "Dolby TrueHD + Dolby Atmos", same as over HTTP, so detection does not depend on the original container. [Direct]

## E-AC-3 and AAC 7.1: what a real encode does

`lab/slices.rb`: a 240 s slice from mid-film, copied to scratch, then the real `process --replace` (recipe 2) and `process --replace --ladder`.

| Slice | Source | Recipe 2 | `--ladder` |
|---|---|---|---|
| The Martian | E-AC-3 7.1, 448k | `peak_limited` skip | encodes E-AC-3 560k, **fails** `output_verification_failed`: "normalised track has 5 channels, source has 8" |
| Star Trek Into Darkness | E-AC-3 7.1, 1024k | `peak_limited` skip | compresses, encodes E-AC-3 1280k, **fails** the same way |
| Star Wars III | HE-AAC 7.1, 210k | `within_tolerance` skip | compress, AAC 7.1 263k LC, done (the profile goes HE to LC) |

So E-AC-3 7.1 (4 tracks in the library, 3 of them a title's selected track) survives the default recipe only because its peaks block the gain; under `--ladder` it fails after a full encode. FFmpeg's `eac3` encoder is limited to 6 channels, `CodecChoice.resolve_encoder` returns it anyway. The runbook documents the failure class ("a 7.1 track through a 5.1-only encoder ends up here"), so the outcome matches the spec, but the dry run's "would compress and level" does not. [Direct for the three slices; [Inferred] for the other E-AC-3 7.1 files]

AAC 7.1 does encode back to 8 channels, as the output check requires. Quality of a 7.1 HE-AAC to AAC-LC 263k pass was not judged by ear.

## analyze-plex on these files

Sampled estimate (five 60 s windows) against the exact reading from the local scratch copy:

| Title | analyze-plex | Range | Exact | Truth in range? |
|---|---|---|---|---|
| Madagascar 2 | -23.19 | -24.7 to -16.2 | -22.0 | yes |
| Forrest Gump | -32.21 ("too quiet") | -33.7 to -25.2 | -25.1 | no, by 0.1 |
| Matrix Resurrections | -23.63 | -25.1 to -16.6 | -18.9 | yes |
| The Martian | -19.79 | -21.3 to -12.8 | -21.8 | no, by 0.5 |
| Godzilla | -21.26 | -22.8 to -14.3 | -20.0 | yes |
| Andor S2E10 | -22.35 | -23.9 to -15.4 | -20.66 | yes |
| Andor S1E1 | -20.16 (sampled), -20.15 (`--full`: exact) | | -20.15 | yes |
| The Little Mermaid | -19.53 | -21.0 to -12.5 | -20.66 | yes |

Caveat [Unknown how much]: these were taken while other shards were reading from Plex. The product's cut-short guard (97%) dropped affected windows and logged it ("Plex sent only 1s of 60s"), so a few estimates rest on fewer than five windows. My attempt at a clean sequential rerun did not run: Plex had a playing session and the idle gate waited. The 7.1 meter path itself was exercised: `--full` on Andor S1E1 gave the exact -20.15 (5.1 though). No 8-channel title got a `--full` read, so the over-HTTP 7.1 side-channel path is only checked in sampled mode, and sampled error is large on high-LRA films regardless of channels (Forrest Gump 7 LU low), which is the known sampling limitation (`plex-sampling-error-2026-10.md`), not a 7.1 fault.

## The track `analyze-plex` reads versus the track a sweep reads

`lab/track_choice.rb` over the whole library:

| | Films (810) | Episodes (8,500) |
|---|---|---|
| More than one audio stream | 171 | 654 |
| Sweep's primary track is not the first audio stream | 11 | 46 |
| Plex's audioChannels differs from the first stream's | 24 | 84 |
| Plex says 7.1+ but first stream is not (or the reverse) | 1 | 0 |

`PlexAnalyzer` maps `0:a:0` and passes Plex's `audioChannels` (`lib/neutraliser/plex_analyzer.rb`, `audio_channels`, `analyze_streaming_audio`); `Source#primary_track` picks the default-disposition track. Real cases: The Little Mermaid (default is the Spanish dub, the English Atmos is a:0), Fantastic Beasts (first stream English AAC 7.1, default flag on a Turkish AC-3 5.1), Godzilla (Plex says 8, a:0 has 6). On all three the sweep and the triage disagree about which track is being judged. The Plex "default" flag is Plex's reading of the container, not verified against ffprobe dispositions here. Task `a9d2e20a`.

## Not done, and what was not verified

- **Four of twelve planned tracks were not measured end to end**: Star Trek Into Darkness (E-AC-3 7.1), Star Wars III (HE-AAC 7.1), Fantastic Beasts (AAC 7.1), and the FLAC 7.1 title (25.5 GB; the read truncated once under concurrent load). On a two-hour film each 8-channel loudnorm pass takes about 15 minutes, and each file needs several, so the runs hit the 2-hour limit twice. Three of them were covered by the slice run above (not the full measure and plan path); the FLAC 7.1 title was not read at all. Real 7.1 FLAC and 7.1 DTS-HD MA are therefore **unverified**; the library has no non-Atmos 7.1 TrueHD or 7.1 DTS-HD MA.
- Totals: 8 tracks measured end to end, 3 as slices, 1 not. Kung Fu Panda (TrueHD Atmos 7.1) and Iron Man 3 (E-AC-3 7.1) were not picked (12-file cap).
- **Codec change on lossless 7.1**: the Atmos TrueHD dry runs with `--allow-codec-change` plan the ladder, but no real TrueHD 7.1 to FLAC 8-channel encode was run.
- **Listening**: not done. HE-AAC to AAC-LC at 263k on 7.1 is unjudged.
- A first attempt read several Plex streams at once; three records truncated and were discarded and redone (`data/results.jsonl` holds only complete, non-truncated records).
- Names of library files were scrubbed from the committed data (`<scratch>/file.mkv`).

## Files

- `data/scan.jsonl`, `scan_summary.json`: every 7+ channel or object-audio-named track in the library; `data/plan.json`: the 12 picks and why.
- `data/results.jsonl`: one record per measured track; `data/slices.jsonl`: the three slices; `data/track_choice.json`: the primary-track count.
- `lab/`: `scan.rb`, `real_71.rb` (`plan`, `run HH:MM K/N`, `analyze`), `bs1770.py` (independent meter), `slices.rb`, `track_choice.rb`. They read `PLEX_TOKEN` from the repo `.env`, never print it, and need Ruby 3.2, ffmpeg 7.1 and Python with numpy and scipy.
