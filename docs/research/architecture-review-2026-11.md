---
type: note
status: active
owner: will
contributors: []
updated: 2026-11-01
review_cycle: 90d
agent_write: false
links: ["docs/design/architecture.md", "docs/design/adr/0001-smart-codec-selection.md"]
summary: "Architecture review after the October feature burst: four shallow modules worth deepening in FFmpegWrapper and Processor, each filed as a Steady task, and what was checked and left alone"
tags: [research, architecture, refactor]
---

# Architecture review, 2026-11

**Verdict: four modules are worth deepening, each filed as a Steady task. Nothing here blocks release.**
The October modules (Stamp, GainPlan, ObjectAudio, DiskGuard, RunLock, ManifestImport) came out fine: they
are small and deep. The problem is the two files they plug into. `FFmpegWrapper` (1003 lines, up from 914
when the task was written) and `Processor` (776, up from 644) kept absorbing each new guard, and the facts
they share are asked for again at every call site.

Confidence tags: **[verified]** I ran it. **[read]** from source only.

## Premise check

- The line counts in the task were stale: 1003 and 776 now, after the pre-release review fixes. **[verified]** `wc -l`.
- "In the glossary's terms" could not be done literally: `docs/philosophy/glossary.md` is still the
  create-project placeholder (no terms). I used the component names in `docs/design/architecture.md`
  and `AGENTS.md` (Processor, SkipDecider, Stamp, GainPlan, FFmpegWrapper, the "Pipeline", "primary track"),
  plus the review vocabulary (module, interface, depth, seam). The new terms below (**Remux plan**,
  **Source**, **Codec choice**, **Guards**) are proposals; if one is accepted it should go into the glossary.
- "Mixes probing, track choice, codec tables, command building and stamping": true, and also
  subprocess running (`execute_with_timeout`, ~100 lines) and loudness measurement. **[read]**
- Nothing in the four commits since the task was written (7a2ff46, 18f1892, b73347b, f983416) did this
  review's work. They added to both files.

## How I looked

Hot spots from `git log --since=2026-08-08 --name-only`: `processor.rb` and `ffmpeg_wrapper.rb` (17 and 15
commits) are the only library files changed that often, followed by `cli.rb` (12) and `skip_decider.rb` (8).
Then, for each candidate, the deletion test and a count of how many callers know the detail.

Two runs settled facts that reading could not:

1. **ffprobe calls per file.** A shim on `PATH` logged every ffprobe/ffmpeg call during
   `neutraliser process --replace` on a generated 2-audio-track mkv (one video, eng default + spa, ac3).
   **[verified]**. To reproduce: put two `#!/bin/sh` scripts named `ffprobe` and `ffmpeg` first on `PATH`
   that append `"$0 $*"` to a log and `exec` the real binary, then run
   `bundle exec bin/neutraliser process DIR --replace --no-cache` on a one-file DIR:

   | Fact asked | Times | Where |
   |---|---|---|
   | Audio tracks | 3 (source x2, output x1) | `Processor#process_file`, then `AudioAnalyser` via `primary_audio_index`; the output in `FileManager.output_mismatch` |
   | NEUTRALISER stamp | 2 (both on the source) | `Processor#already_handled?`, then again inside `AudioAnalyser` via `SkipDecider.skip?` |
   | Container name | 2 | `codec_change` guard, then `apply_normalization` |
   | Stream counts | 3 (source x2, output x1) | `apply_normalization`, then `FileManager.lost_streams` |
   | Duration | 3 (output x2, source x1) | `verify_file_integrity`, then `output_mismatch` |
   | Subtitle support | 1 | `Processor#check_subtitles` |
   | The `FFMPEG::Movie` gem's own probe | 1 | `Processor#process_file` |

   15 ffprobe calls (plus one `-version` each for ffprobe and ffmpeg) and 2 ffmpeg runs (measure, encode)
   for one file. Of the source-side calls, none returns a different answer from the one before it.
   On a NAS each one opens the file over SMB.

2. **The default that disables metadata mapping.** `build_complete_ffmpeg_command(..., stream_counts = { video: 0, subtitle: 0 })`.
   Called without counts it emits no `-map_metadata:s:v/s/t` pairs; with counts it emits them.
   **[verified]** (`send(:build_complete_ffmpeg_command, ...)` with and without the argument: `[]` against
   `["-map_metadata:s:v:0", "-map_metadata:s:s:0", "-map_metadata:s:t:0"]`). Every production caller passes counts today, so this is
   a trap rather than a live bug, but it is the exact mistake behind the metadata-loss bug class
   (`b4c371e`), and the signature invites it.

## Candidates

Ranked. Dependency category per `improve-architecture`'s DEEPENING guide.

### 1. Remux plan: who owns the output audio layout. **Strong.** Task `0860afcd` (M)

- **Files**: `ffmpeg_wrapper.rb` (`build_complete_ffmpeg_command`, `output_audio_count`, `apply_normalization`,
  `apply_normalization_single_pass`, `restamp`), `file_manager.rb` (`output_mismatch`, `channel_change`).
- **Problem**: The question "which output audio stream is the normalised one, which is the kept original,
  which is copied, and what must the output look like" is answered in three places. The command builder
  walks the tracks and computes output indexes. `output_audio_count` re-derives the keep-original rule
  (`keep_original && none original_copy?`, a line also at ffmpeg_wrapper.rb:880). `FileManager.channel_change`
  assumes the primary keeps its index. The builder takes 9 positional arguments and four near-identical loops
  for `-map_metadata:s:{a,v,s,t}`. The two `apply_*` methods repeat a 15-line prelude. **[read]**
- **Solution**: one module that takes the source facts, filter, codec decision, stamp and `keep_original`, and
  produces both the argv and the expected output shape. Verification compares the output against the plan.
- **Benefit**: locality for the bug class the task's *Why* names. A metadata mapping fix, or a new track
  role, is one change. The driver switch and the golden round trip (`spec/round_trip_spec.rb`) lean on
  this. Leverage: callers stop knowing about output indexes.
- **Dependencies**: in-process, pure computation. Safe to deepen. Test at the new interface on argv and
  expected shape; the real-ffmpeg round trip stays as the integration check.
- **Risk**: the argv order matters to ffmpeg (stamp tags come after the explicit mappings). The task says
  to keep the round trip unchanged and green.

### 2. Source: ask ffprobe once per file. **Strong.** Task `fb62003d` (M)

- **Files**: `ffmpeg_wrapper.rb` (10 ffprobe call sites), `processor.rb`, `audio_analyser.rb`,
  `skip_decider.rb`, `file_manager.rb`, `object_audio.rb`.
- **Problem**: Facts about one file are fetched ad hoc by whoever needs them (table above). The result is a
  loose `Hash` per track whose keys are read all over (`:index` 13 reads, `:codec` 6, `:channels` 5);
  `primary_audio_track` is recomputed at 10 call sites; the `UNKNOWN_AUDIO_TRACK` sentinel is tested by
  `[:unknown]` in 4 places. A failed best-effort probe means different things per call: `NO_STREAMS`,
  `[]`, `nil`, `false`. **[read]**, counts from `grep`.
- **Solution**: a Source value built from one probe pass (tracks, primary, stream counts, container,
  attached picture, stamp, subtitle support), handed to the guards, the plan and the skip decision. The
  output gets its own fresh Source after writing, since verification must not trust the source's numbers.
- **Benefit**: fewer subprocesses per NAS file; one place decides the primary track and what "unknown"
  means; specs stop stubbing `detect_audio_tracks` (11 stubs in `processor_spec.rb`).
- **Dependencies**: local-substitutable. ffprobe JSON fixtures stand in for the real thing; keep one
  real-ffprobe spec. Beware the stand-in hiding ffprobe quirks (`bit_rate` "N/A", `profile` "unknown").
- **Order**: after candidate 1 is cleaner but not blocked by it; the track hash is the seam.

### 3. Codec choice: one public interface. **Strong (small).** Task `4f0038b5` (S)

- **Files**: `ffmpeg_wrapper.rb` (the six codec tables, `select_output_codec`, `resolve_encoder`,
  `resolve_bitrate`, `estimate_source_bitrate`, `codec_change`).
- **Problem**: The codec policy has no public interface. It is reached through the private
  `select_output_codec`, which 19 specs call with `send`. The one public entry, `codec_change`, re-derives
  the first half of that method (container, allowed set, `channels.zero? ? 2`, `resolve_encoder`), so the
  codec-change guard and the actual encode could disagree. **[read]**
- **Solution**: a Codec choice module: (track, container) in, decision out, including "this changes the codec".
  Both the guard and the encode call it.
- **Benefit**: one decision, not two; tests assert the decision through a public interface instead of
  `send`; roughly 200 lines of tables and rules leave FFmpegWrapper.
- **Dependencies**: in-process apart from bitrate estimation, which becomes an input.
- **ADR**: keeps ADR-0001's decision; moves it. No conflict.

### 4. The per-file outcome: Guards, FileResult, Mode. **Worth exploring.** Task `1c585044` (M)

- **Files**: `processor.rb`, `gain_plan.rb`, `stamp.rb`, `report.rb`.
- **Problem**: Processor holds 21 instance variables (the option bag) and runs five pre-encode guards
  inline (`check_writable`, `check_disk_space`, `check_subtitles`, `check_object_audio`,
  `check_codec_change`), each with its own policy flag, log line and reason. `process_file` ends in a
  six-clause rescue ladder. `processor_spec.rb` stubs Processor's own private methods
  (`analyze_loudness_for_path` x25, `normalize_file_with_paths` x9, `commit_output`), so it pins the
  construction, not the behaviour. The normalisation mode is spelled `'linear'` in Stamp, GainPlan and
  Report and `'Linear'` in the wrapper and Processor (bridged with `capitalize`/`downcase`);
  `RESUME_FINAL_REASONS` holds strings while results carry symbols. **[read]**
- **Solution**: a Guards sequence that returns the first verdict (skip, fail or proceed, with reason and
  message) and leaves logging and recording to Processor; one FileResult and one Mode type.
- **Benefit**: each guard is testable alone; adding the next guard is one entry; reasons and modes have
  one spelling.
- **Why only "worth exploring"**: the guards are individually simple and the current shape works. The gain
  is in tests and the next guard, not in a bug class. Do it after candidate 2, since guards take its facts.
- **Constraint**: the reason strings are written to run manifests that `--resume` reads across versions;
  they must not change.

## Considered and left alone

| Module | Why not |
|---|---|
| `Stamp`, `GainPlan`, `ObjectAudio` (46 to 59 lines each) | Small interface, real logic behind it. Deep. |
| `DiskGuard`, `RunLock`, `ManifestImport` | Each owns one concept with a 3 to 5 method interface. |
| Run manifest and resume code inside Processor (~100 lines) | Extracting it moves lines but the interface stays about as wide as the code (`record`, `terminal?`, summary). No second consumer: `ManifestImport` reads the retired shell manifest, a different format. Revisit if a second reader appears. |
| Subprocess runner in `FFmpegWrapper` (`execute_with_timeout`, `stop_process`, ...) | A seam only if tests want a fake runner. They currently stub above it. One adapter is a hypothetical seam. |
| `PlexAnalyzer` (493 lines) | Not changed in this burst's hot path; a separate feature with its own estimate model. |
| `CLI` (311 lines, 12 commits) | Thor option plumbing; its churn is options, not logic. |

## Suggested order

1 (Remux plan), then 2 (Source), then 4 (Guards); 3 (Codec choice) is independent and small, take it
whenever. Each task states its own done check. None is a prerequisite for release.

## Not verified

- Per-file ffprobe cost on the real NAS: I counted calls on a local clip, not time over SMB.
- Whether `FFMPEG::Movie` (the streamio-ffmpeg gem) could be dropped once Source exists. Its probe is
  one of the 15; removing it changes the `no_audio_track` / `unreadable` decisions and needs its own look.

### Change Log
- 2026-11-01 (agent:architecture-review): Created
