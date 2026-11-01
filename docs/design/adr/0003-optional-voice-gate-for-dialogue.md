---
type: adr
status: accepted
owner: will
contributors: []
updated: 2026-11-01
review_cycle: 90d
agent_write: true
links: ["docs/research/0002-streaming-loudness-and-dialogue/research.md"]
summary: "Dialogue is estimated from the centre channel with no new dependency; a Silero voice gate is an optional extra, carried as an optional gem plus a pinned model file, not built until real files show it is needed"
tags: ["dialogue", "loudness", "dependencies", "docker"]
---

# Context

`report --measure` and `rate-sample` now estimate each file's dialogue level and its loudness above dialogue (`DialogueMeter`, read-only). The method shipped is the centre channel of a 5.1 mix through the EBU R 128 measurement the tool already runs: no new dependency, error -0.7 to +3.4 LU on the research's synthetic mixes.

The research also tested a voice-activity gate: Silero VAD on the centre channel read +0.12 to +0.87 LU high (about 450x real time on one thread, no torch). It is the only tested way to get a speech share and to give stereo any figure (low confidence: +0.13 to +4.98 LU, because speech and background can't be separated by channel). All of this is synthetic; real films are untested.

# Licence check

Silero VAD is MIT. The repository's `LICENSE` file says so, and so does the README ("Published under permissive license (MIT)"). The README's first badge has the alt text "License: CC BY-NC 4.0", but its image URL is `License-MIT` and it links to the `LICENSE` file; the alt text is a stale typo. Checked 2026-11-01 against `raw.githubusercontent.com/snakers4/silero-vad/master`. Bundling or downloading the model is allowed; keep the copyright notice with it.

# Options for carrying it

| Option | Ruby CLI | Docker image | Verdict |
|---|---|---|---|
| Hard gemspec dependency on `onnxruntime` | Every install gets a native library (tens of MB, per platform) | Always present | Rejected. It breaks "needs only FFmpeg" for a method that is not the default and is unvalidated |
| **Optional gem, loaded on use** (`onnxruntime` by Andrew Kane, MIT; model file separate) | `gem install onnxruntime`, then `--dialogue-method vad`; without it the flag says what to install | A build argument (`--build-arg WITH_VAD=1`) adds the gem and downloads the pinned model | **Chosen** |
| Python helper (`silero-vad` plus `onnxruntime` from pip) | Needs Python and a venv next to Ruby | Doubles the runtime | Rejected |
| Vendor the ONNX model in the gem | One file (about 2 MB) in every install | Always present | Rejected: weight for everyone, and a pinned download with a checksum does the same job |

# Decision

1. The zero-dependency centre-channel estimate stays the default and the only method until the validation task (Steady `3da9b750`) has run on real files. If it is close enough there, the gate is never built.
2. If the gate is built, it is carried as the optional-gem row above: `require 'onnxruntime'` inside the gate only, the model downloaded to a cache directory with a pinned SHA-256 (no network at run time), the Docker image variant built with `WITH_VAD=1`. The default image is unchanged.
3. The gate adds a second `DialogueEstimate` method (`centre_channel_vad`, with `speech_share`) next to `centre_channel`; the existing figure is kept, never replaced, so the two can be compared. Stereo, if it gets a figure, is `confidence: :low`.
4. Songs are the likely failure (Silero's speech precision on French music radio was 23.9% in a published test). Gate on the centre channel only, and judge it on real files with a dialnorm to check against before trusting it.

# Consequences

- `speech_share` exists on `DialogueEstimate` and is nil for `centre_channel`: the centre-channel method cannot say how much of a file is speech, and the figure is shown as absent rather than guessed.
- The research's "-24 whole-programme fallback when under 15% of the file is dialogue" needs a speech share, so it cannot be judged until the gate exists. The dialogue-anchored rate uses the -27 dialogue target alone.
- Stereo and mono files get no dialogue figure and are counted as not judged.
