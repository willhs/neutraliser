---
type: note
status: active
owner: will
contributors: []
updated: 2026-11-01
review_cycle: 90d
agent_write: false
links: ["docs/design/plex-analysis-guide.md"]
summary: "How far a sampled loudness estimate sits from a film's true integrated loudness, measured on 10 real Plex films, and what analyze-plex does about it"
tags: [research, plex, loudness, accuracy]
---

# analyze-plex: how far can a loudness sample be wrong?

## Question

`analyze-plex` judged each title from a 60 s sample against a 1.0 LU tolerance. After the sample moved from a film's opening to its middle (commit 3edfb85), Chariots of Fire still read 3 LU from its true integrated loudness, more than the tolerance. Can any sampling scheme support a ±1 LU verdict, and if not, what may the report claim?

## Method

Read-only against the live Plex server (GET requests and `ffmpeg` reads only; nothing written to the library or the NAS). For 10 films longer than 75 minutes (Chariots of Fire, plus nine drawn at random, seed 7) the full audio stream was measured with `FFmpegWrapper.measure_loudness` (the same loudnorm pass `process` uses: 5 to 7 minutes per film over HTTP), then nine 60 s windows centred at 10%, 20% ... 90% of the runtime, then the middle 60 s. Every sampling scheme was scored offline against the full measurement. Windows are combined as mean-square energy, never by averaging LUFS values.

Two things went wrong and were discarded rather than used:

- Four or more parallel readers made Plex return 5XX errors mid-read. ffmpeg treated the truncated stream as end-of-file and reported success with a bogus level (a "full" read finishing in 1 to 4 seconds at -33 to -41 LUFS). A single reader reproduced the same numbers on repeat reads and matched the NAS sidecar for Chariots of Fire exactly (-20.0). Only single-reader runs are used below.
- loudnorm prints `input_i: "-inf"` when it hears nothing, and Ruby's `"-inf".to_f` is `0.0`. A window that returned no audio therefore read as 0 LUFS, the loudest possible. `Measurement` now flags it `silent?`.

## Result

Error of each sampling scheme against the full-stream truth, in LU (negative = the sample read quieter than the film):

| Title | Truth (LUFS) | Middle 60 s | 5 windows | 9 windows |
|---|---|---|---|---|
| Chariots of Fire | -20.0 | -2.9 | -2.6 | -2.6 |
| Don't Be a Menace to South Central | -21.6 | -2.4 | -0.2 | -1.2 |
| Eternal Sunshine of the Spotless Mind | -20.0 | -0.3 | -0.2 | -0.0 |
| The Replacements | -19.5 | -2.3 | +0.1 | +0.0 |
| Paul | -19.5 | -2.3 | -4.5 | -2.4 |
| Shrek 2 | -24.8 | +2.7 | +0.7 | +1.0 |
| Fear and Loathing in Las Vegas | -20.0 | -2.7 | -1.8 | -1.4 |
| Star Wars: Episode IV - A New Hope | -18.8 | -3.5 | -0.5 | -0.3 |
| The Jackal | -19.9 | -2.3 | -6.5 | -3.7 |
| Edward Scissorhands | -21.4 | -7.4 | -2.7 | -4.0 |

| Scheme | Mean error | RMS error | Worst error | Within ±1 LU |
|---|---|---|---|---|
| Middle 60 s (shipped before) | -2.3 | 3.4 | -7.4 | 1 of 10 |
| 5 windows, energy-combined | -1.8 | 2.8 | -6.5 | 5 of 10 |
| 9 windows, energy-combined | -1.5 | 2.2 | -4.0 | 4 of 10 |
| 5 windows, arithmetic mean of LUFS (wrong) | -2.7 | 3.7 | -9.0 | 4 of 10 |

Reading it:

1. **Where, not how long.** Window size doesn't help (Chariots: 60/300/600 s all read -23.2). Spreading windows across the runtime does help, but not enough.
2. **No scheme supports ±1 LU.** Even nine windows were within 1 LU on only 4 of 10 films.
3. **The error is one-sided.** Samples mostly read quieter than the film: a film's energy sits in its loudest scenes, and a handful of windows miss them. The 5-window estimate read 0 to 6.5 LU quieter than the truth and at most 1.0 LU louder (11 films, including the check below).
4. **Judged as if exact, the old per-file verdicts were wrong 6 times in 10** (the middle window's verdict differed from the full measurement's).
5. **Energy-combining matters.** Averaging window LUFS as numbers is the worst scheme tried.
6. **A synthetic file shows the failure can be much worse and either way.** A 15 minute file with a 90 s loud burst scored -15.6 LUFS in full. Five windows that happened to miss the burst said -25.5 (10 LU low, the wrong side of the tolerance band); five that caught it overshot by 1.6. Real films are tamer, but the mechanism is the same.

Cost over HTTP: a window is about 4 s, so 5 windows is about 19 s per title and 9 is about 34 s; a full read was 150 to 420 s per film (about 56 hours for the 807-film library). Full reads cannot be parallelised against Plex without the truncated-read problem above.

## Decision

Options from the task, decided on the evidence:

| Option | Verdict |
|---|---|
| 1. Measure every title in full | Accurate but 56 hours for this library, and not safely parallel. Kept as opt-in `--full`. |
| 2. Energy-combine windows across the runtime | Adopted as the default estimator (5 x 60 s at 10/30/50/70/90%). Strictly better than one window, still not ±1 LU. 9 windows cut the worst case from 6.5 to 4.0 LU but cost 80% more time and change no verdict. |
| 3. Stop per-file verdicts for samples | Adopted for the cases the data can't support. |

`LoudnessEstimate` carries a level and the range the true level can lie in (-1.5 LU to +7 LU around the 5-window estimate: the observed extremes, each widened by 0.5 LU). A sampled title gets a verdict only when that whole range is on one side of the tolerance band. Replayed against the 10 films: no confident verdict contradicted the truth, and all ten came back "unclear". Which also means a sample can never certify a title as OK; it can only flag outliers (an estimate more than about 6 LU under target, or more than about 0.5 LU over the top of the tolerance band) and rank the rest.

## Limits

- 10 films from one library, one server. The margins are observed extremes, not guarantees. A louder tail (action films with long quiet stretches) could exceed them; the synthetic case above does.
- Audio track 0 only, as in the rest of the Plex path.
- Out-of-sample check: the live CLI run (1% of the Movies library, 9 titles) gave one confident verdict, Indiana Jones and the Temple of Doom, "Too Loud" at an estimate of -17.7 LUFS. A `--full` read (520 s) gave -18.69 LUFS, 1.3 LU over target: the verdict held, and the sample had read 1.0 LU *louder* than the truth, a new extreme on the other side, which is why the quieter margin is 1.5 rather than the 1.0 first observed.
