---
id: dialogue-estimate-real-files
type: note
purpose: "Does the centre-channel dialogue estimate hold on real films and episodes, and what would a dialogue -27 or -24 default ask of a real library? Measured on 79 files read over Plex, nothing written."
scope:
  - "The read-only dialogue estimate (`DialogueMeter`: centre channel of 5.1 through the loudnorm measurement), as shipped"
  - "79 files from the Plex library (40 films, 39 episodes), the primary audio track and an English text subtitle copied to scratch, library only read"
  - "Agreement with the track's own dialnorm, with a subtitle-cue reference, the loudness above dialogue, and what dialogue -27 / -24 would ask of the files"
non_goals:
  - "No default change, no code change in `lib/`, no NAS write. Will decides the default"
  - "No listening test and no hand-marked dialogue (subtitle cues stand in, see the section on how good that reference is)"
  - "Dolby's speech-gating reference code and the Silero gate (ADR 0003) were not tried"
tags: ["research", "loudness", "dialogue", "dialnorm", "default", "validation"]
related:
  - "docs/research/0002-streaming-loudness-and-dialogue/research.md"
  - "docs/research/0003-sceptical-review-dolby-dialogue-compression/research.md"
  - "docs/design/adr/0003-optional-voice-gate-for-dialogue.md"
  - "docs/research/library-baseline-2026-10.md"
---

# Dialogue estimate on real files: the gate before dialogue -27

Run overnight 2026-11-16 (02:30 to 05:40 NZ), Plex idle throughout. Vision alignment: Release neutraliser publicly (a default that is right for people's own libraries).

## Verdict

**The estimate does not pass the gate on films. Keep -20 whole-programme as the default and ship the dialogue figures as report only.** If a dialogue target is wanted later, it should be -24 not -27, and only after a better estimator (the voice gate, ADR 0003) passes the same test on films.

| Question | Answer | Confidence |
|---|---|---|
| Within 2 LU of the track's dialnorm on 90% of 5.1 files (the pass mark)? | **No: 22 of 30 (73%).** Films 4 of 11 (36%), episodes 18 of 19 (95%). Every film miss is the estimate reading **high**, by up to 8.2 LU | [Direct] `data/results.jsonl`, `data/tables.md` section 1 |
| Within 2 LU of a subtitle-cue reference? | 36 of 42 (86%); 32 of 36 (89%) where the cues line up with the audio clearly. Films 13 of 18 (72%), episodes 23 of 24 (96%) | [Supported] the reference is a stand-in, not a hand-mark (below) |
| Is dialnorm a usable ground truth? | Only where it is set: **27 of 57 readable Dolby 5.1 tracks carry -31 (unset)**, and across a 312-file screen 91% do. On clean sitcom mixes it sits a steady 0.6 to 1.3 LU below the cue reference; on action films it sits 3 to 6 LU below | [Direct] screen and measurements; why it differs on films is [Unknown] |
| Loudness above dialogue (programme minus estimate) | median **1.3 LU**, p90 3.4, max 4.9; none of 66 surround files over the 5 LU of EBU R 128 s4. The centre channel reads high, so the true figure is larger | [Direct] for the figure, [Inferred] for the caveat |
| Files needing gain beyond the 6 dB limiter | **0 at -27 and 0 at -24** (one file falls under 0.5 LU short at -24). The limiter still has to engage on **10 of 79 at -27 and 31 of 79 at -24** | [Direct] real `GainPlan` on the measured levels |
| Files already levelled to -20 that would change | Of 32 within 1 LU of -20: **all 32 at -27** (median 5.7 LU quieter), **20 of 32 at -24** (median 2.7 LU quieter) | [Direct] |

## What was measured

**Access.** The NAS is not mounted on this machine; Plex's own part URL is reachable (`/library/parts/...`, token in an `-headers` argument). Each file was read once: ffprobe over HTTP, then one `ffmpeg -c copy` of the primary audio track and one English text subtitle into scratch. Everything else ran on that local copy with the project's own `DialogueMeter`, `FFmpegWrapper.measure_loudness` (programme loudness, true peak, LRA; ebur128 added above six channels) and `DolbyStream.dialnorm`. Nothing was written to the library; scratch was deleted per file. A Plex session check ran before every file and every 15 s during a read (any transcode or playing session would have stopped the read and waited). It never fired: Plex was idle for the whole run. The 79 files total 205 GB; ffmpeg reads the container, so up to that much crossed the LAN.

**Sample.** 79 files, 102 hours of audio: 66 surround (61 `5.1(side)`, 5 `5.1`) and 13 stereo; 40 films and 39 episodes. Three stages, which matter when reading the percentages:

1. **42 files drawn at random within strata** (seed 20261116): Dolby 5.1 films 14, other 5.1 films 4, stereo films 4, and the same three for episodes 12 / 4 / 4. Dolby is over-sampled because only AC-3 / E-AC-3 can carry a dialnorm. This stage alone is closest to "the library".
2. **22 chosen on purpose** from a cheap screen of 312 Dolby 5.1 files (container header and the first 8 frames only): the first 14 found with a real dialnorm, 3 films with songs, 5 with heavy score, each needing an English text subtitle.
3. **15 more with a real dialnorm** (the rest of what the screen found; mostly Simpsons, Futurama, Office episodes, because those are where dialnorm is set).

So the pooled agreement figures are not a library statistic: stage 3 adds easy sitcom mixes, stage 2 adds hard films. The first sample alone gives the same counts to within a few points for section 3 (`data/tables-first-sample-only.md`: dialogue -27 moves 37 of 42, -24 moves 32 of 42; 16 of 22 already-levelled files change at -24, all 22 at -27).

**A discarded first attempt.** The first sharded run read files with several Plex connections at once; ffmpeg reported success on truncated reads, so those records measured seconds of a film. They were found because fetch times were under 3 s and were all deleted. The scripts now take one Plex read at a time and refuse a copy shorter than 97% of the title's runtime. Nothing from that attempt is in these numbers. Job 630928f1's scripts and JSONL live in another job's workspace, which this job may not read, so the scripts here are new (`lab/`).

## 1. Estimate against the track's dialnorm

Dolby 5.1 tracks read: 57 (the other of 58 could not be read). Dialnorm values: -31 on 27, a real value on 30, 1 unreadable. Across the screen of 312, 283 (91%) are -31, and a real value turns up in 19 of 171 episodes and 10 of 141 films. Library-wide, dialnorm gives ground truth on about one Dolby file in eleven.

On the 30 with a real value (all 5.1):

| | n | within 2 LU | within 3 LU | est - dialnorm, median | worst |
|---|---|---|---|---|---|
| All | 30 | 22 (73%) | 25 | +1.2 | +8.2 (Mission: Impossible II) |
| Films | 11 | 4 (36%) | | +2.9 | +8.2 |
| Episodes | 19 | 18 (95%) | | +0.9 | +5.6 (Stranger Things S5E8) |

**Fails the 90% mark.** The films that miss: Mission: Impossible II +8.2, Stranger Things S5E8 +5.6 (an episode, E-AC-3), Watchmen +5.5, Jurassic Park +4.6, Alien +4.0, Hateful Eight +3.0, SpongeBob Movie +2.9, The Departed +2.7. All are over-reads, which is the failure `DialogueMeter` documents: effects and score share the centre channel. The one under-read is Doctor Who -1.5.

**Is dialnorm plausible ground truth? Partly.** On the sitcoms the estimate, the cue reference and dialnorm line up (estimate typically 0.4 to 1.5 LU above dialnorm; dialnorm typically 0.6 to 1.3 LU under the cue reference). So dialnorm is a dialogue-level statement there, set about 1 LU conservative. On action films the estimate and the cue reference agree with each other and both sit well above dialnorm (Mission: Impossible II: dialnorm -27, cue reference -21.0, estimate -18.8). Two readings fit and these data cannot separate them: the encoder's operator set a quieter dialnorm than the speech actually plays at, or the loudness during speech includes effects that a speech-only measure would leave out. [Unknown] which; listening, or Dolby's reference measurement, would settle it.

## 2. Subtitle-cue reference, and how good it is

Dialogue was not hand-marked (nothing here can listen). As instructed, **subtitle cue timings stand in for a hand-marked dialogue track**: 48 of 79 files had an English text subtitle; 42 had at least 30 speech cues after dropping sound descriptions (`[door slams]`), anything with a music note, and cues under 0.3 s. For each, the local copy is decoded once to 400 ms loudness blocks (the same BS.1770 gating as the estimate) for the full mix and for the centre channel alone. The reference is the **integrated loudness of the full mix over blocks that fall wholly inside a speech cue**, after shifting the cues by whatever offset (±8 s, 0.2 s steps) best separates speech blocks from the rest. That is the same kind of figure a dialogue-gated measurement gives: the level of the mix while someone speaks.

**How good it is** [Supported]:

- Clock agreement is good: the best shift is 0.2 s or less on 37 of 42 files (largest 0.8 s). Whole-file checks on the two files looked at (Stranger Things S5E8, The Office S5E2) matched the meter: the decoded full mix integrates within 0.05 LU of loudnorm's reading, the centre within 0.05 LU of the estimate.
- It separates speech from the rest on most files: centre-channel loudness inside cues is a median 5.8 dB above outside them. **It fails on six files, under 3 dB**: The Nightmare Before Christmas (-0.1), The Rocker (0.3), South Park: Bigger, Longer & Uncut (1.5), Kill Bill (1.7), Watchmen (2.5), Treehouse of Horror XII (2.8). Four are songs or continuous loud music, the case the task wanted tested. There the cues cannot tell speech from music, so **the reference cannot judge the estimate on songs**. The songs question is not answered: on the one clear musical (The Cat Returns, 10.6 dB separation) the estimate read 2.1 LU **low**, not high, which is the opposite of the feared failure but a single file.
- It agrees with dialnorm where both exist: on the 22 well-aligned files that have a real dialnorm, dialnorm minus reference has a median of -1.2 LU (p10 -3.4, p90 -0.7, one outlier at +1.0, Mission: Impossible II at -6.0 and Stranger Things at -5.6).
- Limits: it only covers subtitled speech (19% to 70% of runtime, median 49%); an unmarked lyric or a foreign line left untranslated counts wrongly; speech with music under it is, by design, measured with the music in it; no person checked a single file by ear. Treat it as good to about 1 LU on dialogue-heavy television and as weak on musicals.

**Agreement with the reference** (estimate minus full-mix level in speech):

| | n | within 2 LU | median | over-reads > 2 LU | under-reads > 2 LU |
|---|---|---|---|---|---|
| All with cues | 42 | 36 (86%) | 0.0 | 5 | 1 |
| Cues aligned (>= 3 dB) | 36 | 32 (89%) | -0.2 | | |
| Films | 18 | 13 (72%) | 0.0 | 4 | 1 |
| Episodes | 24 | 23 (96%) | 0.0 | 1 | 0 |

Over-reads: Lost S1E3 +4.6, Watchmen +4.2 (cues weak), Kill Bill +2.6 (cues weak), Mission: Impossible II +2.2, Jurassic Park +2.0. Close to the mark overall, but films, where a dialogue target is meant to help, are well short, and the misses are again one-sided.

## 3. What a dialogue default would ask of this library

The library is already levelled: programme loudness has a **median of -20.5 LUFS, 32 of 79 files within 1 LU of -20 and 46 within 2** (production's shell driver did that; most files carry no neutraliser stamp, 1 of 79 does). The counts below run the real `Ladder.aim` and `GainPlan` (limiter reach 6 dB, true-peak ceiling -1.5) over the measured programme loudness, true peak and estimate. A file with no estimate (13 stereo) is aimed 3 LU above the dialogue target, `Ladder::NO_DIALOGUE_OFFSET_LU`: -24 programme for -27, -21 for -24. The task's "-24 whole programme under 15% dialogue" fallback is the same number for the -27 case; no voice gate exists to measure the share of dialogue, so that part is untested.

**Loudness above dialogue**, 66 surround files: median 1.3, p10 0.2, p90 3.4, max 4.9.

| LU above dialogue | files |
|---|---|
| below 0 (centre louder than the mix) | 2 |
| 0 to 2 | 44 |
| 2 to 4 | 18 |
| 4 to 6 | 2 |
| 6 and over | 0 |

None exceeds the 5 LU reference of EBU R 128 s4. But the centre channel carries effects and score, so this figure is a floor; the over-reads in section 1 say the true gap is larger on the films that matter.

**Counts** (79 files; a file "moves" if the aimed level is more than the 1 LU skip tolerance away):

| | Dialogue -27 | Dialogue -24 |
|---|---|---|
| Files that would move | 72 (71 quieter, 1 louder) | 53 (42 quieter, 11 louder) |
| Median move | -4.2 LU | -1.2 LU |
| Needing more than a 6 dB cut | 13 | 1 |
| Needing gain beyond the 6 dB limiter | **0** | **0** (1 file under 0.5 LU short) |
| Needing the peak limiter at all | 10 | 31 (27 of the 66 with an estimate) |
| Files within 1 LU of -20 that would change | **32 of 32** (median -5.7 LU) | **20 of 32** (median -2.7 LU) |

Medians for the last row are over the 24 levelled files that have an estimate; the other 8 levelled files are stereo.

So this library never asks for more than the limiter can give: the research's worry that high-range films would hit the 6 dB wall does not show up, because the files are already loud and the move is nearly always a cut. The cost is elsewhere. Dialogue -27 re-encodes 91% of the files, including every one already at -20, for a median cut of 4 LU; dialogue -24 re-encodes 67% and two files in five would then need the limiter. Each is another lossy generation (research 0004: 0.04 to 0.18 ViSQOL a pass).

Also in this library the estimate sits a median 1.3 LU under the programme, so a dialogue anchor behaves like a programme anchor moved by about 1.3 LU (-27 dialogue is about -25.7 programme). It adds little over the existing target on this material, and where it differs most (films with heavy score) is where it reads wrong.

## Not done, and what was not verified

- **Hand-marked dialogue and listening:** not possible unattended; subtitle cues are the stand-in (section 2). [Unknown] whether the estimate or dialnorm is closer to what a viewer hears on action films.
- **Songs:** the reference fails on four of the musical or music-heavy films, so the songs question stays open. Tried: three films from the Plex genres Musical / Music with English text subtitles, plus The Cat Returns and The Nightmare Before Christmas.
- **Dolby's speech-gating reference code:** not tried (a download behind a form; terms unread; this job had no browser or credentials for it).
- **Silero / voice gate:** not built; fallback "under 15% dialogue" cannot be evaluated.
- **7.1 and Atmos:** none came up in the sample (every track is 5.1 or stereo), so the side-channel path was not exercised.
- **Library coverage:** 79 of roughly 9,300 titles, stratified, not a uniform draw. The counts in section 3 are for this sample.
- **Stereo (13 of 79, 16%):** no estimate by design; they are aimed 3 LU above the dialogue target on programme loudness.

## Recommendation for Will

**Keep -20 whole-programme as the default and ship the dialogue figures as report only.** The estimate misses the 90%-within-2-LU mark on the track's own dialnorm (73%) and on a subtitle-cue reference (86%, 89% where the cues are clean), and on films, the case a dialogue target exists for, it is at 36% and 72%, always reading high, so a dialogue-anchored gain would land true dialogue below target by the over-read on exactly the action films (2 to 5 LU against the cue reference, up to 8 LU against dialnorm). On this already-levelled library a dialogue anchor is also close to a programme anchor moved by 1.3 LU, yet flipping to -27 would re-encode 72 of 79 files (every one already at -20, median 5.7 LU quieter), and -24 would re-encode 53 and put the limiter on 31. Nothing hit the 6 dB wall, so the limiter itself is not the argument; the cost is the churn and the quieter library. If you still want to move toward streaming levels, pick -24 over -27 (it leaves 12 of the 32 levelled files alone), and gate it behind the voice gate (ADR 0003) passing this same test on the films, with dialnorm used as a check only where it is set (about one Dolby file in eleven).

## Files

- `data/plan.json`, `plan2.json`, `plan3.json`: the three sample stages; `data/screen.jsonl`: the 312-file dialnorm and subtitle screen.
- `data/results.jsonl`: one record per measured file (programme loudness, true peak, LRA, estimate, dialnorm, cue reference, sync).
- `data/tables.md`: every table above, all 79 files; `data/tables-first-sample-only.md`: the 42 stage-1 files alone.
- `lab/` (one-off evidence scripts, excluded from rubocop like research 0004's): `plex_probe.rb`, `dialogue_real_files.rb` (`plan`, then `run HH:MM K/N`, idle-gated; `PLAN_FILE=` picks plan2 or plan3), `dialogue_screen.rb` (`screen`, `pick`, `pick3`), `dialogue_real_files_report.rb` (`ONLY_PLAN=1` for stage 1). They read `PLEX_TOKEN` from the repo `.env` and need Ruby 3.2 and ffmpeg 7.1.
