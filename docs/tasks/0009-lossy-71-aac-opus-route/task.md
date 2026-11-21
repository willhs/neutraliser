---
id: task-0009
type: spec
purpose: "Opt-in AAC/Opus route for 7.1 tracks ffmpeg cannot write in their own codec, a too_many_channels message that names the options, and FLAC 7.1's size cost stated."
tags: ["codec", "7.1", "eac3", "cli"]
related: ["../../research/0007-71-eac3-sceptical-review/research.md", "../../design/adr/0001-smart-codec-selection.md"]
created: 2026-11-21
updated: 2026-11-21
---

# Lossy 7.1 (E-AC-3/AC-3): opt-in AAC/Opus route, honest too_many_channels message, FLAC size cost

Vision alignment: Have an online presence (goal: Release neutraliser publicly)

## Goal

A user with E-AC-3 7.1 streaming rips can level them as AAC or Opus 7.1 with an explicit flag, in
MP4 as well as MKV; without the flag nothing changes, but the skip message tells them what would work
and the README/log say what FLAC 7.1 costs in size.

## Context

Research 0007 finding 3. ffmpeg's AC-3 and E-AC-3 encoders stop at 5.1, so `CodecChoice.resolve_encoder`
gives an over-5.1 lossy track FLAC where the container takes it (MKV, only under
`--allow-codec-change`) and nothing elsewhere (MP4, M4V, MOV, AVI: skipped `too_many_channels`). FLAC 7.1
is 3-5x the size of the E-AC-3 and many TV clients cannot play multichannel FLAC. The guard says "no
encoder there holds more than 5.1", which is false: ffmpeg's native AAC and libopus hold eight channels
in MP4.

Director's note (21 Nov 2026): keep today's default unchanged; any AAC/Opus route is an explicit opt-in
flag; fix the message so it names the options; state FLAC's size cost; write the default-change question
for Will instead of deciding it. No tag, no release.

Premise check (2026-11-21, main at 2909847): confirmed. `lib/neutraliser/codec_choice.rb` step 3 returns
FLAC or nil for over-6-channel tracks; `lib/neutraliser/guards.rb` `channel_count` carries the false
message; README says "several times the size" with no figure.

## Scope

### Must Do
- An opt-in flag choosing AAC or Opus for over-5.1 tracks whose own codec ffmpeg cannot write.
- Default behaviour unchanged (FLAC in MKV under `--allow-codec-change`, skip elsewhere).
- `too_many_channels` message that names the options that would work in that container.
- FLAC 7.1 size cost in the README, the `--allow-codec-change` help, and the run log.
- The default-change question for Will in the Steady task notes.

### Won't Do
- Change the default route.
- Tag or release.
- Rename the `too_many_channels` reason (manifest compatibility).

## Success Criteria
- [ ] `process --lossy71 aac --allow-codec-change` levels an E-AC-3 7.1 track in MP4 and MKV as AAC 7.1
- [ ] `--lossy71 opus` does the same as Opus where the container and channel layout allow it
- [ ] Without the flag, decisions are identical to before (specs unchanged)
- [ ] The too_many_channels message no longer claims no encoder holds more than 5.1, and names `--lossy71`
- [ ] README and `--allow-codec-change` help state the FLAC size cost

## References
- docs/research/0007-71-eac3-sceptical-review/research.md (finding 3)
- docs/design/adr/0001-smart-codec-selection.md
- Steady task: 66a329d3-31dd-47c9-91d2-7f0662d33199

## Assumptions
- The flag does not imply `--allow-codec-change`: E-AC-3 to AAC is still a codec change and keeps the
  one consent gate. The codec-change skip message names the flag pair.
- A lossless source (TrueHD, PCM, FLAC, DTS-HD MA) keeps going to FLAC where the container takes it;
  the flag only reaches it where no lossless output is possible.
