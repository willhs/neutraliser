---
type: note
status: active
owner: will
contributors: []
updated: 2026-11-15
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
   details; `9342eb3` (2026-10-22) tracked it again so that worktrees get the skill. It named the
   NAS's SSH login and private address, the volume paths, a LaunchAgent label, and the fact that
   `sudo docker` is passwordless. The addresses are private, so this isn't remotely exploitable by
   itself, but it's a map of your network. Private strings were also in `docs/log.md` (4 lines:
   home hostnames and the NAS address), `docs/ops/runbook.md` (2), the March benchmark results
   (89, naming the host), `benchmark/README.md`, `benchmark/run.sh` and
   `library-validation-2026-08.md`. (The strings themselves are left out of this note so it
   doesn't repeat them; `git show 65a44d5:<path>` has the originals.)
   *Recommendation:* before announcing, move `check-prod` to a user-level skill, redact `docs/log.md`,
   and delete the benchmark results. Removing the skill costs worktree agents their access to it,
   which is why this is your call.
   *Done 2026-11-01 (task 3e4efd6b):* the current tree no longer holds them. `check-prod` stays
   tracked but generic and reads the address from a gitignored `local.env`; the log is redacted; the
   results file is deleted and `benchmark/results_*.txt` is ignored. History is untouched, so the
   old commits still hold them. A guard spec (`spec/no_private_details_spec.rb`) fails if they come back.

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

## After the 15 Nov landings

Added 2026-11-15, after four unattended jobs landed on top of the review above: the levelling ladder
(`c5208fa`, `--ladder`, `--anchor`), 7.1 measured with its side channels (`13be53a`), the honesty
edits to README and CHANGELOG (`c288fff`), and research 0004's generation-loss run (`27ad30a`).
Job 2b33fcf6 (7.1 encoder choice) had not landed on `origin/main` (`27ad30a`) when I finished
(fetch checked before committing); Manager reports it parked in review, so it is not covered. I tried to
disagree with the diff and ran things rather than reading them. Synthetic clips only (the ladder
specs' own generators plus mono, 7.1 and a silent-centre 5.1 I made); no NAS, no real library file.
Evidence and the scripts that produced it are in the job's `evidence/` directory (not committed).

**Verdict: NO-GO — not safe to ship 0.1.0 as it stands.**
`13be53a` broke 7.1 measurement on supported FFmpeg 4.2.2 (finding 1, fixed in this review).
The ordinary <=6-channel processing path retains recipe 2 and its filters, but report fields
are **not identical** (finding 8). Before release, also resolve the misleading ladder/redo claim
(finding 2); stale 7.1 caches make upgrading an existing installation unsafe (finding 3).
The ladder remains opt-in; that limits exposure but does not settle those defects or the
dialogue-target safety decision in finding 4. This is a completed negative review, not release approval.
Confidence labels: **[verified]** I ran it, **[CI]** read from the GitHub Actions log,
**[inferred]** reasoned, not run.

### Findings, most severe first

**1. [High, fixed] 7.1 measurement fails on FFmpeg 4.2.2, with a second defect behind the first.**
The `rspec (ffmpeg 4.2.2)` job fails `spec/seven_one_real_spec.rb:32` and `:46` with
`Measurement failed (exit 1): Invalid argument` **[CI]** (runs 43696441428 and 43699477921; the
7.1 job is green, and `27ad30a` is red for the same reason). The new measure graph asks for
`ebur128=peak=true:framelog=quiet`; FFmpeg 4.2.2 rejects the `quiet` constant **[verified]**
in its actual stderr. The README says "Works from 4.2 (CI runs
4.2.2 and 7.1)", so on that ffmpeg every 7.1 file now fails to measure, a loud failure and no
data change, but a broken claim and a red release gate.
*Reproduce:* `bundle exec rspec spec/seven_one_real_spec.rb:32` with FFmpeg/ffprobe 4.2.2 on PATH.
I ran the static Linux binaries in an amd64 Debian container through local shims:
one example, one failure, `Measurement failed (exit 1): Invalid argument`.
Changing only `quiet` to `verbose` makes the filter parse, but the three-example real spec then
still fails twice: the split-graph reading is **-70.0** versus the independent **-25.3 LUFS**,
and processing lands at **-4.9** rather than **-20 LUFS**. That candidate was reverted; suppressing
the first error alone is not a fix. The raw stderr resolves the second defect: FFmpeg 4.2 prints
an empty -70 LUFS summary when replacing its initial graph, then the real summary at the end.
The parser selected the first summary. A failing unit regression reproduced that exact sequence.
The final correction uses the supported `verbose` log constant and parses the **last** summary;
neither a version fallback nor a six-channel measurement is introduced. Evidence:
`seven-one-42-red.txt`, `seven-one-42-green.txt` (candidate, despite the filename),
`ff42-red.txt`, `ff42-graph.txt`. Supported log constants are also in
[FFmpeg 4.2.2's source](https://github.com/FFmpeg/FFmpeg/blob/n4.2.2/libavfilter/f_ebur128.c#L159-L161).
`seven-one-42-final.txt` captures the real-media verification of the final correction.
*Task filed during diagnosis:* `0f106f55-586a-4c11-88fd-e657262a66ae`, resolved by this review's
small correction; no support-floor decision is needed.

**2. [Medium] `--ladder` re-encodes files an older recipe already levelled, without `--redo-recipe`, and
the README says it won't.** README says "Under a programme anchor ... files already levelled for it
are left alone; `--redo-recipe 2` re-levels them". **[verified]** this is false for any file whose
loudness range is over `--lra-target` + tolerance (14 LU under the ladder), which is most films:
`SkipDecider#entry_matches?` refuses a sidecar entry with no `lra_target`, and
`stamp_meets_lra_target?` refuses a linear stamp with a wide range, so the stamp is not "done".
*Reproduce:* `process --replace wide.mkv` (recipe 2, linear, LRA 14.7), then
`process --replace --ladder wide.mkv` with no redo flag: it compresses and re-encodes
(`recipe 3, compressed`, gain 4.95 dB); a second `--ladder` run skips. That is a second lossy
generation on a normalised library from adding one flag, and it would be every wide-range file
the day `Recipe::CURRENT = LADDER`. A file at target is skipped (a redo on it says "Already at
target", **[verified]**), so the cost lands on exactly the files the ladder exists for.
*Task filed (attended):* `3b569650-b9cb-47ae-8e63-58b059b30fde`, decide whether `--ladder` should honour "a run never re-levels a file
because of its recipe" (recipe.rb says so) or whether the README should say what happens. Until
then the README sentence is wrong.

**3. [Medium] A pre-`13be53a` analysis cache still lands a 7.1 file 3 LU over target. Fixed (16 Nov, task `a9b7230e`).**
`CacheManager::CACHE_VERSION` was not bumped, so a `.loudnorm_<profile>.json` written by an older
build (a dry run or any left-alone pass writes one) is trusted, with the six-channel reading.
*Reproduce* **[verified]**: `bin/neutraliser process --dry-run sev1.mkv` with the tree from
`21d2e2f`, then `process --replace sev1.mkv` on `main`: "Current: -24.1 LUFS", output measured
-17.0 LUFS by ebur128 (target -20); the same file with no cache is correctly left alone at -21.0.
Only caches from builds before `13be53a` are affected, so it matters for Will's own libraries,
not for a fresh install. Bumping the version discards every cache on the NAS (a full re-read), so
I did not do it: *task filed* `a9b7230e-d1e2-4d19-af70-d0ef6d0396a0`.
*Code anchors:* `CacheManager::CACHE_VERSION`, `AudioAnalyser#analyse`, `Measurement#with_all_channels`.
*Fixed:* `CACHE_VERSION` is 1.3, so every 1.2 cache is dropped and re-read. The cost argument above turned out
smaller than feared: a cache only stands for a file that has not been levelled (levelling changes size and mtime),
so the re-read is of files still waiting. The stored entry has no channel count, so 5.1 caches go too.
Regression: `spec/seven_one_real_spec.rb` "does not trust a 7.1 analysis cached under the six-channel meter"
(red before: output -18.2 LUFS against -20). Files already levelled (finding 7) are `process --redo-side-channels`
(runbook, "7.1 files levelled before the side channels were metered"); the stamps themselves are not touched.

**4. [Medium] `--anchor dialogue` has no ceiling on how loud the programme may be aimed.**
`Ladder.aim` floors "loudness above dialogue" at 0 and has no upper bound. A 7.1 clip whose centre
reads 24 LU under its programme (front channels quiet, sides loud) is aimed at **-2.85 LUFS**,
limited by rung 2 and written at -3.9 LUFS with a -1.1 dBFS peak **[verified]**:
`process --replace --ladder --anchor dialogue sev1.mkv`. The fixture is extreme; a realistic one
(dialogue 7 LU under the programme) lands the programme at -20, which is the intent. The risk is a
mis-estimated centre, which the code's own comment says happens. The reproduction kit's different
seeded side-heavy clip aims -8.13 and lands -8.2 LUFS, confirming the mechanism.
*Task filed (attended):* `e871fffd-2cce-4c68-aea2-f8daefa3b2a5`, a cap
or a refusal above some aim, and what that number is, is a default and Will's call.

**5. [Low-medium] 7.1 range is read from six channels, so rung 3 can miss a 7.1 file that is over the limit. Fixed.**
`with_all_channels` keeps loudnorm's range ("close enough"). On a synthetic 7.1 (the wide 5.1 mix
with its back channels copied to the sides) loudnorm reads LRA 13.5 and ebur128 reads 15.2
**[verified]**; under `--ladder` (limit 13 + 1 tolerance) the file gets no compression and is
levelled linear, while the 5.1 original compresses (LRA 9.8 afterwards). *Reproduce:*
`process --replace --ladder wide71.mkv` on the retained fixture under `evidence/fx/`.
The kit generates a new wide mix each run (the existing helper does not seed its noise), so
the precise range and boundary crossing vary. Its fresh run read 14.6 versus 16.0 LU and did
compress at the default limit; the retained fixture proves the missed trigger.
*Task filed:* `2ec806f2-e773-43f2-ad16-7499e4e778c5`.
*Fixed:* `with_all_channels` now takes ebur128's LRA with its loudness and gate, so a 7.1 read (the file and every
compression candidate) is one meter's range against the limit. Regression: a seeded 7.1 clip whose range lives
only in the sides (loudnorm LRA 0.1, ebur128 14.9) was levelled linear, now rung 3 compresses it
(`spec/ladder_real_spec.rb`, `spec/seven_one_real_spec.rb`). Caches written before this hold loudnorm's range for
7.1 files: the same stale-cache question as finding 3, not bumped here.

**6. [Low] `report --measure` and `rate-sample` judged dialogue-anchored files against the wrong target. Fixed.**
`Report#measured_levels` used the profile's fallback programme level (-24) and ignored the stamp's
own `target_i`, so a file that landed exactly where it was aimed (-19.9 for dialogue at -27) read
"needs the remote" in `rate-sample --ladder --anchor dialogue`. The records-based path
(`FinalLevels.from_stamp`) already used `target_i`. One-line fix in `report.rb` with a failing
spec first (`spec/report_spec.rb`, "judges a dialogue-anchored file by the programme level its
stamp aimed at"). Additional coverage checks left-alone dialogue records; existing tests check
profile fallback. *Reproduce:* `bundle exec rspec spec/report_spec.rb`; before the fix the regression
had `target: -24.0`, expected `-20.0`; after it, 18 examples, zero failures.
The kit's `dialogue/report.json` now judges -19.9 LUFS against its stamp's -19.94 target.

**7. [Low] 7.1 files already levelled at recipe 2 cannot be found with `--redo-recipe`, and `analyze-plex` still reads 7.1 loudnorm-only.**
`recipe.rb` explains why 7.1 did not get a new recipe (nothing released). That is true for
strangers; Will's NAS has stamped 7.1 files up to ~1.8 LU over target that no redo flag selects
(`report --measure` is the way to find them). `analyze-plex` also reads 7.1 titles with
loudnorm alone (noted in the log, not in the README).
*Reproduce:* `rg -n 'channels|measure_loudness' lib/neutraliser/plex_analyzer.rb` shows the measurement
call has no channel count; `process clip.mkv --redo-recipe 2` refuses the current recipe.
Recovery is filed with finding 3; Plex propagation is `c2aa02bc-a761-441e-a483-9ed574609db1`.
*Recovery built (16 Nov):* `process --redo-side-channels` (runbook); the `analyze-plex` half was fixed in `4af6c56`.

**8. [Info] What changed on the default path, all additive.** Every `process` now passes two
empty `NEUTRALISER_TARGET_I=` / `NEUTRALISER_DIALOGUE_I=` tags (an empty value deletes a tag, so
nothing is written), `report` prints a `Rungs:` line and the TSV gains a `rung` column. Anyone
parsing the report TSV by column count will notice. JSON gains `summary.rungs`, per-file `rung`,
and nullable `stamp.target_i` / `stamp.dialogue_i` (left records gain nullable `target_i`).
*Reproduce:* run both trees' `report clip.mkv --format json` and `--format tsv` on the same recipe-2
fixture. Captured `report-json.diff` shows the additive keys; existing fields match.

### The five questions

**1. Is the default path unchanged?** Processing recipe and filters: yes for <=6 channels;
complete output/report fields: **no**, additive changes in finding 8 **[verified]**.
I ran `process --replace` on eight
synthetic clips (stereo, mono, 5.1 PCM/AAC/AC-3, DTS, peaky, wide, a 5.1 AC-3 with a silent
centre) and again with `--limit-db 4`, `--lra-target 14`, `--lra-target 11 --tolerance 0.5` and
`--tolerance 0.5 --min-gain 2`, once with `c5208fa^`'s tree (`21d2e2f`) and once with `main`, with an
`ffmpeg` shim logging every invocation. Same ffmpeg argv (filter strings included, e.g.
`volume=6.38dB,aresample=48000`; `alimiter=limit=0.7943:...`) apart from the two empty tags in
finding 8, same stamp tags (recipe 2), same sidecar, same console output, same `report` apart
from the `Rungs:` line. Both trees wrote `limited` and `compressed` stamps in the flag runs, so
this is not comparing two no-ops. Not run: 7.1, where the measurement was changed on purpose.

| No-new-flags comparison | `c5208fa^` (`21d2e2f`) | Reviewed tree |
|---|---|---|
| Narrow fixture recipe | 2 | 2 |
| Narrow fixture filter | `volume=6.38dB,aresample=48000` | identical |
| Written non-date stamp tags | recipe 2 / linear / gain 6.38 | identical |
| Existing report values | same stamped file | identical |
| Report schema | no rung or per-file aim keys | additive keys in finding 8 |

Thus "no default processing change" holds for these fixtures, but "identical report fields" does not.

**2. `--ladder`.** Every rung is reachable in a test: `spec/ladder_real_spec.rb` has a real-ffmpeg
case for rung 1, 2 (guarded for ffmpeg < 5.1), 3, +convert (DTS) and the dialogue anchor, and a
`report` rung count. Edge cases, all **[verified]**:

| Run | Result |
|---|---|
| `--ladder --fast` | refused: `--fast` needs `--allow-dynamic` (unchanged) |
| `--ladder --fast --allow-dynamic`, `--ladder --allow-dynamic`, `--ladder --profile night` | ladder steps aside with a note; stamped **recipe 2**, mode `dynamic` / `linear` |
| `--ladder --fast-verify` | note, runs without rung 3, recipe 3 |
| `--ladder --redo-recipe 3` | refused ("is the one this run writes"); `--redo-recipe 2` and `unversioned` work; a redo on a file at target is skipped |
| mono | rung 1, recipe 3; `--anchor dialogue` gives "No dialogue estimate (mono, no centre channel)" and aims -24 |
| stereo `--anchor dialogue` | same, aims -24, stamped `dialogue-27`, `TARGET_I -24` |
| 5.1 with a silent centre | "No dialogue estimate (silent centre channel)", aims -24 |
| `--anchor dialogue` without `--ladder` or with `--fast-verify` | refused with a clear message |
| 7.1 `--ladder` | works, see findings 4 and 5 |
| next sweep | ladder file: `--ladder` and plain both skip it. Recipe-2 file: `--ladder` re-encodes it (finding 2) |

**3. 7.1.** Integrated loudness, loudnorm against ebur128 on the same clips (LU, ebur128 minus
loudnorm): stereo narrow +0.08, peaky +0.04; mono +0.06; 5.1 PCM +0.11, AC-3 centre-silent +0.04,
AC-3 dialogue 0.00, DTS +0.07; wide 5.1 (LRA 15) **+0.36**; 7.1 with loud sides **+3.05**
(-24.05 against -21.0). So the two agree within about 0.1 LU on steady material and 0.4 on a wide
mix, which is inside the 1.0 tolerance but means a 7.1 film is judged by a slightly different
meter than the same film in 5.1 (ebur128 prints one decimal only, so the small figures carry ±0.05).
The 7.1 result is in tolerance: the loud-sides clip, which loudnorm reads 3 LU low, goes through the
default path and lands at **-20.0 LUFS** by ebur128 (target -20), and the wide 7.1 mix at -20.0.
The defects found were version handling (fixed, finding 1) and range (finding 5).

**4. Docs honesty.** One false claim: the README sentence in finding 2. The ladder is described as
opt-in everywhere I looked ("opt-in for now", `--ladder` off in the options table, "The default is
unchanged"), and `--fast` is no longer recommended for libraries. Gaps rather than falsehoods: the README
(line 88) and CHANGELOG say +25% bitrate "scored higher in every case we measured" / "in all 16
source-window pairs", which is true, but of one metric (a Python ViSQOL port) on four 30-second
windows of one film with no listening test; the CHANGELOG carries the link and the README does not.
Research 0004's per-pass loss numbers are not quoted in README or CHANGELOG, good. Neither mentions
7.1 measurement, nor that `analyze-plex` still reads 7.1 loudnorm-only. Rewording the +25% claim
is Will's call: *task filed (attended)* `e3946d53-ee27-4a8e-bdc6-d54acd6a02f1`.
*Reproduce the wording audit:* `rg -n 'ladder|already levelled|every case|16 source|ViSQOL|generation|fast' README.md CHANGELOG.md`
and compare research 0004's "Repeated generations" method and caveats with
`lab/generations.py` and `lab/decide.rb`. No media from that research was opened or regenerated.

**5. Is research 0004's generation-loss method sound enough to quote in a release post? No, not the numbers.**
Its two limited findings stand: the shipped codec decision writes the same
bitrate on every pass (16 of 16, read from the real `decide_codec`), and +25% does not stop loss
accumulating. I would say those two things. I would not print "ViSQOL falls 0.04 to 0.18 a pass"
or "stereo AAC loses 0.32 over three passes" as general CLI outcomes because: (a) its zero-gain
serial re-encodes are a controlled codec experiment, not actual repeated CLI processing. The CLI
skips a file already at target ("Already at target level ... skipping", **[verified]**, kit `redo-old`),
so it does not perform the modelled second encode on that unchanged file. Changes of aim or
compression are a different workload; (b) it is one film, four
30-second windows, ViSQOL as a pure-Python port not cross-checked against the C++ implementation,
no listening test
(the note itself says it is "a trend, not a verdict that anyone hears it"); (c) the AAC sources came from
Apple's encoder and the passes line up on exact codec-frame delays, which it calls a best case;
(d) the E-AC-3 source was made by FFmpeg, not Dolby. A post could say "re-encoding lossy audio
costs a generation each time; +25% bitrate helps the first pass and does not stop that; neutraliser
leaves files at target alone" and link the note. It should not give per-pass figures as
audible loss.

The scoring code does cover both stereo channels and all five full-range 5.1 channels separately
before averaging (`generations.py:115`); it does **not** score only one 5.1 channel. The one-channel
limitation belongs to the identity-ceiling check, not the generation comparisons. The lab is a
useful controlled serial-encode experiment; its scope and the difference from actual CLI redos
need to travel with any numerical quotation.

### Fixed in this pass

Findings 1 and 6, each with failing checks first. Finding 1 needed both the supported log constant
and the final summary; the initial option-only candidate was disproved and reverted before the
two-part correction. The rest are either not small (2, 3, 5), a default
or a claim (2, 4, wording in 4 above) or need data I can't touch (7).

### Not verified

- Job 2b33fcf6 (7.1 encoder choice): not landed when I looked, not reviewed.
- A ladder pass on a wide-range file whose compression cannot narrow it, after losing the sidecar
  (it should re-measure every sweep rather than re-encode): reasoned from the code, not run.
- Real films, real 7.1, real ears: nothing here says how any of it sounds.

### Reproduction kit and limits

From the repo root, run
`bundle exec ruby docs/research/after-landings/lab/review.rb /absolute/path/to/new/scratch-directory`.
It refuses an existing directory, builds only synthetic clips using the repo's generators, writes
per-run logs and measured reports, and prints JSON rows with both meter readings.
The wide mix's noise is not seeded in the existing helper: expect slight numerical variation.
The original fixtures and raw argv logs are retained under this job's `evidence/`, not only `/tmp/`.
`default-path-comparison.txt` captures the eight-fixture comparison;
`default-narrow-recheck.txt` re-ran one case after the report fix.
The initial `measure-agreement.txt` has a formatting error in its diff column; use its actual
readings and the kit's numeric `delta` fields in `reproduced.jsonl`.

Blast radius of the report fix: `Report#measured_levels` feeds every report format and
`RateHarness`'s measured report. Recorded targets already govern `FinalLevels.computed`; ordinary
records without `target_i` keep the profile fallback. The two regression cases and synthetic
dialogue report prove that shared target contract. No persistent schema or encoder path changes.

Blast radius of the 4.2 correction: only >6-channel reads build the split graph or invoke the
summary parser. The final summary is the completed measurement on both tested versions. The
existing real 7.1/5.1 specs exercise it, and the new two-summary regression checks the actual
4.2 lifecycle output. The <=6-channel argv comparison remains unchanged.

All seven follow-ups above are linked to release goal `669c751d-25c2-4f24-822e-dbe64ddfae88`;
the three policy/wording decisions are attended. Manager lands this note after review.
