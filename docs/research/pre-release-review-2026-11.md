---
type: note
status: active
owner: will
contributors: []
updated: 2026-11-01
review_cycle: 90d
agent_write: false
links: ["docs/tasks/0007-pre-release-code-security-review-october/task.md"]
summary: "Pre-release code and security review of everything since 2026-08-08: findings ranked by severity, what was fixed, what needs Will's call"
tags: [research, security, release, review]
---

# Pre-release review, 2026-11

**Verdict: wait to announce until you've decided items 1 and 2 under "Needs Will's call".** The code
problems below are fixed with regression specs. What's left is about what the public repo shows,
and no code change can settle that.

I reviewed everything since 2026-08-08 as a stranger would, driving the real CLI and real ffmpeg
over synthetic media. No real library, NAS or Plex server was touched. Commit `c52f50c` failed 26 of
27 end-to-end cases; the fixed tree passes all 27.

Confidence tags: **[verified]** I ran it. **[read]** from source only.

## Fixed

Ranked by severity. All **[verified]** before and after, each with a spec in
`spec/pre_release_review_spec.rb`.

### Critical

| # | Finding | Fix |
|---|---|---|
| 1 | **A `.env` in the working directory ran shell commands at startup.** `dotenv/load` runs `$(...)` in values and exports every key, so `cd Some.Download && neutraliser .` executed whatever a `.env` in that folder said. `FFREPORT` from the same file also made ffmpeg write to any path, and `LD_PRELOAD` would reach it the same way. Every command was affected, including `version`. | `dotenv` removed. `analyze-plex` alone reads `PLEX_TOKEN` and `PLEX_SERVER_URL`, as literal text (`PlexEnv`). |

### High: data loss

| # | Finding | Fix |
|---|---|---|
| 2 | **`--replace` lost MKV attachments**, usually the fonts styled subtitles need, and reported success. | Mapped, with their metadata. |
| 3 | **`--replace` lost MP4 cover art and iTunes tags**, and reported success. `use_metadata_tags`, needed for the stamp, writes `mdta` keys instead of the iTunes atoms. | A file with a cover or descriptive tags keeps its atoms; the sidecar holds its record. See "Needs Will's call", item 4. |
| 4 | **`--replace` overwrote a file still being written.** Bytes appended during the encode were gone, and the README recommends running this from cron. | Size and mtime taken before any work and compared before publishing. Fails with `source_changed`. |
| 5 | **SIGTERM hung while ffmpeg ran on.** Ruby waited on an ffmpeg that ignores SIGPIPE. `docker stop` took 11 s, ended in SIGKILL (exit 137) and orphaned the temp file. | The child is stopped in `ensure`. `docker stop` now takes 1 s, exits 143 and leaves no temp. |
| 6 | **A leftover temp was then processed as a film.** During every encode it also sat in the library under a normal video name, where a scanner could find it. | Temps are hidden, never scanned, and listed as a warning. They aren't auto-deleted, because a concurrent run could own one. |
| 7 | **Copy mode wrote straight to the final name**, despite the README's "atomically". A failed encode deleted an earlier `_normalized` file. | Always a temp, then a rename once verified. |
| 8 | **Verification missed lost streams and downmixes.** It compared duration and audio count only, and ffmpeg sending 7.1 through E-AC3 or AC3 comes out with fewer channels and exit 0. | Now compares every stream type, chapters and the primary track's channels. Checked against 18 container and codec combinations for false rejections: none. |
| 9 | **`--replace` through a symlink replaced the link** with a separate copy and left the real file untouched. This library uses such links (`docs/log.md`). | Temp goes beside the real file, which is what gets replaced. |

### High: silently wrong results

| # | Finding | Fix |
|---|---|---|
| 10 | **A 30-second sample could record a film as finished.** Default flags logged a -29.2 LUFS film as "Already at target level (-20.0 LUFS...)", and `--no-fast-verify` couldn't undo it. | `--fast-verify` is off by default, and the log no longer invents a level. See "Needs Will's call", item 3. |
| 11 | **A stale measurement gave the wrong gain, permanently.** The cache only compared mtimes, so a swapped file with an older date (an *arr upgrade can keep the release's) and `same.mp4` beside `same.mkv` both got another file's figure: -51.8 measured, -31.8 true. | Validated by file name, size and mtime. |
| 12 | **Records stopped real work from ever happening.** `--resume` after a dry run or a low-disk skip; `--replace` after a copy-mode run; a second `--target-level`; `--limit-db` after a peak-limited skip; a stricter `--tolerance`. Each logged "skipping" and exited 0. | A record now only claims what still holds under the current options, about the file holding the result. |
| 13 | **One file name that isn't valid UTF-8 aborted the whole run** with `Error: invalid byte sequence in UTF-8`, because a catch meant for bad options caught it. Latin-1 names turn up on older NASes. | Such files now process normally **[verified on Linux in Docker]**, and any per-file exception fails only that file. |

### Medium: first run and honesty

| # | Finding | Fix |
|---|---|---|
| 14 | A directory with `[`, `{` or `*` in its name read as "No video files found", exit 0, in `process`, `report` and `cache`. | One literal directory walk (`VideoFiles`). |
| 15 | `docker run --user`, or any unwritable `HOME`, crashed with a stack trace. | File logging is best effort. |
| 16 | A relative name with a colon (`Alien: Covenant.mkv`) was read by ffmpeg as a protocol, then reported as "No audio track", exit 0. A name like `http:x.mkv` would select a real protocol **[read]**. | Paths are made absolute first. |
| 17 | A corrupt file was "No audio track, skipping", exit 0. | Fails as `unreadable`. |
| 18 | Without ffmpeg, every file failed separately. `report` called every file "untouched". | One error, up front. |
| 19 | On ffmpeg older than 7.1, Atmos is undetectable, yet the README said "never" and `apt install ffmpeg` was its install advice. | Warns each run and skips files named as Atmos. README now says what it can't catch. |
| 20 | Primary track lost flags such as `hearing_impaired`, though the README promised dispositions survive. | Restored. |
| 21 | `--target-level` dropped the chosen profile's settings, contradicting the README. | Inherited, and the profile is named from the target (`custom-18`). |
| 22 | Silent tracks measured as 0 LUFS (`"-inf".to_f`), then re-encoded with a false stamp. | Skipped as `silent`. |

### Low

With `--allow-dynamic`, the stamp correction wrote to the first audio track rather than the primary.
`df` parsing broke on a device name with a space, reading used space as free. A timeout always named
`NEUTRALISER_ANALYSIS_TIMEOUT`. The shared staging directory wasn't private. `--lock-file` errors
were stack traces. Audio-only MP4s failed on a required video map. Unused `plex-ruby` and `nokogiri`
removed.

README sentences also corrected: "no generational decay" (the code itself calls re-encoding
generation loss), `--dry-run` "write nothing" (it keeps analysis caches, and no longer writes a
manifest) and "FFmpeg 4.2+".

## Needs Will's call

Ranked. Nothing here was changed, and history wasn't rewritten.

1. **GitHub still serves the commit the August rewrite was meant to remove.** `57030a3` returns
   HTTP 200 anonymously, and the force-push is listed in the repo's public activity. Its tree holds
   `.env` with a Plex token, `.idea/`, and `check-prod` with NAS SSH details. **[verified]** The
   token is not the one in the current `.env` (compared without printing either) and doesn't appear
   in reachable history. `docs/log.md` records it as rotated; I didn't test it against Plex.
   *Recommendation:* confirm that old token is dead, then ask GitHub Support to purge the dangling
   commits, after item 2 so the purge covers everything.

2. **NAS details are in the public tree again.** August untracked `check-prod` because of its SSH
   details; `9342eb3` (2026-10-22) tracked it again so that worktrees get the skill. It names
   `admin@192.168.69.217`, the volume paths, a LaunchAgent, and the fact that `sudo docker` is
   passwordless. The addresses are private, so this isn't remotely exploitable by itself, but it's a
   map of your network. Lines with private strings: `check-prod` 5, `docs/log.md` 4 (also
   `willdows.local`, `nas.local`, "SSH as `admin` works"), `docs/ops/runbook.md` 2,
   `benchmark/results_20260308_051318.txt` 89 (host `budgie`), `benchmark/README.md` 2,
   `benchmark/run.sh` 1, `library-validation-2026-08.md` 1.
   *Recommendation:* before announcing, move `check-prod` to a user-level skill, redact `docs/log.md`,
   and delete the benchmark results. Removing the skill costs worktree agents their access to it,
   which is why this is your call.

3. **`--fast-verify` default, reversible.** I flipped it to off because the wrong answer is permanent
   and production already opts out (parity audit, row 26). The cost is one full measurement per file
   on a first run. To reverse: the default in `cli.rb` and `processor.rb`.

4. **MP4 record versus MP4 tags, reversible.** MP4s with a cover or descriptive tags now show as
   untouched in `report` and lose their record if moved. A moved file is re-measured, and it then
   lands within tolerance or peak-limited, so it isn't re-encoded **[read]**. I chose the file's own
   tags over our record, per "least lossy" in the vision.

5. **`--min-free-gb` can breach its own floor.** With 31 GiB free, a 30 GiB file and a 10 GiB floor
   the verdict is `:ok`, leaving 1 GiB mid-encode **[verified]**. That matches the README, so it's
   not a clear bug, but the class comment says a sweep "never fills it". `--local-stage` also guards
   only the output volume, not the staging one **[read]**. *Recommendation:* skip when
   `free - size < floor`, and check the staging volume.

6. **`--replace` breaks hard links.** The old copy lives on under its other names **[verified]**, so
   a library hard-linked to a seeding folder uses the space twice. Now in the README. Writing in
   place would keep the link but give up atomic replacement. *Recommendation:* leave it.

7. **`--fast` re-encodes files already at target**, since it never measures **[verified]**. That's
   a dynamic compression pass on a file that needed nothing, and the README example aimed at a whole
   library uses it. *Recommendation:* say so beside that example, or measure first.

8. **`analyze-plex` on TV libraries probably returns nothing.** It reads `/library/sections/N/all`,
   which for a show library lists shows rather than episodes, and only items with `Media` are
   measured **[read, not run against Plex]**. Job 7a872534 just rewrote this file and I left it
   alone. *Recommendation:* check on a real TV library before the README's "across your Plex
   libraries" is announced.

9. **The Plex token is visible in `ps`** while a title is sampled, because ffmpeg only takes headers
   in argv. The code comment claimed otherwise and is corrected, and the README discloses it. Only a
   local proxy would avoid it. *Recommendation:* accept for now.

10. **Smaller things.** The Docker image runs as root by default, so sidecars are root-owned `0600`
    (`--user` now works and is documented). No `fsync` before the rename, so "atomic" covers a
    killed process but not necessarily a power cut **[read]**. Real film titles appear in `demo/`
    and `docs/research/`. `AGENTS.md` still claims "Production ready" and "rollback capability".
    Actions are pinned by tag and the image publishes without running specs (CI job f43057f1 is
    still pending). Data streams other than a MOV timecode aren't carried over, which matters for GoPro
    telemetry and little else.

## Looked for and didn't find

| Hypothesis | Result |
|---|---|
| Shell injection from file names | None. Every subprocess uses argv form. The route that did exist was protocol parsing (fixed, #16). |
| Live credentials in reachable history | None. Current token count 0 across all patches; no AWS, GitHub, OpenAI or private-key shapes. The only `PLEX_TOKEN=` values are placeholders. |
| A/V offset drift on `--replace` | None **[verified]**: audio delayed by 2 s stayed at 2.000 s. |
| Published image is private | No. Anonymous registry access returns 200 for tags and manifest. |
| A mistyped flag runs for real | No. `--replace --dryrun` errors and leaves the file alone. |
| Unexpected codec or container failures | None in a matrix of AAC, AC3, E-AC3, Opus, Vorbis, FLAC, MP3 and PCM across MKV, MP4, M4V, MOV, WebM, AVI, FLV and WMV. Not every pairing was run. |
| Clean-clone install | Works: `bundle install`, `--help`, gem build and install, Docker build. |

## Not verified

- **FFmpeg 4.x.** The Debian 11 image's archive is unsigned, and two builds with FFmpeg 4.2 from a
  scratch image failed. The README now states only what ran: 5.1 and 7.1. The queued CI matrix should
  settle this.
- **Real E-AC3 Atmos and DTS:X files.** There are no samples, as in the October detection note.
- **Real Plex.** Out of scope for this review.
- **The invalid-UTF-8 spec on macOS.** APFS refuses such names, so it skips there. The behaviour was
  run on Linux in Docker.

## Overlap with other jobs

Rebased onto four commits that landed during this review. `b73347b` already wrote the manifest per
file and `8463db0` already added `Measurement#silent?`; I kept theirs and added only what they
didn't cover (no manifest on a dry run, `silent` in the cache and in the normalise decision).
