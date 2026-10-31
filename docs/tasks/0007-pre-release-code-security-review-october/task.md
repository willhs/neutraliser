---
id: task-0007
type: spec
purpose: "Pre-release code and security review of everything since the 2026-08-08 review; fix clear bugs with tests, write findings ranked by severity."
tags: ["review", "security", "release"]
related: ["../../research/pre-release-review-2026-11.md"]
created: 2026-11-01
updated: 2026-11-01
---

# Pre-release code and security review of neutraliser's October changes; fix clear bugs

Vision alignment: Have an online presence (goal: Release neutraliser publicly)

## Goal

The note is landed in `docs/research/` and the fixes pass specs. A stranger who clones the public
repo and points it at their library should not lose data, have commands run from a stray file, or
be told something false by the README.

## Context

The repo is public and about to be announced. The last review was on 2026-08-08, and the October
work roughly doubled `lib/neutraliser/ffmpeg_wrapper.rb` and `processor.rb`.

Premise check: confirmed. `processor.rb` is 645 lines and `ffmpeg_wrapper.rb` 914, 38 commits are
newer than 2026-08-08, and the repo is public. `a343fbbc` in the Steady notes isn't a git commit;
it is taken to be a task or job id. The review date is what scopes this work.

## Scope

### Must Do

- Review as a sceptical outside user: data-loss paths (`--replace`, swap, disk guards, interruption
  mid-run), metadata and track loss, shell or path injection from filenames, secrets or private
  paths and hostnames in the repo and its git history, README claims a stranger would disprove,
  and first-run experience from a clean clone.
- Write the findings as a short note in `docs/research/`, ranked by severity.
- Fix clear bugs, with tests.
- Describe anything that needs Will's call in the note, including anything found in git history.

### Won't Do

- Rewrite git history.
- Tag, release, post or file issues.
- Run against the real library or NAS.
- Duplicate another job: `analyze-plex` accuracy belongs to job 7a872534, so `plex_analyzer.rb`
  stays untouched here.

## Constraints

- Other jobs are changing this repo tonight: rebase rather than duplicate.
- Specs must keep working without ffmpeg installed (real-ffmpeg examples skip themselves).

## References

- Steady task: 62033285-1724-4805-8659-cfa512a4eeca
- `docs/research/prod-parity-audit-2026-10.md`
- `docs/research/library-validation-2026-08.md`

## Assumptions

- "Clear bug" means behaviour that contradicts the README or a code comment, or loses data, with a
  fix that doesn't need a product decision. Everything else goes in the note.
- Fixing a default counts as clear when the default gives a demonstrably wrong result and the
  opt-in stays available. See `--fast-verify` in the note, which Will can reverse with one line.

## Success Criteria

- [ ] `docs/research/pre-release-review-2026-11.md` lands, ranked by severity.
- [ ] Each fixed finding has a regression spec, red before the fix and green after.
- [ ] `bundle exec rspec` passes.
- [ ] The end-to-end repro script goes from failing to passing against real ffmpeg.
- [ ] Nothing in git history is rewritten; items needing Will's call are in the note.
