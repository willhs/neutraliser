---
type: note
status: active
owner: will
contributors: []
updated: 2026-11-08
review_cycle: 90d
agent_write: false
links: ["docs/research/prod-parity-audit-2026-10.md"]
summary: "Why four The Office (US) S03 episodes play 3-4 LU quieter than the rest: unprocessed DTS-HD releases that constant gain cannot lift; measured on the real library, with the fix and its expected result"
tags: [research, production, loudness, dts]
---

# The Office (US) S03: why some episodes are quieter

Will heard "noticeably different volume between some episodes in season 3". This note measures the real TV library, read-only, and names the cause.

## Answer

**Four S03 episodes (E01, E04, E06, E17) are 3 to 4.4 LU quieter than the other 19.** The 19 sit within 0.2 LU of each other (-20.1 to -19.9 LUFS). The four are all DTS-HD MA 5.1 releases that were never levelled:

| | Integrated loudness |
|---|---|
| S03 min | -24.4 LUFS (E04) |
| S03 max | -19.9 LUFS (E15) |
| Spread | 4.5 LU; 0.2 LU without the four DTS episodes |

Cause (confidence: **verified**, measurements below; the reason the old run skipped them is **inferred** from the run manifest and today's guards):

1. DTS can't be re-encoded to itself, so the codec-change guard leaves it alone (`Guards#codec_change`, `lib/neutraliser/guards.rb`). The August run reached them and did nothing (E06 `skipped`, E17 `failed`: file renamed under it).
2. E01 and E04 were levelled in that run as the Netflix WEB-DL files, then Sonarr swapped them for the DTS-HD releases a few hours later (the new files are dated after the run's processing time). E17 was swapped before the run, which is why it `failed` with "No such file". Nothing has run on the TV library since: the TV sweep is paused until the driver runs this CLI.
3. Even with `--allow-codec-change`, plain constant gain still skips all four, because these files are quiet **and** peaky (see "Why the obvious fix does nothing").

It is **not** a code bug, stale dialnorm or DRC, a stereo/5.1 mix, or a dynamic-vs-linear mix. Each suspect was checked (below).

## Method

All read-only. The library was never written to.

- Metadata: `ffprobe` over SSH on every `.mkv` in S02, S03, S04 (58 files): codec, channels, dispositions, container and stream tags, and the `.neutraliser` sidecar, `.neutraliser-run-manifest.jsonl` and `manifest.jsonl` in the show and staging folders.
- Loudness: the primary audio track (`a:0`, which is also the default track wherever a file marks one) was streamed with `-c copy` to a local scratch copy, then `ffmpeg -af ebur128=peak=true` ran over the whole track. Dolby tracks were decoded twice: `-drc_scale 0` (what the CLI measures) and the ffmpeg default (stream DRC applied).
- Dialnorm: read with `Neutraliser::DolbyStream.dialnorm` from the first frames of the raw track.
- Fix trials ran on local copies of the four tracks, never on the library.

Evidence (outside git): measurement script, raw JSON lines (`measure.jsonl`), ffprobe dumps, trial logs.

## State on the NAS

- **No file carries a `NEUTRALISER_*` stamp.** 0 of 58 (the format tag set has no `NEUTRALISER_*` key; the stream tags are only mkvmerge/Lavc defaults). So Mode, Recipe and LeftRecord reasons do not exist for this library: production does not run this CLI yet (see the check-prod skill), and the August run predates stamps.
- State comes from the August run instead. Its manifest says every processed S03 episode was `done` with `normalization_type: Dynamic` (two-pass loudnorm, may compress), i.e. the recipe is effectively **unversioned**. The sidecar `.neutraliser` and a `*.loudnorm_livingroom.json` cache sit beside each processed file.
- Dolby tracks: dialnorm is **-31 in every one** (S02, S03, S04). Unversioned encodes wrote -31 (the thing recipe 2 fixed for new runs), but since it is -31 everywhere a decoder that honours dialnorm applies 0 dB to all of them, so it cannot create a spread between these files. The DRC decode matches the DRC-off decode to 0.1 LU on every Dolby file (`drc1` = `drc0` in the data), so no DRC is baked in either.
- The TV sweep is paused (check-prod; `driver.status` last said `stopped (signal)` on 2026-11-01), so nothing has levelled new or swapped files since the August run.

## S03 by loudness

Sorted quietest first. "Run" is the August run manifest; "none" means no entry names the file that is on disk now. Release `NF` is the Netflix WEB-DL, `BD` the HEVC release from a BluRay.

| Ep | Integrated LUFS | LRA | True peak dBTP | Track | Release | Run (Aug) | Cause |
|---|---|---|---|---|---|---|---|
| E04 | **-24.4** | 14.3 | -1.5 | DTS-HD MA 5.1 | BD | none (NF file was `done`, then replaced) | DTS, unprocessed |
| E01 | **-23.8** | 15.5 | -0.2 | DTS-HD MA 5.1 | BD | none (NF file was `done`, then replaced) | DTS, unprocessed |
| E17 | **-23.4** | 12.0 | -0.9 | DTS-HD MA 5.1 | BD | `failed` (NF name gone) | DTS, unprocessed |
| E06 | **-22.9** | 13.1 | -1.1 | DTS-HD MA 5.1 | BD | `skipped`, yet sidecar says processed | DTS, unprocessed |
| E15 | -19.9 | 10.9 | -1.4 | FLAC 5.1 | BD | done, Dynamic | processed |
| E05, E07, E08, E09, E10, E02, E19, E21, E22, E23, E14 | -20.0 | 8.5 to 12.6 | -0.9 to -1.5 | FLAC / E-AC-3 5.1 / AAC 2.0 | BD / NF | done, Dynamic | processed |
| E03, E11, E12, E13, E16, E18, E20 | -20.1 | 8.4 to 14.8 | -1.1 to -1.5 | FLAC / E-AC-3 5.1 | BD / NF | done, Dynamic | processed |

Full per-episode rows (codec, channels, dialnorm, both decodes) are in the evidence `measure.jsonl`. Other facts per suspect:

| Suspect | Result |
|---|---|
| Never processed | **Yes, E01/E04/E06/E17.** The DTS files above. |
| Peak-limited landing short | Not the August output (all within 0.1 LU of -20), but it is why the DTS files stay quiet if run again: see below. |
| Old-recipe Dolby, DRC baked in or dialnorm reset | **No effect on spread.** All 12 Dolby S03 tracks have dialnorm -31 and the DRC/no-DRC decodes agree. |
| Dynamic vs linear | The 19 processed episodes are all Dynamic; same mode, so no spread. They do differ in LRA (8.4 to 14.8): E-AC-3 episodes sit at LRA 8.4 to 11.4, FLAC ones up to 14.8. At equal integrated loudness the wider-range ones have louder peaks and quieter dialogue, which can read as a volume difference; this is minor next to 3 to 4 LU. |
| Stereo vs 5.1 | E07 is AAC 2.0 and measures -20.0 like the rest. Not a cause. |
| Different releases | Yes, but only through the DTS codec: the NF files (E-AC-3) and the BD FLAC files both land on -20. |

## Do S02 and S04 show it?

S03 is not alone, but the others are milder.

| Season | Files | Min / max LUFS | Outliers |
|---|---|---|---|
| S02 | 22 | -20.3 / -19.0 | E11 is -19.0 with true peak +2.3 dBTP and LRA 15.1; E02 is -20.3 with +0.6 dBTP. Both within about 1 LU of target. No DTS. |
| S03 | 23 | -24.4 / -19.9 | The four DTS episodes. |
| S04 | 13 | -22.8 / -20.0 | E13 is -22.8: an AAC 5.1 file (a different, later release, dated 2026-10-28) that no run has seen. The rest are -20.0 to -20.1. |

So the whole library has the same two gaps: files that arrived after the August run (S04E13) and DTS releases (the 4 in S03; S04's FLAC/E-AC-3/AC-3 files are fine). Other seasons were not measured; DTS in other seasons would show the same.

## Why the obvious fix does nothing

`process --allow-codec-change` alone leaves all four alone as `peak_limited`. Trial on local copies of the four tracks, current CLI, `--profile livingroom` (default):

```
S03E01  Peak-limited: max useful gain -1.31 dB is under 1.0 dB towards target, skipping re-encode
S03E04  Peak-limited: max useful gain  0.05 dB ...
S03E06  Peak-limited: max useful gain -0.45 dB ...
S03E17  Peak-limited: max useful gain -0.58 dB ...
Run summary: queued=4, done=0, skipped=4
```

They need +2.9 to +4.4 dB to reach -20 but their peaks leave 0 dB or less of headroom under -1.5 dBTP. A limiter or loudnorm's dynamic mode is required.

Trials with the same four copies (outputs are FLAC 5.1; measured again with ebur128):

| Option | E01 | E04 | E06 | E17 | Peaks | LRA change |
|---|---|---|---|---|---|---|
| (none) | skipped | skipped | skipped | skipped | n/a | n/a |
| `--limit-db 6` (Limited) | -20.2 | -20.3 | -20.1 | -20.1 | TP -0.4, -1.3, -1.1, **-0.1** | none to 0.2 LU |
| `--allow-dynamic` (Dynamic) | -19.9 | -20.1 | -20.0 | -20.0 | TP -1.5, -1.3, -1.4, -1.5 | 0.9 to 2.2 LU narrower |

## Proposed fix (not run)

Re-level the four episodes only. Three details are easy to get wrong:

- The CLI is not deployed on the NAS yet, so this runs wherever the CLI runs with the TV library mounted. Do it per file, not on the whole season: a season-wide run would also redo the 19 episodes that are already at -20.
- E06 has an old sidecar entry that says "processed" and matches the file's size and mtime exactly, so a plain run skips it as done. `--redo-recipe unversioned` makes the sidecar entry (which predates recipes) and any unstamped record count as not done (`spec/skip_decider_spec.rb`, "does unversioned files over when asked"). It touches no other file here since only the files named on the command line are visited.
- The Dolby/NF files in the same folder have no `NEUTRALISER_*` stamp either, so never run `--redo-recipe unversioned` against the folder.

Recommended: dynamic, because it matches how the other 19 were processed in August, keeps every true peak at or under -1.3 dBTP, and lands all four within 0.1 LU of -20:

```
neutraliser process "<tv root>/The Office (US)/Season 3/<file>" \
  --profile livingroom --allow-codec-change --allow-dynamic --redo-recipe unversioned --replace
```

once for each of `S03E01`, `S03E04`, `S03E06`, `S03E17` (the `.mkv` named `The.Office.US.S03E0n...HEVC.x265-MeGusta.mkv`). Add `--dry-run` first to see it queue four.

Expected result: each file's primary audio track becomes FLAC 5.1 (the DTS-HD MA track is the primary and default; per the multi-track rule in AGENTS.md the second DTS core track is copied unchanged, not exercised in the trial, which had only the primary track), stamped `dynamic`, recipe 2, integrated loudness -20.0 +/- 0.1 LUFS, LRA about 10 to 13. S03 then spans -20.1 to -19.9 LUFS.

Alternative: `--limit-db 6` instead of `--allow-dynamic` keeps the dynamics (LRA unchanged) and stamps `limited`, at the cost of true peaks up to -0.1 dBTP (E17), over the -1.5 target, so it can clip on some decoders. Use it only if the dynamic range matters more than the headroom.

`--allow-codec-change` is the product decision for Will: DTS-HD MA lossless becomes FLAC (lossless to lossless, 5.1 kept), but anything that bitstreams DTS to a receiver will no longer see DTS on the primary track. The extra DTS core track stays as the second track.

Separately, S04E13 (AAC 5.1, -22.8) needs a plain `process` on that file: AAC is re-encodable, so no codec flag. It is a new file the paused sweep has not seen. It is a normal run, no redo flag.

## Code bugs

None found, so nothing filed.

- The guard and the peak-capped skip behave as designed (`Guards#codec_change`, `GainPlan`).
- The stale "processed" sidecar entry on E06 came from the August run, before left-alone records existed (`LeftRecord` entries have no top-level `profile`, so they never count as done; commit dbfb20e added them). The current code does not write such an entry.

## What was not done

- Dialogue-level (centre channel) estimates for S03 were not obtained: `report --measure` over local copies didn't finish inside the job's time limit. The integrated-loudness spread already accounts for what Will heard.
- Stereo downmix loudness was not measured; only the primary track as stored.
- Seasons other than S02 to S04 were not measured.
- Nothing was run against the library other than `ffprobe`, a read of the audio stream and `cat`/`grep` of the sidecars and manifests.
