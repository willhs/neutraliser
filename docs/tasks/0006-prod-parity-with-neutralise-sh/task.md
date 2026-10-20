---
created: 2026-10-20
updated: 2026-10-20
---

# Prod parity with media-server's neutralise.sh

Vision alignment: "Production runs the neutraliser CLI, not a forked shell script" (goal), and the least-lossy vision in `docs/philosophy/vision.md`.

## Goal

Everything the NAS depends on in `media-server/scripts/neutralise.sh` is either in the CLI, ported here, or consciously dropped, so the driver can switch to the CLI. The behaviour-by-behaviour verdicts are in [the audit](../../research/prod-parity-audit-2026-10.md); this spec covers the items marked **port**.

## Requirements

Each requirement has a spec that names it (`spec/*_spec.rb`).

### R1 Peak-capped files are only re-encoded when it helps
- R1.1 A file far from target is skipped (`peak_limited`) unless the peak-capped gain moves it **towards** target by at least `--min-gain` dB. A quiet file whose peaks sit over the ceiling (gain would be negative) is never re-encoded. (`gain_plan_spec`, `processor_spec`)
- R1.2 `--min-gain` defaults to `--tolerance`; setting it lower (prod: `--tolerance 2 --min-gain 1`) re-encodes smaller capped gains.

### R2 Opt-in peak limiter
- R2.1 `--limit-db N` (default 0 = off) lets gain exceed the true-peak headroom by up to N dB; an `alimiter` (limit TP−0.5 dB, attack 5, release 50, latency 1) holds the peaks. (`gain_plan_spec`)
- R2.2 Such files are stamped `NEUTRALISER_MODE=limited`, counted as `limited` in the run summary and `report`, and logged with a note. (`processor_spec`, `report_spec`)
- R2.3 It cannot be combined with `--allow-dynamic`, `--fast` or the night profile. (`processor_spec`)

### R3 Track choice
- R3.1 The primary track is the default-disposition track, else the first `eng` track, else the first. (`ffmpeg_wrapper_spec`)

### R4 Codec changes are opt-in
- R4.1 A file whose primary codec cannot be re-encoded to itself in its container (DTS, TrueHD, FLAC in MP4 ...) is skipped before measuring with reason `codec_change`, unless `--allow-codec-change`. Not stamped in the sidecar. (`ffmpeg_wrapper_spec`, `processor_spec`)

### R5 Container is what the bytes say
- R5.1 MP4 data in a file named `.mkv` (or any non-MP4 name) is encoded with the MP4 codec table and `-f mp4`, so `mov_text` subtitles copy and tags are written. (`ffmpeg_wrapper_spec`, real-ffmpeg example)

### R6 Output must match the source before it replaces it
- R6.1 Duration within 1 s of the source and the expected audio stream count (source count, +1 with `--keep-original-audio` unless already kept), else `output_verification_failed` and the original is untouched. (`file_manager_spec`, `processor_spec`)

### R7 Disk floors
- R7.1 `--min-free-gb N`: below N GiB free, or less than the file's size, on the output folder's volume, skip the file (`low_disk`) and carry on. Nothing is recorded, so a later run retries.
- R7.2 `--abort-free-gb N`: below N GiB free, stop the run; exit code 4. Files done so far are kept.
- R7.3 Neither applies to a dry run. (`disk_guard_spec`, `processor_spec`, `cli_spec`)

### R8 One run at a time
- R8.1 `--lock-file PATH` holds an `flock` for the run; if another run holds it, exit 3 without processing. The kernel drops the lock if the holder dies. (`run_lock_spec`, `cli_spec`)

### R9 Replaced files keep their owner
- R9.1 `atomic_replace` and `atomic_copy` give the new file the original's uid/gid when permitted (best effort, in addition to the mode). (`file_manager_spec`)

### R10 Shell history carries over
- R10.1 `neutraliser import-manifest MANIFEST --root DIR` writes a `.neutraliser` sidecar entry beside each file whose last manifest entry is `done`, `skip_tol` or `skip_tp_capped` and whose size and mtime still match. Other statuses and changed files are counted and left alone; `--trust-legacy` also accepts entries without size/mtime; `--dry-run` writes nothing. (`manifest_import_spec`)
- R10.2 A sidecar in a file's own folder counts for a run started anywhere above it. (`skip_decider_spec`)

## Out of scope (follow-up tasks)
- The Docker image (ruby + ffmpeg, `TMPDIR`, timeouts).
- The media-server driver switch, running `import-manifest` on the NAS, and deleting `neutralise.sh`.
