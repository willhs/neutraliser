---
id: plan-0008
type: spec
purpose: "Implementation plan for the opt-in levelling ladder (--ladder, --anchor), recipe 3 and report rungs."
tags: ["plan", "ladder", "recipe", "dialogue", "report"]
related: ["./task.md"]
---

# Levelling ladder (opt-in) Implementation Plan

## Overview

Bundle the existing rungs into one switch, add a dialogue-anchored target, give ladder output its own
recipe, and show the rung in `report`. The default stays constant gain (recipe 2); the flip is
`Recipe::CURRENT = LADDER`.

**Primary Goal**: `process --ladder [--anchor dialogue] [--target-level N]` levels each fixture by the
least rung that works, stamps recipe 3, and `report` names the rung.

**Approach**: no new levelling machinery. The ladder is option defaults plus a per-file *aim* (the
programme level a file is levelled to). Programme anchor: the aim is the profile. Dialogue anchor:
aim = dialogue target + (programme − dialogue estimate), so the existing `GainPlan`, `Compression`
and tolerance checks work unchanged on it.

## Current State Analysis

- Rungs already exist and already run in ladder order in `Processor#process_file_two_pass`
  (`lib/neutraliser/processor.rb:425`): compression plan first (`--lra-target`), then peak-limited
  skip, then `GainPlan` (limited when `--limit-db` lets the gain past the ceiling).
- `--limit-db` defaults to `0.0` in the CLI (`cli.rb`), so "not given" can't be told from "0".
- `Recipe::CURRENT` (2) is written by `Stamp.now`, `LeftRecord.for` and `SkipDecider#mark_processed`
  defaults; `Recipe.check_redoable!` refuses `>= CURRENT`.
- `Profiles.find` rebuilds a profile from a stamp's name (`custom-18`); `FinalLevels` and `Report`
  judge files against it.
- `DialogueMeter.estimate(file, track)` reads the centre channel (`pan=mono|c0=c2`) through loudnorm.
- `Report::Row` derives `state` from the stamp's mode; no rung.

### Key Discoveries
- `FFmpegWrapper.apply_normalization` builds its own `GainPlan` from the profile it is given, so
  passing the per-file aim (same name, different `lufs`) is all it needs.
- `Compression::Plan` is a `Data`, so a dialogue re-aim after compression is
  `plan.with(gain_plan: GainPlan.for(plan.after, aim, limit_db:))`.
- `--limit-db` needs ffmpeg 5.1+ (`FFmpegWrapper.wide_filter_options?`); CI runs 4.2.

## Desired End State

- `Ladder` module (`lib/neutraliser/ladder.rb`): defaults (`LIMIT_DB = 6`, `LRA_LIMIT = 13`,
  `NO_DIALOGUE_OFFSET_LU = 3`), `aim`, and `Rung` (`1-gain`, `2-limiter`, `3-compress`, `dynamic`,
  `+convert`).
- `Recipe::CONSTANT_GAIN = 2`, `Recipe::LADDER = 3`, `Recipe::CURRENT = CONSTANT_GAIN` (the flip line),
  `Recipe.for(ladder:)`, `check_redoable!(recipes, writing:)`.
- `Processor.new(ladder: Recipe::CURRENT == Recipe::LADDER, anchor: 'programme', limit_db: nil, ...)`.
- Stamp fields `TARGET_I` and `DIALOGUE_I` (dialogue anchor only); `LeftRecord#target_i`.
- `report`: `Rungs:` summary line, `rung` TSV column and JSON key.

## What We're NOT Doing

- Changing the default, NAS writes, restarting the sweep.
- A loudness-above-dialogue compression trigger; a voice gate for stereo.
- Caching the dialogue estimate (one extra centre-channel decode per surround file under the dialogue anchor).

## Assumptions _(unattended runs: decisions made without the user)_

- **One switch, existing flags override.** `--ladder` fills in `--limit-db 6` and `--lra-target 13`
  only when they aren't given. Why: the task says reuse the machinery; Will can tune each rung.
- **Rung 4 stays behind the allow flags.** The ladder doesn't turn on `--allow-codec-change` /
  `--allow-object-audio-loss`: Will's driver passes them, others keep the cautious defaults (vision).
- **Profile name is the aim, recipe is the method.** Programme anchor keeps the existing profile
  names (`livingroom`, `custom-24`), so turning the ladder on doesn't re-level files already done
  for that profile: only `--redo-recipe 2` does. The dialogue anchor is a new aim, named
  `dialogue-27`, so it does re-level (a target change always has).
- **Dialogue anchor requires the ladder.** A dialogue-anchored constant-gain run with recipe 2 would
  make recipe 2 mean two methods.
- **Dynamic runs turn the ladder off.** `--allow-dynamic`, the night profile and `--fast` pick
  another method, so the ladder steps aside with a log line (after the flip, those flags must keep
  working without `--no-ladder`). `--anchor dialogue` with them is an error.
- **`--fast-verify` drops rung 3** (the sample can't see LRA) with a log line; an explicit
  `--lra-target` with it is still refused as today.
- **Old ffmpeg drops rung 2.** Under 5.1 the ladder runs without the limiter and says so; an
  explicit `--limit-db` there is still refused.
- **No estimate → programme 3 LU above the dialogue target** (Netflix: -24 programme for -27 dialogue).
  Loudness above dialogue is floored at 0 (a centre reading over the programme is a bad estimate).
- **Under the dialogue anchor, compression re-reads the dialogue through the chosen chain** (one more
  decode), because compression moves programme and dialogue by different amounts.
- **Rung is derived, not stamped.** mode → step; codec changed (stamp `source_codec` vs the track's
  codec now) or object audio named in `source_profile` → `+convert`. Works for old stamps too.
- **Recipe 3 for every ladder output**, whatever rung: the recipe is the method, the rung the outcome.

---

## Phase 1: Recipe and stamp groundwork

- [x] `recipe.rb`: `CONSTANT_GAIN`, `LADDER`, `CURRENT = CONSTANT_GAIN`, `for(ladder:)`, `check_redoable!(recipes, writing: CURRENT)` refusing `>= writing`.
- [x] `stamp.rb`: `target_i`, `dialogue_i` (float, default nil); `Stamp.now(recipe: Recipe::CURRENT, ...)`.
- [x] `left_record.rb`: optional `target_i`; `for(..., recipe:, target_i:)`; `from_entry` reads it.
- [x] `skip_decider.rb`: `recipe:` in the constructor, used as `mark_processed`'s default.
- [x] `guards.rb`: `recipe:` passed to `LeftRecord.for`.
- [x] `remote_free_rate.rb`: `FinalLevels` uses `target_i` when set.
- [x] Run: `bundle exec rspec --tag '~real_ffmpeg'` — green (no behaviour change).

## Phase 2: Ladder module and profiles

- [x] `ladder.rb`: constants, `ANCHORS`, `aim(profile, measurement, estimate)`, `Rung.of(stamp, track)` with `label`.
- [x] `profiles.rb`: `dialogue_profile(target, tp:, lra:)` named `dialogue-27` (`lufs = target + 3`, `anchor: :dialogue`, `dialogue_target:`); `find` parses `dialogue-N`.
- [x] `dialogue_meter.rb`: `estimate(file, track, pre_filter: nil)`.
- [x] `spec/ladder_spec.rb`: aim (estimate, no estimate, floor), rung labels, profile round trip.

## Phase 3: Processor and CLI

- [x] `Processor.new`: `ladder:`, `anchor:`, `limit_db: nil`; rung defaults, notes, refusals; `@recipe`.
- [x] `process_file_two_pass`: per-file aim used for compression, peak-limited, tolerance, gain, left records; dialogue re-aim after compression.
- [x] `FFmpegWrapper.apply_normalization(recipe:)` → `build_stamp` writes recipe, `target_i`, `dialogue_i`.
- [x] CLI `process` and `rate-sample`: `--ladder` (default `Recipe::CURRENT == Recipe::LADDER`), `--anchor`, `--limit-db` without a default.
- [x] Specs: option wiring, refusals, flip (`stub_const('Neutraliser::Recipe::CURRENT', 3)` → ladder on), recipe 3 stamped, no-ladder unchanged.

## Phase 4: Report rungs

- [x] `Report::Row#rung`; `counts[:rungs]`; `Rungs:` summary line; `rung` TSV column after `state`; JSON `rung`.
- [x] Update `spec/report_spec.rb` for the new column.

## Phase 5: Real-file fixtures

- [x] `spec/support/ladder_fixture.rb`: narrow clip (rung 1), quiet-but-peaky clip (rung 2), `LraFixture` (rung 3), DTS 5.1 clip (rung 4), 5.1 clip with a known centre level (dialogue anchor).
- [x] `spec/ladder_real_spec.rb` (`:real_ffmpeg`): each fixture through `process --ladder --replace`, stamp mode + recipe 3, `report` rung; rung 2 skips under ffmpeg 5.1; dialogue anchor lands the centre within 1.5 LU of -27.
- [x] Run: `bundle exec rspec` and `bundle exec rubocop` — green.

## Phase 6: Docs

- [x] `docs/ops/data_contracts.md`: recipe 3, `TARGET_I`, `DIALOGUE_I`, left `target_i`.
- [x] README, AGENTS (`.gent/rules.md`), CHANGELOG: `--ladder`, `--anchor`, rungs in report, how to flip the default.
- [x] `docs/philosophy/vision.md` is `agent_write: false`: left alone. Roadmap: note the ladder exists opt-in.
- [x] `docs/log.d/<job>.md` and `docs/index.d/<job>.md` fragments.

## Phase 7: Wrap (commit & finalize)

- [x] `decisions.tsv` complete; commit all paths (no push, no merge).
