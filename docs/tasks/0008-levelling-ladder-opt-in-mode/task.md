---
id: task-0008
type: spec
purpose: "Build the vision's levelling ladder (gain, limiter, compression, convert) as one opt-in mode with a target parameter, so switching the default later is a one-line change."
tags: ["ladder", "recipe", "dialogue", "report"]
related: ["../../philosophy/vision.md", "../../work/roadmap.md", "../../research/0002-streaming-loudness-and-dialogue/research.md"]
created: 2026-11-15
updated: 2026-11-15
---

# Build the levelling ladder as an opt-in mode so the default flip is one line

Vision alignment: Have an online presence (goal: Release neutraliser publicly)

## Goal

`neutraliser process --ladder` does the least that works for each file: constant gain, then a
limiter when peaks block the gain, then compression when the loudness range is over a limit, and
(only where the operator allows it) codec conversion of lossless or object audio. The target is a
parameter: whole-programme or dialogue, at any level. The default is unchanged; switching it later
is one line (`Recipe::CURRENT = LADDER`) plus docs.

## Context

The vision (`docs/philosophy/vision.md`, 1 Nov) wants dialogue steady and loud moments within a
limit. The default switch waits on the real-file dialogue check and on Will's pick of target
(dialogue -27, dialogue -24, or keep -20 whole programme). This task builds the ladder now so the
switch needs no code.

Premise check (2026-11-15, main at 3f5c44f): no ladder mode exists. All its parts do:
`--limit-db` (`GainPlan`, mode `limited`), `--lra-target` / `--centre-boost` (`Compression`, mode
`compressed`), `--allow-codec-change` and `--allow-object-audio-loss` (`Guards`), `--target-level`
(custom profile), the read-only dialogue estimate (`DialogueMeter`), and recipes (`Recipe`, dbfb20e).
Missing: one switch that bundles them with the vision's defaults, a dialogue-anchored target, a
recipe number for the ladder, and a rung column in `report`.

## Scope

### Must Do
- One opt-in switch (`--ladder`) that turns on rung 2 (limiter, up to 6 dB) and rung 3 (compression
  when LRA is over 13), each overridable by the existing flags.
- Target as a parameter: `--anchor programme|dialogue` with `--target-level`; dialogue uses the
  read-only estimate, so -27 / -24 / -20 is a config choice.
- Rung 4 stays behind `--allow-codec-change` / `--allow-object-audio-loss` (Will's library passes
  them; others keep the cautious defaults).
- Ladder output stamped with its own recipe number (3).
- `report` shows the rung each file took (summary counts, TSV and JSON).
- Real-ffmpeg fixture tests for each rung, and for the dialogue anchor.
- Switching the default is one line.

### Won't Do
- Change the default. No NAS writes; don't restart the sweep.
- The loudness-above-dialogue compression trigger (the vision's "later").
- A voice-activity gate for stereo dialogue (ADR 0003).

## Constraints

- CI green on ffmpeg 4.2 and 7.1 (`--limit-db` needs 5.1+).
- A run never re-levels a file because of its recipe; only `--redo-recipe` does.

## References

- `docs/philosophy/vision.md`, `docs/work/roadmap.md`
- `docs/research/0002-streaming-loudness-and-dialogue/research.md` (section c, ladder table)
- `docs/ops/data_contracts.md` (stamp schema)
- Steady task: c194eca9-c049-45a6-82a5-2928f24d58dd

## Success Criteria

- [ ] `--ladder` levels a fixture by rung 1, 2, 3 and (with the allow flags) 4, each stamped and shown by `report`.
- [ ] `--ladder --anchor dialogue --target-level -27` lands a 5.1 fixture's centre near -27 LUFS.
- [ ] Without `--ladder`, behaviour and stamps are unchanged (recipe 2).
- [ ] Flipping `Recipe::CURRENT` to `LADDER` turns the ladder on by default (spec proves it).
- [ ] `bundle exec rspec` and `bundle exec rubocop` pass on ffmpeg 7.1; 4.2-only paths skip cleanly.

## Assumptions

- "-24" in Will's choice is read as dialogue -24 (research 0002 table row G), so the anchor and the
  level are separate settings.
- With no dialogue estimate (stereo, mono), a dialogue-anchored file aims its programme 3 LU above
  the dialogue target (Netflix's -24 programme for -27 dialogue).
