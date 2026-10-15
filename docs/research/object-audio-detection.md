---
type: note
status: active
owner: will
contributors: []
updated: 2026-10-15
review_cycle: 90d
agent_write: false
links: []
summary: "How to detect Dolby Atmos (E-AC3 JOC, TrueHD) and DTS:X with ffprobe, and why neutraliser skips them by default"
tags: [research, codec, quality]
---

# Detecting object audio (Atmos / DTS:X) with ffprobe

## Question

ffmpeg cannot encode Atmos or DTS:X object metadata. Re-encoding a track like
that flattens it: E-AC3 JOC (DDP Atmos) becomes plain 5.1, TrueHD Atmos or
DTS:X becomes plain FLAC. How do we tell, reliably and cheaply, that a primary
track carries object audio so we can skip it?

## Findings

**1. FFmpeg 7.1+ names the profiles.** libavcodec has
`"Dolby Digital Plus + Dolby Atmos"`, `"Dolby TrueHD + Dolby Atmos"`,
`"DTS-HD MA + DTS:X"` and `"DTS-HD MA + DTS:X IMAX"`. They show up as the
stream `profile` in `ffprobe -show_entries stream=profile`. Checked in the
local Homebrew build (7.1.1, `strings libavcodec.61.dylib`).

**2. The decoder sets them, not the demuxer.** In the 7.1 source:

| Format | Where it's set | Signal |
|---|---|---|
| E-AC3 JOC | `libavcodec/ac3dec.c` (after a frame decodes cleanly) | `flag_ec3_extension_type_a`, the LSB of the first `addbsi` byte (parsed in `eac3dec.c`) |
| TrueHD Atmos | `libavcodec/mlpdec.c` | major-sync substream info |
| DTS:X | `libavcodec/dca_xll.c` | X / X-IMAX sync words in the XLL extension |

ffprobe prints `codecpar->profile` (`fftools/ffprobe.c`). That value is
copied from the decoder context that `avformat_find_stream_info` uses to
decode the first frame(s). So the profile is only as good as the frames
decoded during probing. `-count_frames` and `-read_intervals` don't help:
they decode into ffprobe's own context and never update `codecpar`. The DTS
*parser* also sets a profile, but only up to `DTS-HD MA`. The X variants need
the decoder.

**3. A plain E-AC3 profile reads `unknown`.** Plain DDP has no named profile.
That makes `unknown` ambiguous for E-AC3: it can mean plain 5.1, or Atmos
whose JOC flag wasn't seen in the frames ffprobe decoded. This fits the
observation in the task, where a DDP Atmos file probed from only its first
30MB reported `profile=unknown`.

**4. Tests on FFmpeg FATE samples** (fate-suite.ffmpeg.org):

| Sample | `profile` |
|---|---|
| `truehd/atmos.thd` (raw, remuxed to MKV, and with `-probesize 32`) | `Dolby TrueHD + Dolby Atmos` |
| a 5s stream-copied slice of it in `.mka` | `Dolby TrueHD + Dolby Atmos` |
| the same track re-encoded to FLAC | `unknown`: the loss is real |
| `dts/master_audio_7.1_24bit.dts` | `DTS-HD MA` (correct negative) |
| `eac3/csi_miami_5.1_256_spx_small.eac3` | `unknown` (plain DDP) |

FATE has no E-AC3 JOC or DTS:X sample, and we didn't find a small, freely
licensed one. Positive detection for those two formats is therefore only
covered by specs with mocked ffprobe output, plus reading the FFmpeg source
above. It has not been tested on a real file.

## Approach taken

1. **Primary:** the existing `detect_audio_tracks` probe now asks for
   `stream=profile` (and `stream_tags=title`), so this costs no extra
   subprocess. A profile matching `/atmos|dts:x/i` means object audio.
2. **Second opinion, triggered by a name hint:** say the codec could carry
   objects (`eac3`, `truehd`, `dts`) but the profile doesn't name them, while
   the file name or track title says Atmos / JOC / DTS:X. Then
   `probe_audio_profile_mid_file` stream-copies 10s from the middle of the
   file into a scratch `.mka` and probes that. This decodes different frames
   from the ones the opening probe saw. If that slice names an object
   profile, it counts as object audio.
3. **The name is never the only signal.** Hinted but unconfirmed is logged as
   a note, and the file is processed.

Object audio is skipped (`status: skipped`, `reason: object_audio`, with the
profile in the manifest message). The skip isn't stamped in the `.neutraliser`
sidecar, and `--resume --allow-object-audio-loss` picks these files back up.
`--allow-object-audio-loss` processes them anyway, with a warning. The
codec-decision log line now shows the source profile, e.g.
`Audio: truehd (Dolby TrueHD + Dolby Atmos) 2866k -> flac (lossless)`.

## Alternatives considered

| Option | Verdict |
|---|---|
| Stream `profile` only | Cheap, but `unknown` on E-AC3 is ambiguous (finding 3) |
| Profile + name-hinted mid-file probe (chosen) | Cheap for most files. The extra probe runs only where a miss is likely |
| Parse E-AC3 BSI / `addbsi` ourselves | Doesn't depend on the decoder, but it's a bitstream parser we can't test against a real JOC sample. It also only covers one of the three formats |
| Skip on filename alone | Rejected by the task: names lie both ways |

## Open

- Confirm on a real DDP Atmos file (e.g. the NAS `tv/Severance/Season 2/*DDP5.1.Atmos*`)
  that the plain probe reports the Atmos profile with FFmpeg 7.1. If it
  doesn't, check that the mid-file probe catches it.
- Needs FFmpeg 7.1+ on the host. Older ffprobe reports no object profiles, so
  only the name-hinted note would fire.
