---
id: plan-0009
type: spec
purpose: "Implementation plan for the opt-in --lossy71 AAC/Opus route, the too_many_channels message and the FLAC 7.1 size cost."
tags: ["plan", "codec", "7.1"]
related: ["./task.md"]
---

# Lossy 7.1 AAC/Opus route Implementation Plan

Vision alignment: Have an online presence (goal: Release neutraliser publicly)

## Overview

**Primary Goal**: `--lossy71 aac|opus` (with `--allow-codec-change`) levels E-AC-3/AC-3/DTS 7.1 as AAC or
Opus 7.1 in MP4 and MKV; the default is byte-for-byte unchanged.

**Approach**: one new input to `CodecChoice.decide` (`lossy71:`, an encoder name or nil), used only at
`resolve_encoder`'s over-5.1 step; threaded CLI -> Processor -> Guards and FFmpegWrapper.decide_codec.

## Current State Analysis

- `lib/neutraliser/codec_choice.rb` `resolve_encoder` step 3: `channels > 6` returns FLAC or nil.
- `lib/neutraliser/guards.rb` `channel_count`: message "no encoder there holds more than 5.1" (false for
  AAC/Opus in MP4). `codec_change` log names only `--allow-codec-change`.
- `lib/neutraliser/codec_tables.rb`: AAC and Opus have 7.1 floors/caps already (7d8986c), and are allowed
  in MP4/M4V/MKV (Opus not in MOV/AVI).
- ffmpeg 7.1.1 checks (this job): native AAC encodes 7.1, 7.1(wide) and unnamed 7ch into MP4; libopus
  encodes 6.1, 7.1 and unnamed 7/8ch but refuses a named `7.1(wide)` ("Invalid channel layout ... for
  specified mapping family -1").

### Key Discoveries
- `FileResult::REASONS` reasons cannot be renamed (manifest read across versions): keep `too_many_channels`.
- `spec/processor_spec.rb` pins the codec_change *message* `eac3 would be re-encoded as flac`; the size
  note goes in the log line, not the message.

## Data shape

`lossy71`: `nil | 'aac' | 'libopus'` (CLI spelling `aac`/`opus`, mapped by `CodecChoice::LOSSY_71`).
Invariant: it only changes the answer for a track with more than six channels whose own codec cannot be
written there, from a lossy source or where the container has no lossless output. `nil` is exactly today.

## Design Options

| Option | Exposes | Verdict |
|---|---|---|
| A. `lossy71:` keyword on `CodecChoice.decide`, threaded through Guards/FFmpegWrapper | one keyword per call site | **chosen**: matches how `allow_codec_change` is threaded; decide stays pure |
| B. Mutate the container table (add AAC preference) per run | global state | rejected: tables are frozen constants shared by every caller |
| C. Flag implies consent (no `--allow-codec-change` needed) | a second consent path | rejected: two gates for one loss; the flag names the encoder, the allow flag gives consent |

## What We're NOT Doing
- Changing the default (question for Will in the Steady notes).
- `rate-sample` support beyond passing the same option (added there for parity, nothing else).

## Assumptions
- Flag name `--lossy71`, values `aac`/`opus` (Thor enum). Thor maps `lossy71` to `--lossy71`.
- Lossless sources (LOSSLESS_CODECS, DTS-HD MA profile) keep FLAC where allowed.
- Opus is taken to hold an over-5.1 track only when its layout is `6.1`, `7.1`, or unnamed; otherwise the
  route falls back to today's answer (FLAC/skip), and the skip message offers only what works.
- Size figure: FLAC 7.1 of decoded lossy film audio is roughly 3-6 Mbit/s against 0.77-1.5 Mbit/s for
  E-AC-3 7.1 (3-5x; research 0007 finding 3 estimate, not measured on a real film).

---

## Phase 1: CodecChoice route

- [x] Add `LOSSY_71 = { 'aac' => 'aac', 'opus' => 'libopus' }` and `OPUS_WIDE_LAYOUTS` to `codec_tables.rb`
- [x] `decide(track, container, sample:, stamp:, lossy71: nil)`; step 3 prefers `lossy71` over FLAC for a lossy source, and uses it where there is no FLAC; `holds?` knows Opus layouts
- [x] Add `CodecChoice.lossy71_options(track, container)`: the `--lossy71` values that would encode this track there
- [x] Specs in `spec/codec_choice_spec.rb`: E-AC-3 7.1 in MP4/MKV with aac and opus; TrueHD 7.1 in MKV stays FLAC; Opus 7.1(wide) falls back; MOV+opus unencodable; nil unchanged
- [x] Run: `bundle exec rspec spec/codec_choice_spec.rb` — green

## Phase 2: Guards, Processor, FFmpegWrapper, CLI

- [x] `Guards.new(lossy71:)`; `channel_count` message names the options; `codec_change` log adds the FLAC size note and `--lossy71` for over-5.1 lossy-to-FLAC
- [x] `Processor.new(lossy71:)` validated (`aac`/`opus`), passed to Guards and `FFmpegWrapper.apply_normalization(_single_pass)` -> `decide_codec`
- [x] CLI `process` and `rate-sample` option `--lossy71`; `--allow-codec-change` help states the size cost
- [x] Specs in `spec/guards_spec.rb` (new message, size note) and `spec/processor_spec.rb` (MP4 E-AC-3 7.1 done under the flag)
- [x] Run: `bundle exec rspec spec/guards_spec.rb spec/processor_spec.rb spec/ffmpeg_wrapper_spec.rb` — green

## Phase 3: Real surface and docs

- [x] Real ffmpeg: FLAC 7.1 in MP4 (no E-AC-3 7.1 can be built) driven through `process` with and without `--lossy71`; see decisions.tsv and evidence/real-run.txt
- [x] README feature bullet, flag table, known limits; `docs/ops/data_contracts.md` too_many_channels wording; AGENTS.md CodecChoice line; CHANGELOG
- [x] Log/index fragments under `docs/log.d/` and `docs/index.d/`
- [x] Steady notes: the default-change question for Will
- [x] Run: `bundle exec rspec --tag '~real_ffmpeg'` and `bundle exec rubocop` — green

## Phase 4: Wrap (commit & finalize)

- [x] Run: `git status`; commit the work with paths named (Manager job: commit only, no merge/push)
- [x] Run: `git status` — clean
