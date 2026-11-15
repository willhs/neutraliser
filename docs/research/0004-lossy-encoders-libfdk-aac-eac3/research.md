---
id: lossy-encoders-libfdk-aac-eac3
type: note
purpose: "Whether a better lossy encoder (libfdk_aac, a better E-AC-3 path) or bitrate headroom would cut the one unavoidable lossy-to-lossy generation on the re-encoded primary track, measured on real clips."
scope:
  - "FFmpeg's native aac, libfdk_aac, ac3 and eac3 encoders, at the bitrate neutraliser picks today and at +25% and more"
  - "Four 30 s windows of one film (Tears of Steel, CC-BY), four source kinds: AAC 2.0 128k, AAC 5.1 384k, AC-3 5.1 448k, E-AC-3 5.1 640k"
  - "Three consecutive passes of the shipped path on the same clips (added 2026-11-15)"
non_goals:
  - "No listening test. No real-library files (the NAS is not reachable from a job). No code change"
tags: ["research", "codec", "aac", "ac3", "eac3", "libfdk_aac", "quality"]
related:
  - "docs/design/adr/0001-smart-codec-selection.md"
  - "docs/philosophy/vision.md"
  - "docs/research/0002-streaming-loudness-and-dialogue/research.md"
---

# Better lossy encoders for the one re-encoded track

Run 2026-11-08. Vision alignment: Least lossy by default (the goal that wants the smallest cost to quality per levelled file).

## Verdict

**Do not add libfdk_aac. Bitrate headroom on the encoders we already ship is the cheap lever; take it as a small, separate change. No better E-AC-3 encoder exists to switch to.**

| Question | Answer | Confidence |
|---|---|---|
| Is libfdk_aac available where this runs? | No. The Dockerfile's Debian 13 `ffmpeg` has no libfdk_aac, and the image is published to GHCR under MIT | [Direct] `results/encoder-availability.txt`; `Dockerfile`, `.github/workflows/docker.yml` |
| Does it sound better at the same bitrate? | Below 16 kHz it measures a little better (+0.02 to +0.04 ViSQOL, +4 to +7 dB SNR) and loses above it (it cuts at about 16 kHz, native keeps about 18 kHz). Over the full band it measures worse at the same bitrate (4.28 against 4.52 at stereo 128k) | [Supported] 100 encodes, two metrics, below |
| Does +25% bitrate on the native encoder help? | Yes, in every one of 16 source-window pairs (4 sources x 4 windows): +0.05 to +0.06 ViSQOL on average | [Supported] `results/tables.md`; cost is about +25% of the audio track |
| Is there a better E-AC-3 encoder? | Not in FFmpeg. Its `eac3` scored 0.015 to 0.036 below its own `ac3` at equal bitrate; turning coupling off changed nothing | [Supported] for the measurement; [Unknown] for any other encoder (nothing open-source found; Dolby's is commercial, from memory) |
| Does a `--redo-recipe` pass land on the same bitrate, and what does it cost? | Same bitrate to the bit in 16 of 16 cases; but each pass costs about as much again (ViSQOL -0.04 to -0.18 a pass, stereo AAC most), so headroom does not hold the quality | [Direct] rate, [Supported] loss; section "Repeated generations" |
| Is a single generation audibly bad today? | Unknown. The metric says today's native 128k AAC sits 0.2 below the identity ceiling (4.52 against 4.73), a small gap; no one listened | [Unknown] |

**Recommendation.** (1) Drop "runtime detection of libfdk_aac" from ADR-0001's open list: rejected, with this note as the reason. (2) The headroom change is filed as one Steady task (`e0cc927b-4ad2-46fd-ab7c-7798b0745b86`, idea lane): bitrate = min(cap, 1.25 x the first-generation bitrate), where the first generation comes from the stamp so a `--redo-recipe` pass does not grow it again. (3) Leave E-AC-3 alone apart from (2).

## What was measured

Every case runs the way `process` does: decode with `-drc_scale 0`, one constant gain, encode, then compare with `decode(source) + gain`. The reference is what a perfect re-encode would give, so the score is the cost of this one generation only.

- **Sources.** AC-3 5.1 448k is Tears of Steel's own Dolby release, cut by stream copy (real Dolby encoder). The other three are made here: AAC 2.0 128k and AAC 5.1 384k with Apple's AudioToolbox encoder (so no candidate re-encodes its own output), E-AC-3 5.1 640k with FFmpeg's encoder (no Dolby encoder to hand, so E-AC-3 to E-AC-3 is the same encoder twice).
- **Gain.** Capped so each clip's sample peak lands at -1 dBFS, like the real peak cap (-2.8 to +4 dB). My first run used a fixed +4 dB, pushed these hot clips over 0 dBFS, and made the native encoder read 2.9 dB low (libfdk_aac 0.35). That run was thrown away and the gain rule fixed; the discarded numbers are not kept [Inferred: the encoder level drop is a clipping artefact, I did not chase its cause].
- **Metrics.** ViSQOL v3 audio mode (a community pure-Python port, `visqol-python`; not checked against Google's C++ build), mean over the full-range channels (L, R; L, R, C, Ls, Rs for 5.1). Identity scores 4.73 and native AAC 320k scores 4.72 (one window, one channel), so the scale has room above the 4.5 to 4.7 band the candidates sit in. Second pass: both signals low-passed at 16 kHz, to separate bandwidth from in-band quality. SNR (null test) as a cross-check; it is not perceptual.
- **FFmpeg.** 7.1.1 in Docker on Debian 13 with fdk-aac 2.0.3 (`lab/Dockerfile`), same base as the production image. Native encoders there behave like Debian's 7.1.5 [Inferred: same codec code, I did not rerun on 7.1.5].

## Results

Means over four windows. "<16 kHz" is ViSQOL with both signals low-passed. Full tables, bandwidths and the per-window rows are in `results/`.

| Source | Encoder, bitrate | kbit/s | ViSQOL | <16 kHz | SNR dB | Bandwidth kHz |
|---|---|---|---|---|---|---|
| AAC 2.0 128k | native 128 (**today**) | 133 | 4.516 | 4.540 | 20.8 | 17.8 |
| | native 160 (+25%) | 166 | 4.570 | 4.586 | 24.4 | 18.0 |
| | native 192 | 199 | 4.646 | 4.658 | 25.0 | 18.1 |
| | libfdk 128 | 132 | 4.283 | 4.562 | 25.5 | 15.9 |
| | libfdk 160 (+25%) | 164 | 4.532 | 4.671 | 28.2 | 16.4 |
| | libfdk 192 | 196 | 4.680 | 4.710 | 30.9 | 17.4 |
| AAC 5.1 384k | native 384 (**today**) | 389 | 4.561 | 4.603 | 22.2 | 17.9 |
| | native 480 (+25%) | 484 | 4.621 | 4.637 | 24.5 | 18.0 |
| | libfdk 384 | 388 | 4.441 | 4.640 | 29.4 | 16.4 |
| | libfdk 480 (+25%) | 485 | 4.642 | 4.704 | 32.6 | 17.4 |
| AC-3 5.1 448k | ac3 448 (**today**) | 450 | 4.538 | 4.627 | 25.7 | 20.0 |
| | ac3 576 (+25%) | 578 | 4.599 | 4.668 | 29.0 | 20.0 |
| | ac3 640 (cap) | 642 | 4.626 | 4.690 | 30.7 | 20.1 |
| | eac3 448 (policy keeps AC-3, shown for the encoder) | 450 | 4.522 | 4.612 | 24.5 | 20.0 |
| E-AC-3 5.1 640k | eac3 640 (**today**) | 642 | 4.604 | 4.670 | 29.3 | 20.2 |
| | eac3 800 (+25%) | 802 | 4.659 | 4.715 | 32.1 | 20.2 |
| | ac3 640 (policy keeps E-AC-3, shown for the encoder) | 642 | 4.628 | 4.693 | 30.1 | 20.2 |
| | eac3 640, coupling off | 642 | 4.604 | 4.670 | 29.3 | 20.2 |

### What the numbers say

1. **libfdk_aac keeps the waveform better and gives up the top octave.** At the same bitrate its SNR is 4 to 7 dB higher (waveform fidelity), its in-band ViSQOL is 0.02 (stereo 128k) to 0.04 (5.1 384k) higher, and it stops at 15.9 to 16.4 kHz where native reaches about 18 kHz. [Supported] ViSQOL's full-band score charges the missing top, hence 4.28 against 4.52. Whether a loss above 16 kHz matters is a hearing question this note does not settle [Unknown].
2. **At the same bitrate the in-band gap is inside the window-to-window spread.** Paired `<16 kHz` differences, libfdk minus native, at stereo 128k: +0.029, +0.002, -0.026, +0.085; at 5.1 384k: +0.044, -0.010, +0.051, +0.063. At +25% it is cleaner: +0.075 to +0.097 on all four stereo windows. [Supported] That is a real in-band edge at 160k, not a large one.
3. **Headroom helps every encoder, every window.** Paired differences for +25% over today are positive in all 16 pairs: stereo AAC +0.019 to +0.087, 5.1 AAC +0.012 to +0.050, AC-3 +0.019 to +0.054 (`<16 kHz`), E-AC-3 +0.035 to +0.053. [Supported] On stereo AAC it buys back about a quarter of the gap to the 4.73 ceiling (0.054 of 0.214), and 192k (+50%) about 60%; it does not remove the generation. The ceiling was measured on one stereo channel and is assumed for 5.1.
4. **FFmpeg's E-AC-3 is no better than its AC-3 at the same rate.** `eac3` is 0.015 to 0.036 below `ac3` at 640k (all four windows) and 0.016 below at 448k on average. `-channel_coupling 0` produced bit-identical scores to the default. [Supported] I did not read the encoder source to say which E-AC-3 tools it lacks [Unknown].

### Cost of +25%

Audio track growth only, per hour of runtime: stereo AAC 128 to 160k is about 14 MB; AAC 5.1 384 to 480k about 43 MB; AC-3 448 to 576k about 58 MB; E-AC-3 640 to 800k about 72 MB. [Direct: arithmetic from the bitrates] Against a video track in the gigabytes this is small, but it breaks ADR-0001's "match the source bitrate" and the vision's "keeps the source codec and bitrate", so the change needs that wording amended.

### Repeated generations (`--redo-recipe`), run 2026-11-15

The shipped headroom (commit 0037de7) came after this note, and ADR-0001's amendment says a second pass "writes the same rate". This measures it, three passes deep, and what each pass costs.

**Answer.** Generation 2 and 3 land on the same bitrate as generation 1, in all 16 source-window cases. [Direct: `results/generations.jsonl`, `target_bps` equal across passes] Quality is not held: every pass costs about as much again, so the +25% buys a better first generation and does not stop the slide. [Supported: 4 sources x 4 windows, one film]

Method. Each source is encoded three times in a row, each pass reading the last pass's output. Which encoder and bitrate each pass uses comes from the shipped code, not from a table of mine: `lab/decide.rb` runs the real `FFmpegWrapper.decide_codec` (so `CodecChoice.decide` with the file's own `NEUTRALISER_*` stamp, the container's `BPS` tag and, for AC-3/E-AC-3, the dialnorm) and the real `build_stamp`, and `lab/generations.py` writes that stamp into the file with the encode. Pass 1 applies the same peak-capped gain as before; passes 2 and 3 apply 0 dB, which is what a redo over a file already at target does [Inferred: a real redo re-measures and could add a fraction of a dB; I did not run the full CLI]. The reference is the same every pass, `decode(source) + gain`, so each score is the cumulative cost since the source. FFmpeg is Debian 13's own 7.1.5 package in Docker (the shipped image's), not the 7.1.1 fdk build the first runs used; pass 1 reproduces the earlier +25% rows (stereo AAC 4.570 against 4.570, AAC 5.1 4.621 against 4.621, AC-3 4.599 against 4.599, E-AC-3 4.659 against 4.659).

Means over four windows; the change columns are paired per window (min to max).

| Source | Pass | Encoder, target kbit/s | Stamp's first-generation kbit/s read | File kbit/s | ViSQOL | SNR dB | ViSQOL change from previous pass | SNR change dB |
|---|---|---|---|---|---|---|---|---|
| AAC 2.0 128k | 1 | aac 160 | none | 166 | 4.570 | 24.6 | | |
| | 2 | aac 160 | 128 | 166 | 4.389 | 21.1 | -0.180 (-0.207 to -0.156) | -3.5 |
| | 3 | aac 160 | 128 | 166 | 4.246 | 19.2 | -0.144 (-0.164 to -0.112) | -1.8 |
| AAC 5.1 384k | 1 | aac 480 | none | 485 | 4.621 | 24.3 | | |
| | 2 | aac 480 | 384 | 486 | 4.534 | 22.5 | -0.087 (-0.096 to -0.078) | -1.8 |
| | 3 | aac 480 | 384 | 486 | 4.443 | 21.6 | -0.091 (-0.097 to -0.080) | -0.9 |
| AC-3 5.1 448k | 1 | ac3 576 | none | 578 | 4.599 | 29.0 | | |
| | 2 | ac3 576 | 448 | 578 | 4.558 | 28.8 | -0.041 (-0.052 to -0.033) | -0.2 |
| | 3 | ac3 576 | 448 | 578 | 4.519 | 28.8 | -0.039 (-0.062 to -0.029) | 0.0 |
| E-AC-3 5.1 640k | 1 | eac3 800 | none | 802 | 4.659 | 32.1 | | |
| | 2 | eac3 800 | 640 | 802 | 4.612 | 32.3 | -0.046 (-0.051 to -0.042) | +0.1 |
| | 3 | eac3 800 | 640 | 802 | 4.561 | 32.4 | -0.051 (-0.066 to -0.045) | +0.1 |

(Target kbit/s is rounded: the stereo AAC windows range 160.0 to 160.9, AAC 5.1 480.0 to 482.3, because the first-generation figure is the source file's measured rate. Per-window rows: `results/generations.jsonl`, `results/generations.md`.)

What it says:

1. **The rate is stable.** Pass 1 reads no stamp, takes the file's own bitrate and writes 1.25x of it. Passes 2 and 3 read the stamp's first-generation figure (128, 384, 448, 640k) and write exactly the same target again, to the bit, in every case. The file on disk is within 1 kbit/s of the same size each pass. [Direct] This is what ADR-0001's amendment claims, and it holds, including the AC-3 step rounding (448k to 576k each time).
2. **Each pass loses about as much as the first did.** Pass 1 sits 0.07 to 0.16 below the 4.73 identity ceiling (measured on one stereo channel, assumed for 5.1); stereo AAC then drops a further 0.18 and 0.14, AAC 5.1 about 0.09 per pass, AC-3 and E-AC-3 about 0.04 to 0.05 per pass. Pass 1 to 3 in total: stereo AAC -0.32, AAC 5.1 -0.18, AC-3 -0.08, E-AC-3 -0.10. [Supported] The score falls in every one of the 32 paired window steps (none is positive; the smallest fall is -0.029).
3. **Headroom does not pay for a redo.** After one `--redo-recipe`, stereo AAC (4.389) is already below a single generation at today's 128k (4.516); after two it (4.246) is below a single generation at 96k (4.289). AAC 5.1 is under the single-generation "today" score (4.561) at pass 2 (4.534). AC-3 stays ahead of a single un-headroomed generation (4.538) through pass 2 (4.558) and falls under it at pass 3 (4.519); E-AC-3 likewise (today 4.604; 4.612, then 4.561). [Supported]
4. **Stereo AAC suffers most.** It loses twice what AAC 5.1 does per pass and about four times what the Dolby codecs do. I did not isolate why (rate per channel, the encoder, the mix) [Unknown].
5. **SNR agrees on AAC, not on Dolby.** SNR falls 5.4 dB over the AAC 2.0 passes and 2.7 dB for AAC 5.1 but is flat for AC-3 and E-AC-3, while ViSQOL still falls 0.04 to 0.05 a pass. Flat SNR with falling ViSQOL means the second AC-3 pass changes things the null test does not count much (it is dominated by loud, well-coded content) and the perceptual model does [Inferred]. As before, SNR is a cross-check, not a verdict.

Caveats specific to this run. The measured lags are exactly 1024, 2048, 3072 samples (AAC) and 256, 512, 768 (Dolby): each pass adds one codec frame of delay, so a pass's frame grid lands on the previous pass's. A real remux that keeps the container's delay compensation would probably line up the same way [Inferred: not run], but this is a best case for loss; a trimmed or re-cut file would not align, and could lose more or less [Unknown]. The AAC sources were made by Apple's encoder and passes 1 to 3 use FFmpeg's native one, so the second and third pass are native to native, the case a library pass sees after its first. Four 30 s windows of one film; no listening test; ViSQOL is a port. A pass-by-pass gain of 0.04 to 0.18 on a 1 to 5 scale is a measured trend, not a verdict that anyone hears it [Unknown].

**Consequence for ADR-0001.** No contradiction, so the ADR is unchanged and behaviour is untouched. The amendment claims the rate stays put on a redo, which it does; it also says the headroom "does not remove the generation" (point 3 above), which this confirms. What this adds is a number for the cost of a redo: roughly the cost of the first generation again each time, largest on stereo AAC. If `--redo-recipe` (or a second pass under another profile, which the amendment also covers) is run casually over a library, that cost belongs in front of the user; a way to avoid it would be a stream copy plus a gain tag where the gain is small, which is a separate design question and not tested here.

## Why not libfdk_aac

- **It cannot come from the package the image uses.** Debian 13's `ffmpeg` has no libfdk_aac [Direct] (`results/encoder-availability.txt`; `docker run debian:trixie`). Fraunhofer's licence is reported to conflict with the GPL, and FFmpeg's LICENSE says a `--enable-nonfree` build is not redistributable; an LGPL-only build with it is discussed as possibly distributable. [Supported] Sources: [FFmpeg LICENSE.md in a commit diff](https://git.kx.studio/falkTX/FFmpeg/commit/479a5f644f07d78b2de0536d85a094c2f73b0d7d), [ffmpeg-devel licence thread](https://lists.ffmpeg.org/pipermail/ffmpeg-devel/2018-May/230618.html), [Doom9](https://forum.doom9.org/showthread.php?p=1894966). Not legal advice. Shipping it means building FFmpeg ourselves in CI and publishing it, a licensing call for the owner.
- **Detection alone would not help production.** Runtime detection only helps people whose own `ffmpeg` has it. The developer's Homebrew build does not either (`aac_at`, Apple's encoder, is there instead; it does not exist on Linux).
- **Output would depend on the machine.** The same file would come out of two hosts with different encoders and different bandwidth. The recipe version and the stamp say nothing of the encoder, and CI could not test the fdk path.
- **The measured gain is modest and mixed** (points 1 and 2 above), while headroom on native gives most of the same in-band improvement everywhere.

## What we don't know

- **Whether anyone can hear it.** No listening test; ViSQOL MOS-LQO is a proxy, from a port not checked against the C++ build, and the differences between candidates are 0.02 to 0.1 on a 1 to 5 scale.
- **Real library files.** One film (an animated feature with an orchestral score and dialogue), four 30 s windows, a CC-BY source. The NAS is not reachable from a job. A speech-heavy live-action or low-bitrate stereo AAC library could rank differently.
- **A real E-AC-3 source.** The E-AC-3 source here was made with FFmpeg's own encoder; the AC-3 source is a real Dolby stream. Real Dolby E-AC-3 (Atmos-tagged DDP, adaptive transform) is not covered.
- **Other encoders.** Searched for an open E-AC-3 encoder and for ViSQOL/PEAQ options; found a pure-Python ViSQOL port (used) and GstPEAQ and AquaTk for PEAQ (not used). Apple's `aac_at` exists only on macOS and was only used to make sources.
- **Repeated generations beyond three, or on re-cut files.** Three passes were measured (section "Repeated generations"); a file whose frame grid no longer lines up with the last pass, or a fourth pass onward, was not.
- **fdk at its own VBR.** `-vbr 3` landed at about 105 kbit/s and scored 4.288, level with native CBR 96k (4.289); other VBR levels, SBR/HE-AAC profiles and `afterburner` off were not tried.

## Reproduce

`lab/Dockerfile` (FFmpeg with libfdk_aac), `lab/prep.py` (build sources from the [Tears of Steel](https://download.blender.org/demo/movies/ToS/) AC-3 and stereo mix; credit: (C) Joram Letwory, CC BY-ND 3.0 for the soundtrack files, `results/source-licence.txt`), `lab/run.py` (encode and score), `lab/score_lowpass.py`, `lab/analyze.py` (tables). The repeated-generation run (2026-11-15) adds `lab/generations.py` (three passes, scored), `lab/decide.rb` (the shipped `decide_codec` and `build_stamp`, run from the repo root with rbenv Ruby 3.2) and `lab/analyze_generations.py`; its image is plain `debian:trixie` plus `apt-get install ffmpeg` (7.1.5). Docker Desktop's credential helper hung `docker pull` in a job; an empty `DOCKER_CONFIG` directory got round it. The media and the Docker image are not committed. `visqol-python` in a virtualenv, `NUMBA_NUM_THREADS=1`; a full run is about an hour on 18 cores.

Decision trail: `decisions.tsv`.
