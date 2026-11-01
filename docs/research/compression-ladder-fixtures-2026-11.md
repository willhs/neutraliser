---
type: note
status: active
owner: will
contributors: []
updated: 2026-11-01
review_cycle: 90d
agent_write: false
links: ["README.md", "docs/ops/data_contracts.md"]
summary: "What the opt-in --lra-target compression ladder does on a synthetic 5.1 fixture: rung chosen, loudness range, level and peak after, and where the loudnorm and ebur128 readings differ"
tags: [research, compression, lra, fixtures]
---

# `--lra-target`: what the ladder does on a fixture

## Question

`--lra-target N` compresses a file whose loudness range (LRA) is over N, then levels it to the profile target. Does it reach N on a clip shaped like a film mix, what does each setting do to level and peak, and what should the docs claim?

This note reports measurements of arithmetic on a synthetic clip. It says nothing about how any rung sounds. Choosing the amounts by ear is still open: that is why the settings are a ladder the target selects from, and why nothing is on by default.

## Method

`spec/support/lra_fixture.rb` builds a 32 s 5.1 (AC-3, `5.1(side)`) track from eight 4 s pink-noise scenes: quiet "dialogue" in the centre channel only, loud "effects" on all six channels, a quiet bed. A stereo second track rides along to check it is left alone. `demo/compression_ladder.rb` runs `process --replace --lra-target N` (and with `--centre-boost 4`) over a copy per run and reads each output with `ebur128` — a different filter from the `loudnorm` pass that chose the rung. ffmpeg 7.1.1, livingroom profile (-20 LUFS, -1.5 dBTP, `--tolerance 1.0`).

Reproduce: `bundle exec ruby demo/compression_ladder.rb`.

## Results

Measured by `ebur128` on the output files, except the "after" column, which is what `loudnorm` measured on the compressed signal before the final encode (and what the file's `NEUTRALISER_LRA_AFTER` tag holds):

| run | rung | LRA after (loudnorm, pre-encode) | I (LUFS) | LRA (LU) | peak (dBFS) |
|---|---|---|---|---|---|
| source (untouched) | - | - | -21.8 | 15.3 | -9.3 |
| `--lra-target 12` | gentle | 9.3 | -19.7 | 10.0 | -7.8 |
| `--lra-target 12 --centre-boost 4` | gentle | 7.0 | -19.8 | 7.9 | -5.2 |
| `--lra-target 10` | gentle | 9.3 | -19.7 | 10.0 | -7.8 |
| `--lra-target 10 --centre-boost 4` | gentle | 7.0 | -19.8 | 7.9 | -5.2 |
| `--lra-target 8` | moderate | 8.6 | -19.7 | 9.2 | -7.6 |
| `--lra-target 8 --centre-boost 4` | gentle | 7.0 | -19.8 | 7.9 | -5.2 |
| `--lra-target 6` | extreme | 7.8 | -19.7 | 8.2 | -5.2 |
| `--lra-target 6 --centre-boost 4` | gentle | 7.0 | -19.8 | 7.9 | -5.2 |

## Findings

- **It reaches the target when the ladder can.** Targets 12, 10 and 8 land at or under target + tolerance by the pre-encode reading (9.3, 9.3, 8.6). The rung is the gentlest that does, so 12 and 10 share `gentle`.
- **Not every target is reachable.** At 6 even `extreme` stops at 7.8 (8.2 on the output), over 6 + 1. The file is still compressed at `extreme`, the log says "even the strongest compression (extreme) leaves LRA above --lra-target", and the stamp records the real `compression` and `lra_after`. The fixture's range comes from quiet scenes the compressor doesn't lift, since it only pulls loud parts down; a tighter range than that needs upward gain, which this doesn't do.
- **The centre boost does real work on this fixture** because the quiet scenes are centre-only: +4 dB on that channel narrows the range more than a stronger rung does, so target 6 is met by `gentle` with the boost where `extreme` alone fails. A real film's dialogue won't separate this cleanly.
- **Two LRA readings disagree by up to 0.8 LU.** `loudnorm` before the encode says 9.3 and `ebur128` on the file says 10.0 (and 9.1 vs 9.9 on another run). Short clip, different gating and an AC-3 re-encode. The specs allow 1.0 LU, and `NEUTRALISER_LRA_AFTER` is documented as the pre-encode reading.
- **Level lands within 0.3 LU of target** (-19.7 / -19.8 for -20), consistent with the constant-gain default's own accuracy.
- **Peak rises as compression gets stronger** (-9.3 to -5.2 dBFS) because the gain that restores the level is large (about 7 dB for `gentle`, 24 dB for `extreme`, on that earlier version). With `--limit-db`, the limiter holds the overshoot; on a separate run (an earlier, 48 s version of the fixture) at `--target-level -12 --limit-db 10` the output peaked at -0.7 dBFS after the AC-3 encode, above the limiter's -2 dBFS ceiling, as `--limit-db` already does on its own (an encoder can overshoot a sample-peak limiter).
- **Cost:** the search needs at most three extra `loudnorm` reads of the file before the encode (bisection over six rungs), on top of the ordinary measurement. On this 32 s clip a run took about 10 s on a laptop; for a two-hour film that is minutes of extra reading per file. `--dry-run` does the search and writes nothing.

## Design choices behind it

| Choice | Alternatives | Why |
|---|---|---|
| Thresholds relative to the file's own loudness (-6 dB ... -24 dB under it) | The test script's absolute -28 / -34 dB | An absolute threshold does almost nothing to a file already quieter than it. The two first-test settings correspond to the first and third rungs for a file at -22 LUFS. |
| Search the ladder, measuring each candidate | Predict the rung from the LRA gap | The effect depends on the mix; measuring is exact and the cost is bounded. |
| Level after compressing, from the compressed signal's loudness | Level first, or reuse the original measurement | Compression moves the level by 5 to 20 dB. |
| `compressed` is its own mode, applied once | Reuse `limited` or `dynamic` | `dynamic` means loudnorm's AGC and `limited` means a peak limiter; a re-run must not stack a second compression. |
| `--tolerance` is also the LRA tolerance | A new option | Same unit, same meaning ("close enough"); fewer knobs. |

## Not covered

- Any claim about sound. The first test clips (a real film's LRA 17.1 to 13.5 / 9.6 / 7.4) were measured on a NAS this change doesn't touch; the fixture here is a stand-in.
- ffmpeg 4.2.2 locally: only 7.1.1 was available for these runs. CI runs both.
