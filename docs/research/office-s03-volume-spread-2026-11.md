---
type: note
status: active
owner: will
contributors: []
updated: 2026-11-08
review_cycle: 90d
agent_write: false
links: ["docs/research/prod-parity-audit-2026-10.md"]
summary: "Why four The Office (US) S03 episodes play 3-4 LU quieter than the rest: unprocessed DTS-HD releases that constant gain cannot lift; measured on the real library, with the fix tested on NAS copies (all four land within 0.2 LU of -20) and the command to run"
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
2. E01 and E04 were levelled in that run as the Netflix WEB-DL files, then Sonarr swapped them for the DTS-HD releases a few hours later (the new files are dated after the run's processing time). E17 was swapped before the run, which is why it `failed` with "No such file". Nothing has run on the TV library since: the `/volume1` TV sweep is gated off (`SWEEP_TV`, see "Fix, tested on copies"), and the driver itself has been stopped since 2026-11-01.
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

- **No file carries a `NEUTRALISER_*` stamp.** 0 of 58 (the format tag set has no `NEUTRALISER_*` key; the stream tags are only mkvmerge/Lavc defaults). So Mode, Recipe and LeftRecord reasons do not exist for this library: the August run predates stamps and the TV sweep has not reached this show since the driver moved to this CLI. (An earlier version of this note said production does not run the CLI; it does, as a docker image, since 2026-10-28.)
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

## Fix, tested on copies

Question kind: a recommendation to act on, checked by running it. Premise check first: two things in the earlier version of this note were wrong.

- **The CLI is on the NAS.** The driver has run it as a docker image since 2026-10-28 (confidence: **verified**, `docker images` on the NAS and the driver script). The check-prod skill's "production does not run this CLI yet" was stale (fixed in this commit).
- **The image is older than main.** It is v0.1.0, built 2026-10-23 from `2cfd854`, 36 commits behind: no recipes, no `--redo-recipe`, no Dolby fix. I tested **that image**, since it is what runs. Its `process` has `--allow-codec-change`, `--allow-dynamic` and `--limit-db`.

### The command for Will

One show, four files, not the sweep. It is the driver's own `docker run` (`run_one()` in media-server's `neutralise-driver.sh`: `--replace --tolerance 2 --min-gain 1 --no-fast-verify --no-cache`, the driver's lock file and disk floors) plus `--allow-codec-change --allow-dynamic`. The script (`docs/research/office-s03-fix.sh`) copies each original to a backup folder first, then runs the image on that one file. It takes the stage dir and media root from the environment, so no NAS path is in the repo. Paths come from `local.env` (see the check-prod skill); run from the neutraliser checkout:

```
set -a; . .claude/skills/check-prod/local.env; set +a
ssh "$NAS_SSH" "cat > $NAS_STAGE_DIR/office-s03-fix.sh" < docs/research/office-s03-fix.sh
# optional first: add --dry-run after the backup dir (measures only, about 30 min, copies nothing)
ssh "$NAS_SSH" "cd $NAS_STAGE_DIR && STAGE=$NAS_STAGE_DIR MEDIA_ROOT=$NAS_MEDIA_ROOT nohup setsid sh office-s03-fix.sh '$NAS_MEDIA_ROOT/tv/The Office (US)' $NAS_STAGE_DIR/office-s03-backup </dev/null >office-s03-fix.log 2>&1 & sleep 2; cat office-s03-fix.log"
```

It runs detached on the NAS (an ssh drop does not kill it); follow it with `ssh "$NAS_SSH" "tail -f $NAS_STAGE_DIR/office-s03-fix.log"`. It stops at the first failure (`set -e`). Do not `docker pull` the image first (see Risks).

Before running: `driver.status` should not say `running` (it has said `stopped (signal)` since 2026-11-01). The run uses the driver's lock file, so a driver that starts meanwhile yields with exit 3 instead of colliding.

Verified on copies: the script ran as written apart from two constants (the stage dir and media root became environment variables after the test; an argument-construction check with a stubbed `sudo` printed the identical `docker run` line).

### Before and after (copies on the NAS stage area, full-length)

Method: `ebur128=peak=true` over the whole default audio track, using the image's own ffmpeg (the NAS host ffmpeg has no DTS decoder). "Centre" is the same measure on the centre channel only (`pan=mono|c0=c2`), a stand-in for dialogue, not a speech-gated figure. E15 is the good episode, left untouched as the reference.

| Ep | Before: LUFS / LRA / TP | After: LUFS / LRA / TP | Centre LUFS before → after |
|---|---|---|---|
| E01 | -23.8 / 15.5 / -0.2 | **-19.9** / 13.3 / -1.5 | -23.8 → -19.9 |
| E04 | -24.4 / 14.3 / -1.5 | **-20.1** / 11.0 / -1.3 | -24.6 → -20.2 |
| E06 | -22.9 / 13.1 / -1.1 | **-20.0** / 11.2 / -1.4 | -23.3 → -20.3 |
| E17 | -23.4 / 12.0 / -0.9 | **-20.0** / 10.2 / -1.5 | -23.4 → -20.0 |
| E15 (good, untouched) | -19.9 / 10.9 / -1.4 | same | -20.1 |

Against the targets (confidence: **verified**, raw lines in the evidence):

- **Within 1 LU of the good episodes:** yes. All four land -19.9 to -20.1, within 0.2 LU of E15 and of the other 19. The "before" numbers reproduce the earlier measurements to 0.1.
- **True peak <= -1.5 dBTP:** E01 and E17 meet it; **E04 (-1.3) and E06 (-1.4) miss by 0.1 to 0.2 dB.** That is the same peak range as the already-processed episodes (-0.9 to -1.5, and E15 sits at -1.4), so it is not worse than the rest of the season, and nothing is above -1.3.
- **No dialogue loss:** the centre channel rose by +3.9, +4.4, +3.0, +3.4 LU against +3.9, +4.3, +2.9, +3.4 for the programme, so dialogue stayed in step with the whole mix, and ends -19.9 to -20.3 against E15's -20.1. Loudnorm did narrow the range (LRA 1.8 to 3.3 LU lower), as the earlier trial said.
- **Short because of the peak limit:** none. Dynamic mode reached -20 on all four, which constant gain could not (it skipped all four as `peak_limited`). `--limit-db` was not re-run on the NAS; the earlier local trial stands (`--limit-db 6` reaches -20.1 to -20.3 with unchanged LRA but a true peak of -0.1 dBTP on E17, and -0.4 on E01).
- **Everything else in the file kept:** the video, the second (DTS core) audio track and the PGS subtitle are unchanged in the output (checked with `ffprobe` on E01 and E06). The new primary track is FLAC 5.1, default, tagged `NEUTRALISER_MODE=dynamic`. The show-level `.neutraliser` sidecar was not touched by this build.
- **E06's stale sidecar entry did not block it** in this image: it was processed like the others, so `--redo-recipe` is not needed (the flag does not exist in this build). Why it was not skipped was not investigated.

### Files touched, time, undo

- **Touched (real run):** four files in `Season 3` are replaced in place: E01, E04, E06, E17 (`The.Office.US.S03E0n...HEVC.x265-MeGusta.mkv`). Each shrinks by about 50 to 70 MB (DTS-HD 3 Mbps to FLAC). Nothing else in the library: not the other 19 episodes, not the sidecar or run manifest (their size and mtime were identical before and after the copy test, and the originals' size and mtime were identical after).
- **Also written:** four backups, about 4.1 GB, in the backup folder on the stage volume (720 GB free there); a log in the stage dir. The tool's own temp file sits beside each episode during its encode and is renamed over it.
- **Time:** the test took 63 minutes for the four (about 7.5 minutes measuring plus about 8 minutes encoding per file, 15 to 16 minutes each; the NAS has 4 cores). Plan on about 65 to 75 minutes on the library volume, longer if Sonarr or Plex are busy. A `--dry-run` takes about 30 minutes.
- **Undo:** `--replace` keeps no original, which is why the script backs the four files up first (`cp -p`, mtimes kept). Restore one with `cp -p <backup>/<file> "<show>/Season 3/"`, then delete the backups when happy. Sonarr and Plex need no action beyond their normal rescan. `--keep-original-audio` would keep the DTS-HD inside the file as an extra track (about 3 Mbps each) but was not tested, so the script uses the backup copy.
- The copies and the test folder were deleted afterwards (nothing left in the stage dir).

### Risks

- **Do not update the image before running.** The recipe above was proven on the Oct 23 image. A newer build (main) behaves differently here: the earlier note's read of main is that E06's stale sidecar entry would make a plain run skip it as done, needing `--redo-recipe unversioned` (never against the folder), and main stamps recipes and fixes Dolby dialnorm. The driver itself never pulls, so only a manual `docker pull` would change it. Re-test if the image is replaced.
- **Product decision:** the primary track becomes FLAC 5.1 and a DTS-HD MA bitstream to a receiver is gone from the default track. The extra DTS core track stays as track 2.
- **Dynamic mode compresses** the four (LRA lower by 1.8 to 3.3 LU), the same as the other 19 episodes got in August.
- **Peaks:** E04 and E06 end at -1.3 and -1.4 dBTP, 0.1 to 0.2 dB over the -1.5 target, in line with the rest of the season.
- **The TV sweep:** do not un-pause it for this. `SWEEP_TV` gates the whole `/volume1` TV backlog (7,000+ episodes), so it cannot be limited to one show, and it would not fix these anyway: the sweep passes neither `--allow-codec-change` nor `--allow-dynamic`, so it would leave the four DTS files alone as it would any DTS file. To make *future* Office downloads get this treatment, a line in the driver's `neutralise-overrides.txt` (`<tv root>/The Office (US)/|--allow-codec-change --allow-dynamic`) would do it through the import queue. That is a media-server config change, which this job did not make; it is Will's call, and it would also make every later Office episode dynamic rather than constant gain.
- **Not tested:** S04E13 (AAC 5.1, -22.8) needs the driver's plain flags on that one file (no codec or dynamic flag, AAC re-encodes); run it the same way with the script's `docker run` minus those two flags. Not tried here.

### Side finding: the driver is stopped

`driver.status` has said `stopped (signal)` since 2026-11-01 02:42 (mid-sweep, Star Trek TNG), and the Mac-side kicker's last log line is 2026-11-01 15:14 with no launchd entry for it now. The import queue holds six files queued on 2026-11-06 that have not drained (movies and a TV show, none of them The Office). Not touched.

Evidence (outside git): before/after and centre-channel measurements, the test run's log (`run.log`, with per-file timings and the CLI's own output), the `ffprobe` of the output tracks and the dry-run log.

## Code bugs

None found, so nothing filed.

- The guard and the peak-capped skip behave as designed (`Guards#codec_change`, `GainPlan`).
- The stale "processed" sidecar entry on E06 came from the August run, before left-alone records existed (`LeftRecord` entries have no top-level `profile`, so they never count as done; commit dbfb20e added them). The current code does not write such an entry.

## What was not done

- Dialogue-level (centre channel) estimates for S03 were not obtained: `report --measure` over local copies didn't finish inside the job's time limit. The integrated-loudness spread already accounts for what Will heard.
- Stereo downmix loudness was not measured; only the primary track as stored.
- Seasons other than S02 to S04 were not measured.
- Nothing was run against the library other than `ffprobe`, a read of the audio stream and `cat`/`grep` of the sidecars and manifests.
