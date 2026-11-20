---
id: 71-eac3-sceptical-review
type: note
purpose: "Sceptical review, before v0.1.0, of the 7.1 handling (615c468: FLAC or skip up front) and the E-AC-3 7.1 follow-up (f96462a): what a stranger's library would hit, with evidence and severity, and what was fixed."
scope:
  - "615c468 and f96462a read against the code, then exercised with synthetic ffmpeg files: 7.1 / 6.1 / 5.1 in MKV, MP4, M4V, MOV, WebM; AAC, Opus, Vorbis, FLAC, PCM, AC-3, E-AC-3, DTS"
  - "process default, --ladder, --allow-codec-change, --redo-recipe, --allow-dynamic, night profile, --fast, --lra-target, --anchor dialogue, --keep-original-audio, --local-stage, a second run, a second run with the sidecars deleted, report"
non_goals:
  - "No real E-AC-3 7.1, Atmos or DTS:X file: ffmpeg 7.1.1 cannot encode them (E-AC-3 stops at 5.1), so those paths are covered by probe-fixture specs only"
  - "No tag, release or post"
tags: ["research", "7.1", "e-ac-3", "review", "release"]
related:
  - "docs/research/0003-sceptical-review-dolby-dialogue-compression/research.md"
  - "docs/research/0006-71-and-atmos-real-files/research.md"
  - "docs/design/adr/0001-smart-codec-selection.md"
---

# Sceptical review of the 7.1 and E-AC-3 changes

## Verdict

The two changes do what they say. A 7.1 track is converted to FLAC or skipped before any measure, and
the skip is recorded, shown by `report`, and not repeated expensively. **The 7.1 handling that was meant
to be reviewed has no bug of its own.** The review did find one serious bug next to it, in the 7.1
loudness read added on 15 Nov, and it is fixed here: `--allow-dynamic` and the `night` profile played a
7.1 file about 14 dB over target. The rest are limits to state in the README or small follow-ups.

Premise check. 615c468 is dated 15 Nov, not 20-21 Nov. f96462a (job 05f065cb) changed no code: it found the
E-AC-3 7.1 case already covered by 615c468 and added regression specs for it (`--ladder`, dry run, MKV
under `--allow-codec-change`, MP4). So "the E-AC-3 change" is tests only. Full suite on the starting
tree: 801 examples, 0 failures, 1 pending.

## Findings

Severity: **high** = wrong output that reaches a stranger's speakers; **medium** = a limit a stranger
meets in ordinary use or a doc that is wrong; **low** = rare or cosmetic.

| # | Severity | Finding | Status |
|---|---|---|---|
| 1 | high | 7.1 under loudnorm's dynamic mode lands ~14 dB over target | **fixed here** |
| 2 | medium | README says every track over 6 channels goes to FLAC; only codecs that cannot hold it do | **fixed here** (docs) |
| 3 | medium | E-AC-3 7.1 is skipped forever in MP4 and becomes FLAC (3-5x the size) in MKV; no AAC/Opus 7.1 route | task |
| 4 | medium | Lossless PCM other than s16le/s24le/f32le (Blu-ray remux LPCM) counts as a "codec change" | task |
| 5 | low | 7.1 AAC above 512k is re-encoded below its source rate | task |
| 6 | low | A 7-channel track with no layout name fails every measure | task |
| 7 | low | `--fast --allow-dynamic` on 7.1 lands ~1.7 LU over | task |
| 8 | low | `report` counts a failed file as "untouched" with no reason | note only |

### 1. 7.1 + `--allow-dynamic` / night profile: 14 dB too loud (high, fixed)

*Evidence (ebur128 read back from the output, same sine clip on every channel):*

| clip | option | target | before | after |
|---|---|---|---|---|
| 7.1 FLAC / AAC | `--allow-dynamic` | -20 | **-5.7** | -20.0 |
| 7.1 FLAC / AAC | `--profile night` | -16 | **+2.3** | -16.0 |
| 5.1 E-AC-3 / AC-3 | same | | -20.0 / -16.0 | unchanged |
| 7.1 pink noise, 18 LU range, FLAC | `--allow-dynamic` / night | -20 / -16 | -25.1 / -17.1 | -20.1 / -16.1 |
| same, AAC in MP4 | `--allow-dynamic` / night | -20 / -16 | -24.2 / not run | -19.6 / -15.8 |

*Cause.* `Measurement#with_all_channels` (the 7.1 read, 15 Nov) set `target_offset` to
`target - integrated`, the gain the linear mode needs. `FFmpegWrapper.build_loudnorm_filter` passes it as
`offset=`. loudnorm ignores `offset=` in linear mode (it works the gain out from `measured_I`) but **adds it
as extra gain in dynamic mode**, which is where `--allow-dynamic`, the night profile and any file that
does not fit linear end up. Checked directly: the same filter on the same clip with `offset=12.6` gives
-5.7 LUFS, with `offset=0.0` gives -18.3. loudnorm's own pass-1 report is about 0.02 there. Six-channel
tracks keep loudnorm's own figure, which is why 5.1 was always right. The default constant-gain path
uses the `volume` filter, not loudnorm, so it was never affected; 615c468 is not involved.

*Reach.* Any 7.1 file under `--allow-dynamic` or `--profile night` (night is one of the three named
profiles). A film at -27 LUFS under night would get +11 dB on top of loudnorm's own gain: loud, and
into the limiter. The output verification does not catch it (channel count and codec are right).

*Fix.* `target_offset` is now loudnorm's own offset plus the gap between its read and ebur128's (the side
channels' share, 1.8 LU on the clip), so a dynamic pass lands on target as ebur128 hears it. Dropped the
now-unused `target_i:` from `with_all_channels` and `read_loudness`. `CACHE_VERSION` 1.3 -> 1.4: a cached
1.3 entry for a 7.1 file holds the bad offset. Specs: `spec/seven_one_real_spec.rb` (real ffmpeg, both
options; failed before with -5.7 / -5.0, pass after) and `spec/measurement_spec.rb`.

### 2. README overstates the 7.1 conversion (medium, fixed)

README lines on "Leaves 7.1 alone" and `--allow-codec-change` said a track with more than 6 channels
"is re-encoded as FLAC" / "goes to FLAC". Run for real: 7.1 AAC (MP4, M4V, MKV), Opus (MKV, WebM, MP4),
Vorbis, FLAC (MKV) and PCM (MKV, MOV) are all levelled **in their own codec with no flag** and land at
-20.0 to -20.1 LUFS with eight channels and a `7.1` layout kept. Only a codec that cannot hold the
channels (AC-3, E-AC-3, DTS, TrueHD) is converted or skipped. Reworded both.

### 3. E-AC-3 7.1: skip in MP4, FLAC (huge) in MKV (medium, task)

*Evidence.* FLAC 7.1 in MP4 gives `Too many channels (flac with 8 channels can't be re-encoded in .mp4:
no encoder there holds more than 5.1), skipping`, in every mode, dry run included, and `report` shows
`too_many_channels=1`. The message is wrong for the general case (AAC and Opus in MP4 do hold 7.1, and
`resolve_encoder` never offers them). The E-AC-3 7.1 cases are in `spec/processor_spec.rb` (f96462a).
Only a probe fixture was possible; no real E-AC-3 7.1 file could be built.

*Why it matters.* Streaming-service rips with Dolby Digital Plus 7.1 are a normal thing to have. In MP4,
M4V, MOV and AVI they are never levelled. In MKV, with `--allow-codec-change`, a 1.0-1.5 Mbps lossy track
becomes FLAC 7.1 (the synthetic clip was 1.9 Mbps for a quiet sine; real film FLAC 7.1 is several Mbps),
so a two-hour film grows by gigabytes under `--replace`. The README does not say so, and many TV clients
cannot play multichannel FLAC without transcoding. The user is told only "eac3 would be re-encoded as flac".

*Task.* Offer a lossy 7.1 route (native AAC holds eight channels; Opus too) for lossy 7.1 sources under
`--allow-codec-change`, fix the message, and state the size cost.

### 4. Blu-ray LPCM counts as a codec change (medium, task)

`pcm_s24be` and `pcm_s32le` 7.1 in MKV: `Codec change (pcm_s24be would be re-encoded as flac), skipping
(--allow-codec-change to process anyway)`. Neither is in `ENCODABLE_CODECS` or `LOSSLESS_CODECS`; only
`pcm_s16le`, `pcm_s24le`, `pcm_f32le` (and `pcm_s16be`) are. MKV/MakeMKV remuxes carry big-endian
24-bit LPCM, so 5.1 and 7.1 Blu-ray remuxes are skipped by default for a conversion that loses nothing.
Not from 615c468 (stereo behaves the same). Needs a choice: map to `pcm_s24le`/FLAC and treat as lossless
(not a codec change), or leave it opt-in and say so in the README.

### 5. 7.1 AAC bitrate cap (low, task)

`resolve_bitrate` keys floors and caps on `channels >= 6 ? 6 : 2`, so 7.1 uses the 5.1 cap (AAC 512k).
A 641 kb/s 7.1 AAC came back at 512k, below its source, against the "+25%" promise. 7.1 AAC above 512k
is rare. Add an 8-channel key.

### 6. Unnamed 7-channel layout fails the measure (low, task)

A 7-channel AAC whose layout ffprobe reports as `unknown` (ffmpeg's own AAC 6.1 output, MKV or MP4)
fails `Measurement failed (exit 234) ... pcm_s16le Invalid argument` on every run: ebur128 in the
7.1 split read cannot map seven unnamed channels. A named `6.1` (FLAC) is fine. Evidence is synthetic;
real DTS-ES / TrueHD 6.1 normally carry `6.1`. Failure is early and cheap, not recorded, retried next run.

### 7. `--fast --allow-dynamic` on 7.1 (low, task)

Single-pass loudnorm cannot hear the side channels and has no ebur128 correction, so equal-energy 7.1
lands 1.7 LU over (-18.3 for -20). `--fast` is documented as less accurate; the README should say that
7.1 reads high under it, or the fast path should apply the same correction.

### 8. Report counts a failure as "untouched" (low, note)

`report` over 16 files: `normalised 14, untouched 2, left alone: codec_change=1`. The other untouched
file is the finding-6 failure, which has no stamp and no record, so it shows as untouched with no reason.

Steady tasks (goal 669c751d): finding 3 `66a329d3`, 4 `75675807`, 5 `2fc0bd8e`, 6 and 8 `6af476ae`, 7 `7e55eceb`.

## Checked and fine

- **Order of guards**: object audio, then channel count, then codec change; `--allow-object-audio-loss` still
  hits the channel guard in MP4. Dry run records nothing.
- **Channel counts**: 8 ch (7.1) and 7 ch (6.1) with a named layout; 6 ch stays on the old path; zero channels
  is read as 2. 6.1 DTS-ES now goes to FLAC instead of failing.
- **MP4 vs MKV**: output container is the extension, or `.mp4` for a sniffed MP4 family; MP4, M4V, MOV, WebM
  all level 7.1 AAC/Opus/PCM. MOV and AVI have no FLAC, so E-AC-3 7.1 skips there too.
- **`--ladder`**: gain, limiter and compression rungs on 7.1 FLAC and AAC (LRA 18.1 -> 12.3 / 13.9); `+convert`
  on DTS 5.1 to FLAC; `--anchor dialogue` reads the centre of a 7.1 (`c2`); `--lra-target` with
  `--centre-boost` says it skipped the boost on 7.1 and carries on. AAC lands 0.6-0.7 LU off target
  when compressed (within the 1 LU tolerance); FLAC lands on it.
- **Already stamped**: second run skips everything; with `.neutraliser` and caches deleted the in-file
  stamp alone skips every 7.1 file, MP4 and MOV included. `--redo-recipe 2 --ladder` reads the stamp,
  leaves files already within tolerance, and converts DTS under `--allow-codec-change`.
- **Other flags**: `--keep-original-audio` (7.1 original kept, not default), `--local-stage`, `--replace`.
- **Left alone is recorded**: `too_many_channels` is in `FileResult::REASONS`, the sidecar, `report` and the
  data contract; it has no top-level profile so the next run decides again.

## Not verified

- A real E-AC-3 7.1, Atmos (E-AC-3 JOC, TrueHD) or DTS:X file: not producible with ffmpeg 7.1.1. The FLAC
  output check for an eight-channel E-AC-3 source rests on the probe-fixture specs and the FLAC 7.1 runs above.
- FFmpeg 4.2 behaviour: only 7.1.1 was available locally; CI covers 4.2.2 for the suite, not for this matrix.
- Playback of any output on a real player.

## Reproducing

`evidence/mkfiles.sh` builds the files (synthetic sine and pink noise only), `evidence/runall.sh DIR "flags"`
runs `neutraliser process` over them; read back with `ffmpeg -i FILE -map 0:a -af ebur128 -f null -`.
