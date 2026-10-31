---
id: plan-0007
type: spec
purpose: "Fix plan for the pre-release review: reproduction first, then fix phases planned from that evidence."
tags: ["plan", "review", "security"]
related: ["./task.md", "../../research/pre-release-review-2026-11.md"]
---

# Pre-release review fixes: implementation plan

Vision alignment: Have an online presence

## Overview

**Primary goal**: every confirmed clear bug has a regression spec and a fix, and the rest is in the
research note for Will.

**Approach**: bug playbook at size L. Phase 1 reproduces each suspected bug on the unfixed commit
with the real CLI and ffmpeg over synthetic media. The fix phases are planned from what that showed.

## Current State Analysis

Artifact check:

- Spec quality: full research, because the task is a review and its findings define the scope.
- Existing tests: Phase 0 omitted (non-Python repo). 340 examples, 0 failures at `c52f50c`.
- Existing research: reference `prod-parity-audit-2026-10.md` (row 26 records that production will
  pass `--no-fast-verify`).
- Changed behaviour: `--fast-verify` default, resume finality, sidecar marking and temp-file naming
  all change. The `why` for each is in `decisions.tsv` and the note.

### Key discoveries (all reproduced at `c52f50c`)

- `lib/neutraliser.rb:6` `require 'dotenv/load'` runs `$(...)` from any `.env` in the working
  directory, and exports everything else into ffmpeg's environment.
- `ffmpeg_wrapper.rb:851` never maps `0:t`, so MKV attachments vanish under `--replace`, and
  `file_manager.rb:103` doesn't notice.
- `ffmpeg_wrapper.rb:512` has no cleanup for an exception raised outside the timeout path, so
  SIGTERM blocks in Open3's `wait_thr.join` while ffmpeg keeps running.
- `processor.rb:170` treats any `done`/`skipped` as final, so dry-run and low-disk records end a
  file's processing for good. `processor.rb:307` marks files processed that weren't.
- `cache_manager.rb:43` only compares mtimes, so a swapped file or a same-basename twin gets another
  file's measurement.
- `processor.rb:592`, `report.rb:64` and `cli.rb:35` glob a literal path.

## Desired End State

`ruby evidence/scripts/repro.rb <worktree>` reports all cases passing, specs are green, and the note
is committed.

Core data shapes:

- **File outcome**: `file_result` `{file, status, reason, message, normalization_type}`. Invariant:
  a record (sidecar or manifest) may only say "finished" about the file that actually holds the
  result, and only for a verdict the current options would reach again. `RESUME_FINAL_REASONS` lists
  the final reasons; anything else falls through to `SkipDecider`, which costs one probe.
- **Stream inventory**: `{video, audio, subtitle, attachment, chapter}` counts from ffprobe.
  Invariant: output equals source, except audio may gain the kept original, and the primary track
  keeps its channel count.
- **Source fingerprint**: size and mtime taken before any work. Invariant: nothing is published if
  the source has changed since.

## What We're NOT Doing

- Rewriting history, or removing `check-prod` or the private strings in `docs/log.md` (Will's call).
- Changing `plex_analyzer.rb` (job 7a872534 is in it).
- Changing disk-floor semantics, or preserving hard links on `--replace` (note only).

## Assumptions

- `--fast-verify` flips to off by default. A 30 s sample recorded a -29.2 LUFS film as finished, and
  `--no-fast-verify` couldn't undo that afterwards. Production already opts out. Reversible with one
  line and flagged in the note.
- `--dry-run` keeps writing analysis caches, since re-measuring costs about 20 minutes per film, and
  stops writing the run manifest. The README now says this rather than "write nothing".
- `.env` is parsed by a small reader limited to `PLEX_TOKEN` and `PLEX_SERVER_URL`, read only by
  `analyze-plex`. `dotenv` is dropped because its parser runs `$(...)` even through `Dotenv.parse`.
- Temp outputs are dot-prefixed so media scanners ignore them. Leftovers get a warning and are never
  auto-deleted, because a concurrent run could own one.
- A symlinked file under `--replace` is replaced at its real location, keeping the link.
- A 7.1 track through a 5.1-only encoder fails verification rather than picking another codec.
- `--target-level` names its profile from the target (`custom-18`) so that a different target isn't
  "already processed". No released version wrote the old `custom` tag.
- `plex-ruby` and `nokogiri` are removed if the lockfile can be regenerated. Nothing requires them.

---

## Phase 1: Reproduce and diagnose

- [x] Read every file in `lib/`, the README, packaging and CI.
- [x] Drive each suspect with the real CLI over synthetic media: `evidence/scripts/repro.rb`.
- [x] Check history and tree for secrets with values masked.
- [x] Clean-clone install, gem build, Docker build, `docker stop`, `--user`, invalid UTF-8 names.
- [x] Record refuted hypotheses in `decisions.tsv`.

### Success Criteria

- [x] Run: `ruby evidence/scripts/repro.rb /tmp/nr/clean` — 26 failed, 1 passed at `c52f50c`
  (`evidence/repro-before.txt`).

---

## Phase 2: Failing regression specs first

- [x] Add `spec/pre_release_review_spec.rb` (real ffmpeg, skips without it) with one example per
  finding, driving `Processor` or the real binary and asserting what the user would observe.
- [x] Add unit examples for what synthetic media can't reach on APFS: invalid UTF-8 keys, `df` output
  with a space in the device name.

### Success Criteria

- [x] Run: `bundle exec rspec spec/pre_release_review_spec.rb` — red, each example failing for the
  expected reason. Commit the red specs on their own.

---

## Phase 3: Security and first run

- [x] Replace `dotenv` with `PlexEnv`, called only from `analyze-plex`.
- [x] `Logger`: file logging is best effort (unwritable or missing `HOME`, full disk).
- [x] `VideoFiles.under`: literal directory walk for `process`, `report`, `cache clean`; `cache_stats`
  and `cleanup_stale_cache` stop globbing paths.
- [x] `Processor#process` and `Report` use absolute paths, so ffmpeg never reads a name as a protocol.
- [x] Unreadable file fails (`unreadable`) rather than "No audio track".
- [x] Preflight: a missing ffmpeg gives one error, and ffmpeg older than 7.1 warns that object audio
  can't be detected.
- [x] Narrow the CLI's `rescue ArgumentError` to option validation; `--lock-file` open errors are one line.
- [x] Staging directory is created `0700` and must be owned by the user.

### Success Criteria

- [x] Run: `bundle exec rspec spec/pre_release_review_spec.rb -e security -e first-run` — green.
  Ran as part of the full suite after Phase 6, not filtered per phase. The phases landed together in
  one commit rather than one each.

---

## Phase 4: Data safety

- [x] `execute_with_timeout` always stops its child in `ensure`; the timeout hint names the right variable.
- [x] CLI turns a signal into one line and exit `128 + signo`.
- [x] `safe_temp_path` dot-prefixes; `render_normalization` always writes a temp and publishes by rename.
- [x] Leftover temps are warned about, and `_normalized` copies with a sibling source aren't scanned.
- [x] Symlink targets: temp beside the real file, rename over the real file; preflight checks that dir.
- [x] Source fingerprint before work, re-checked before publish (`source_changed`).
- [x] Map `0:t?`, its metadata and every primary disposition flag; map `0:v?`.
- [x] `output_mismatch` compares the stream inventory, chapters and primary channels.
- [x] Restamp writes to the primary track's index.

### Success Criteria

- [x] Run: `bundle exec rspec spec/pre_release_review_spec.rb -e 'data safety'` — green, as part of
  the full suite.

---

## Phase 5: Records tell the truth

- [x] Resume: `RESUME_FINAL_REASONS`, same profile, target and replace mode; per-file manifest
  writes; none in a dry run.
- [x] Sidecar: copy-mode records the output, peak-limited isn't recorded, within-tolerance records
  its tolerance.
- [x] `custom_profile` names from target and inherits the chosen profile's settings.
- [x] Cache validated by file name, size and mtime.
- [x] `Measurement#silent?`; silent tracks skipped with reason `silent`.
- [x] `--fast-verify` default off.

### Success Criteria

- [x] Run: `bundle exec rspec spec/pre_release_review_spec.rb -e records` — green, as part of the
  full suite.

---

## Phase 6: Per-file isolation and small fixes

- [x] Any per-file exception becomes that file's failure; only `DiskGuard::Abort` ends a run.
- [x] Subprocess output scrubbed to valid UTF-8; sidecar, manifest and cache keys scrubbed.
- [x] `DiskGuard` parses `df` from the numeric columns.

### Success Criteria

- [x] Run: `bundle exec rspec` — green.
- [x] Run: `ruby evidence/scripts/repro.rb <worktree>` — all pass (`evidence/repro-after.txt`).
- [x] Docker: `docker stop` exits 143 with no temp; `--user 1000:1000` runs; a Latin-1 name doesn't
  stop the run; older ffmpeg result recorded for the README claim (5.1 passes; 4.2 could not be
  built, so the README now claims only 5.1 and 7.1).

---

## Phase 7: Docs and note

- [x] Write `docs/research/pre-release-review-2026-11.md`, ranked by severity.
- [x] Correct README claims; update `CHANGELOG.md`, `data_contracts.md`, `architecture.md`,
  `AGENTS.md`, `docs/index.md`, `docs/log.md`.

---

## Phase 8: Wrap (commit & finalize)

- [x] Run: `git status` — note unstaged and untracked files.
- [x] Commit (in a Manager job this only commits: no merge, no push).

### Success Criteria

- [x] Run: `git status` — `nothing to commit, working tree clean`.

---

## Final Checklist

- [x] All phases complete.
- [x] Documentation updated.
- [x] Nothing written outside the worktree except `evidence/`.

## Documentation Updates

- [x] `docs/research/pre-release-review-2026-11.md` (new), with `docs/index.md` and `docs/log.md`.

## References

- Task: `docs/tasks/0007-pre-release-code-security-review-october/task.md`
- Research: `docs/research/prod-parity-audit-2026-10.md` (2026-10-20)
