---
id: lossy-71-route-sceptical-review
type: note
purpose: "Sceptical review of the opt-in --lossy71 aac|opus route (138eda0) and the new too_many_channels message, run on synthetic ffmpeg files: what a stranger's library would hit, with evidence and severity."
scope:
  - "138eda0 read against the code, then run through `process` on synthetic 8ch and 7ch files: MKV, MP4, M4V, MOV, AVI; layouts 7.1, 7.1(wide), unnamed, 6.1"
  - "Sources faked as E-AC-3, AC-3, DTS-HD HRA, DTS-HD MA, TrueHD through an ffprobe shim (see Method)"
  - "Default unchanged, consent gate, bitrate caps, channel order, stamps, second run, report"
non_goals:
  - "No real E-AC-3 7.1 file (ffmpeg 7.1.1 cannot encode one) and no real player: decode of a real dependent substream and playback are untested"
  - "No tag, release or post"
tags: ["research", "7.1", "codec", "review", "release"]
related:
  - "docs/research/0007-71-eac3-sceptical-review/research.md"
  - "docs/tasks/0009-lossy-71-aac-opus-route/task.md"
  - "docs/design/adr/0001-smart-codec-selection.md"
---

# Sceptical review of the opt-in lossy 7.1 route

## Verdict

The route does what it says and the default is unchanged. **No serious bug.** One S wording bug is fixed
here (a 6.1 track was called 7.1 in the skip message). Three things are worth a follow-up, none blocks
v0.1.0, and the first should be a README known limit: **AAC for 7.1(wide) and 6.1 is written with a
Program Config Element that many hardware players ignore** (finding 1). Playback on real players is
unverified for everything here (finding 8).

Premise check. 138eda0 is on main (`git log`): `--lossy71`, the new message and the FLAC size note all
exist as the task described. The task's list of things to review was all reachable; "players that can't
play the result" can only be answered from knowledge, not tested (finding 8).

Confidence tags: **verified** = run here, output in `matrix1.txt` / `matrix2.txt`; **read** = from the
code only; **belief** = from general knowledge of players, not tested.

## Method

- Sources built with `mksrc.sh`: pink noise panned to N channels at distinct levels (so channel order
  can be checked), as FLAC in MKV/MP4, PCM in AVI/MOV. FLAC stores its channel mask, so an "unnamed" 8ch
  comes back named 7.1; the unnamed and `7.1(wide)` cases are made with the shim.
- `ffprobe-shim.rb` is a wrapper ffprobe that reports the FLAC (or PCM) stream as E-AC-3, AC-3, DTS or
  TrueHD with a chosen layout, profile and bit rate. ffmpeg then decodes the real FLAC. This drives the
  real `process` pipeline (guards, codec decision, measure, encode, verify, stamp) for a lossy source,
  but not the E-AC-3 decoder or the dialnorm read. `run.sh` runs one case, `matrix1.sh` / `matrix2.sh`
  are the two batches. Set `NEUTRALISER_CHECKOUT` to a checkout to run them.
- ffmpeg 7.1.1, Ruby via rbenv, `LANG=en_US.UTF-8`.

## Findings

### 1. AAC 7.1(wide) and 6.1 use a Program Config Element (medium, verified)

`--lossy71 aac` on a `7.1(wide)` MKV track and on a 7-channel track gives an AAC stream whose ADTS
`channel_config` is **0** (channel layout carried in a PCE), and ffprobe reports the layout as
`unknown`. Standard `7.1` gets `channel_config` 7 and reads back as `7.1` (MKV, MP4, M4V, MOV, AVI).
Evidence: `matrix1.txt` B2 and F3, ADTS header read from the outputs. Decoding in ffmpeg is clean (zero
error lines), so the file is valid; the risk is players, many of which ignore a PCE and play the wrong
channels or none (**belief**).

How likely: 7.1(wide) E-AC-3 and 6.1 AC-3/E-AC-3 are rare in a library (**belief**); the 7.1 case,
which gets a standard config, is the common one. Not an S fix: either map `7.1(wide)` to standard 7.1
with a `channelmap` (a decision about channel meaning) or restrict AAC to the standard layouts. Filed.

### 2. `--lossy71 opus` on 7.1(wide) in MKV silently becomes FLAC (low-medium, verified)

`matrix1.txt` B1: the user asked for Opus, the track is 7.1(wide), libopus cannot open it, so the answer
falls back to FLAC (3-5x the size). The log shows the FLAC size note ending `--lossy71 aac keeps it
lossy`, but nothing says Opus was refused or why. In MP4 the same case is skipped and the message
correctly offers only AAC (D2). Fix is a one-line log; filed with the others.

### 3. Message wording (S, fixed)

A 7-channel track's skip said `levels it as AAC or Opus 7.1` (F1). Now `6.1` for seven channels, with a
spec (`spec/guards_spec.rb`, "calls a seven-channel track 6.1"). The same message says `.mp4 takes no
FLAC` for a source that is FLAC in an MP4 (ffmpeg writes it, and my sources prove it); the table
deliberately leaves FLAC out of MP4, so this is a wording nit, filed with item 2.

### 4. Default unchanged, consent gate holds (verified)

- Without the flag: MKV E-AC-3 7.1 under `--allow-codec-change` goes to FLAC with the size note (A1); MP4
  is skipped `too_many_channels` (C1, C2). Same decisions as before.
- `--lossy71 aac` alone: a note that it needs `--allow-codec-change`, then the `codec_change` skip (C3).
- `--lossy71 mp3`: Thor rejects it, `Expected '--lossy71' to be one of aac, opus; got mp3` (L5).
- `--dry-run` writes nothing (L6).

### 5. Containers and layouts (verified)

| Case | Result |
|---|---|
| MKV / MP4 / M4V 7.1, aac | AAC 7.1, layout 7.1 (A2, C4, I1) |
| MKV / MP4 7.1, opus | Opus 7.1 (A3, C5) |
| unnamed 8ch, opus and aac | works, read as 7.1 (E2, E3) |
| 7.1(wide) MP4, opus | skipped, message offers aac only (D2) |
| MOV, AVI, aac | AAC 7.1 (H1, G1) |
| MOV, AVI, opus | skipped, message offers aac only (H2, G2) |
| 6.1 (7ch), aac / opus | works, 512k / 510k caps (F2, F3); aac layout unknown (finding 1) |

Channel order survives both encoders: per-channel RMS of the output matches the source plus one constant
gain (about +17.7 dB) on all channels except LFE. AAC's LFE gains +15.1 dB because the native encoder
band-limits it (expected); Opus's LFE matches. Evidence: astats per channel on the MP4/MKV outputs.

### 6. Bitrates and caps (verified)

E-AC-3 7.1 at 1.0 M, 6 M, and an unknown rate (sampled 5.4 M) all land on AAC 768k / Opus 680k (caps).
AC-3 at 448k stays 448k (no headroom on a codec change, as designed). A 7.1 E-AC-3 at 1.5 M (common
streaming rate) therefore loses half its bits; 768k AAC 7.1 is probably transparent but that is untested
by ear (**belief**). Opus is VBR: the log says `680k`, the file came out at 507 kbit/s on noise, so
the logged figure is a target not a size. Real E-AC-3 7.1 at 768k, where 7.1 is mostly 640-768k on
streaming rips, would be capped near its own rate (**read**).

### 7. Lossless sources, stamps, second run, report (verified)

- DTS-HD MA and TrueHD 7.1 in MKV stay FLAC under `--lossy71` (J2, J5); in MP4 they become AAC 768k
  (J3, J4): the only place a lossless track goes lossy, because MP4 has no FLAC in the table. It needs
  `--allow-codec-change` too. Documented in the flag help; stated here since a lossless rip is the case
  a user minds most.
- DTS-HD HRA (lossy) goes to AAC (J1).
- `--keep-original-audio` keeps the original beside the new track (L3); `--allow-dynamic` and `--ladder`
  work (L2, L4); `--fast` needs `--allow-dynamic` first, as before (L1).
- Stamp on the AAC output: `NEUTRALISER_SOURCE_CODEC=eac3`, `SOURCE_BITRATE=1024000`, mode `linear`, the
  gain and measures. Nothing names the route, but the output codec and source codec say it. A second
  run, with or without the flags, skips `Already processed` (the sidecar and stamp both hold). `report`
  counts it `normalised linear` and shows the rung `1-gain+convert`.

### 8. Not verified

- **A real E-AC-3 7.1 file.** ffmpeg 7.1.1 cannot build one; the shim drives everything except the E-AC-3
  decode of the dependent substream and the dialnorm read (AAC and Opus carry no dialnorm, so nothing is
  lost there, **read**). The probe-fixture specs and the shim cover the decision; a real file would
  cover the decode.
- **Players.** Opus in MP4 (the file is valid: `dOps` mapping family 1, decodes clean in ffmpeg) and
  8-channel AAC in MP4 are not played by many TV clients, Apple devices or Plex clients, and AAC in AVI is
  nonstandard (**belief**). The README already says "many TV clients cannot play multichannel FLAC";
  the same caution belongs on the lossy route. A real-player check needs Will.
- **No real_ffmpeg spec covers `--lossy71`**; the processor specs mock ffmpeg. The runs here are the only
  end-to-end evidence. Filed.

## Looked for and not found

A crash or hang on any case; a wrong channel count or order; a stamp or sidecar that re-queues a file;
a way for `--lossy71` to change a decision without `--allow-codec-change`; a way for it to change the
default path; a `FileResult` reason renamed; a decode error in any output.

## Filed

Steady task 86e0d44d under goal 669c751d: AAC PCE layouts, the silent Opus-to-FLAC fallback and the
FLAC-in-MP4 wording, a real_ffmpeg spec, and the real-file/real-player check (marked human).

## Full suite

`bundle exec rspec` with `LANG=en_US.UTF-8` (real_ffmpeg included), run on 138eda0: see the summary in the
job's evidence directory; the result is stated in the commit message.
