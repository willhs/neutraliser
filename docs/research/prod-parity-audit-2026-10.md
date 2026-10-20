---
type: note
status: active
owner: will
contributors: []
updated: 2026-10-20
review_cycle: 90d
agent_write: false
links: ["docs/tasks/0006-prod-parity-with-neutralise-sh/task.md"]
summary: "Behaviour-by-behaviour audit of media-server's neutralise.sh against the CLI: already there, ported, or dropped, and the driver switch it unblocks"
tags: [research, production, parity]
---

# Parity audit: media-server's `neutralise.sh` vs the CLI

Production normalises new media with `media-server/scripts/neutralise.sh` (a 357-line shell fork of this tool), called per folder or file by `neutralise-driver.sh`. The goal is to run the CLI instead. This note lists every behaviour the script has that the driver or the library depends on, and says whether the CLI had it, now has it, or should not.

Confidence tags: **[verified]** I ran it; **[read]** from source only.

## Verdicts

| # | `neutralise.sh` behaviour | Verdict | Notes |
|---|---|---|---|
| 1 | Target -20 LUFS, TP -1.5, LRA 12 | **Already** | = `livingroom` profile. **[read]** |
| 2 | Constant gain `min(target − I, TP − peak)`, `volume` filter, never loudnorm as encoder | **Already** | `GainPlan` (was `capped_linear_gain`). **[verified]** same numbers on a fixture |
| 3 | Skip within tolerance 2.0 LU | **Already** | `--tolerance`; the CLI default is 1.0, so the driver passes `--tolerance 2` |
| 4 | `MIN_GAIN` skip of TP-capped files: only re-encode when gain moves the file **towards** target by ≥ 1 dB | **Ported (CLI had a bug)** | The CLI skipped when `|gain| ≤ tolerance`, with no direction. **[verified]** a file at -28 LUFS / +0.5 dBTP (gain -2.0 dB) was re-encoded **quieter** at the default tolerance — the "17 of 36 quiet files made quieter" failure the script's comment describes. Now `GainPlan#worthwhile?` + `--min-gain` (default = tolerance; prod `--tolerance 2 --min-gain 1`) |
| 5 | `NEUTRALISE_LIMIT_DB`: opt-in alimiter so quiet-but-peaky files can reach target | **Ported, opt-in** | `--limit-db N`, stamp mode `limited`. See "Judgment: the limiter". **[verified]** fixture -24.0 LUFS / -1.8 dBTP → -20.8 LUFS / -2.0 dBTP, stamped `limited` |
| 6 | Target track: default-flagged, else first `eng`, else a:0 | **Ported** | CLI had default, else a:0. Now default, else first `eng`, else first. **[verified]** a spa/eng file with no default flag: eng track went -52 → -20, spa untouched |
| 7 | Atmos / DTS:X skip (profile contains `atmos` / `dts:x`) | **Already** | `ObjectAudio` (superset: name hint + mid-file probe), `--allow-object-audio-loss` |
| 8 | Only `aac`/`ac3`/`eac3` are re-encoded; everything else `skip_codec` | **Ported, narrowed** | Skip any primary codec that can't re-encode to itself in its container, `--allow-codec-change` to override. Judgment below |
| 9 | Keep all audio tracks in original order; restore the default flag; per-stream metadata for v/a/s; chapters; subtitles copied | **Already** | `build_complete_ffmpeg_command`, `--keep-original-audio` is an extra |
| 10 | Output codec/bitrate = source's; `bit_rate` N/A → 640k | **Drop (CLI better)** | CLI reads the BPS tag or samples packets, applies per-codec floors/caps (ADR-0001). The 640k fallback inflates MKV stereo |
| 11 | `aresample` to the source rate | **Already** | |
| 12 | MP4 bytes named `.mkv`: write `-f mp4` (mov_text can't go in Matroska) | **Ported** | **[verified]** before: CLI failed on a Lost-S01-style file, misreported as `unsupported_subtitle`. After: MP4 out, subtitle intact, stamp readable |
| 13 | Verify staged output: duration within 1 s and audio stream count | **Ported** | CLI only checked that ffprobe could read a duration. Now `FileManager.output_mismatch`, reason `output_verification_failed` |
| 14 | Atomic swap with `.bak`, verify in place, rollback | **Drop** | The CLI renames the temp output over the original (atomic), after verifying it. No window, nothing to roll back |
| 15 | Stage output on `/volume2`, then `cp` to `/volume1` | **Drop (config)** | CLI writes the temp file beside the original and renames. `--local-stage` stages in and out; point `TMPDIR` at the fast volume if wanted. ADR-0002 found staging gave no benefit on this NAS |
| 16 | `chown 999:999`, `chmod 0777` after the swap | **Ported (owner), dropped (0777)** | The CLI keeps the original's mode and now its uid/gid (best effort; needs root in the container). Forcing 0777 was a NAS workaround, not a requirement |
| 17 | `NEUTRALISE_KEEP_ORIG`: move the original file aside so a limited pass can be undone | **Drop** | Superseded by `--keep-original-audio`: the untouched track lives in the same file, no second file to manage. Use it with `--limit-db` |
| 18 | `MIN_FREE_KB` 40 GiB (skip file) / `MIN_ABORT_KB` 20 GiB (abort run, exit 4) | **Ported** | `--min-free-gb`, `--abort-free-gb`. The script sized them for a 2× transient (`.bak` + new file). Rename needs 1×, so 20/10 would do, but start with 40/20 (the proven values) and relax later. The check moves before the slow encode |
| 19 | PID lock dir, stale lock reclaimed, exit 3 | **Ported, redesigned** | `--lock-file` with `flock`: freed by the kernel when the holder dies, works across containers. The driver keeps its own lock |
| 20 | Exit codes: 0, 3 busy, 4 disk abort, other = keep going | **Ported** | CLI: 0 ok, 1 when files failed, 3 busy, 4 abort. The driver's `run_one` handles all of them already |
| 21 | Manifest `manifest.jsonl` (append-only, last wins, `size`+`mtime` self-healing) | **Replaced + migrated** | See "The manifest". The driver never reads it |
| 22 | `neutralise.sh invalidate < paths` | **Drop** | A replaced file has no `NEUTRALISER_*` tag and a different size/mtime, so it is picked up with no manual step. `neutralise-sweep.sh` mentions it for the HEVC campaign: not needed |
| 23 | Skip `._*` AppleDouble files | **Already** | `Dir.glob('**/*')` doesn't match dotfiles. **[read]** |
| 24 | Per-file log lines, `driver.status` | **Drop** | The driver only writes its own status; nothing parses the script's log. **[read]** |
| 25 | No timeouts | **Config** | The CLI times out after 1800 s per subprocess. The driver doc says ~20 min to measure a movie on the NAS CPU: set `NEUTRALISER_ANALYSIS_TIMEOUT` and `NEUTRALISER_NORMALIZATION_TIMEOUT` to 7200+ in the container |
| 26 | Measures every file fully | **Config** | The CLI's `--fast-verify` (default on) can skip a file after a 30 s sample. Pass `--no-fast-verify` for the same exactness |
| 27 | Nothing written into the library but the media | **Config** | The CLI adds hidden `.neutraliser`, `.loudnorm_*.json` and `.neutraliser-run-manifest.jsonl` files. Plex and the *arrs ignore them; `--no-cache` drops the `.loudnorm_*` ones |
| 28 | `sudo docker run linuxserver/ffmpeg` | **Follow-up** | The CLI needs an image with Ruby and ffmpeg |

## Judgment: the limiter

Does an `alimiter` fit "least lossy"? The vision's rule is "constant gain by default; compression is a choice, opt-in, named for what it does and reported". A limiter is a dynamics change, but a narrow one: it only touches peaks above the ceiling, by at most `--limit-db`, which is a ceiling on how much it may do. So it fits as an **opt-in** that is named (`--limit-db`), reported (`NEUTRALISER_MODE=limited`, a `limited=` count in the summary and `report`, a log note) and never the default. Production does not set `NEUTRALISE_LIMIT_DB` in the driver today; it is a manual lever (Lost S3), and stays one.

What is ported is stricter than the script in one way: the limiter ceiling is 0.5 dB under the true-peak target, and the script engaged it on a rounding overshoot too (a gain rounded to 2 decimals can sit 0.005 dB above the ceiling). `GainPlan` ignores overshoots under 0.01 dB, so a strictly constant-gain file is never marked `limited`.

## Judgment: codec changes

The script re-encodes only AAC, AC-3 and E-AC-3 because it passes `-c:a $ACODEC`; everything else was skipped (`skip_codec`) after 2026-10-17, when DTS/TrueHD were found falling back to lossy AC-3. The CLI's ADR-0001 sends DTS/TrueHD to FLAC in MKV and to E-AC-3 in MP4. FLAC from lossless is lossless, but it still replaces what an AVR can decode as DTS-HD/TrueHD with PCM, and the E-AC-3 case is lossy-from-lossless. Matching production, and the vision ("the re-encoded track keeps the source codec"), the default is now to **skip** any codec change and tell the user how to opt in. ADR-0001's fallback chain still applies under `--allow-codec-change`. mp3/opus/vorbis/FLAC/PCM re-encode to themselves, so they are processed (the script skipped them only because its encoder line couldn't).

## The manifest

`neutralise.sh` is the only reader of `manifest.jsonl`; `neutralise-driver.sh` reads its own queue and stamp files. So the "format the driver reads" is not a CLI requirement. What the manifest carries is **history**: which of the ~4,000 library files are already leveled. The shell never tagged files, so after the switch the CLI would see none of them as processed and re-measure the library (20 min a movie).

`neutraliser import-manifest manifest.jsonl --root /volume1/media` carries that over:

| manifest status | imported? | why |
|---|---|---|
| `done`, `skip_tol`, `skip_tp_capped` | yes, if size and mtime still match | the script finished with the file |
| `skip_object_audio`, `skip_codec` | no | the CLI decides these in seconds, before measuring |
| `fail_*`, `rollback`, `skip_diskguard` | no | should be retried |
| entries with no size/mtime (pre-2026-07-26) | only with `--trust-legacy` | can't be checked against the file |

Each hit becomes an entry in the `.neutraliser` sidecar in the file's own folder, which now counts for any run above it. New files from now on carry `NEUTRALISER_*` tags and show in `neutraliser report`; the imported history shows as `untouched` there, because the shell wrote no tags. **[verified]** a manifest-listed quiet file was skipped, not re-encoded, in a run over its parent folder.

## Recommended driver call

```
neutraliser process /m/<relpath> --replace --tolerance 2 --min-gain 1 \
  --no-fast-verify --no-cache --lock-file /stage/.neutralise.lock \
  --min-free-gb 40 --abort-free-gb 20
```
with `NEUTRALISER_ANALYSIS_TIMEOUT` / `NEUTRALISER_NORMALIZATION_TIMEOUT` ≥ 7200, `TMPDIR` on the stage volume, and the container running as a user that can write the library (or root, for the owner copy). Add `--keep-original-audio` only if reversibility is wanted: it costs the size of one audio track per file.

## Open decisions (Will)

- Disk floors 40/20 GiB: kept from the script; could halve now that no `.bak` is made.
- Codec-change default is skip (matches prod). Say if lossless-to-FLAC in MKV should instead be processed.
- `--keep-original-audio` on the driver or not.

## Follow-up tasks

1. Docker image: Ruby + ffmpeg (≥ 7.1 for Atmos profile names), `TMPDIR`, timeouts, non-root option.
2. Driver switch in media-server: call the container, pass the flags above, drop the `neutralise.sh` lock handshake (exit 3 still means busy), run `import-manifest` once on the NAS, delete `neutralise.sh`, update `neutralise-sweep.sh` comments about `invalidate`.
3. Verify on the NAS: one imported Sonarr file ends with `NEUTRALISER_*` tags and appears in `neutraliser report`.
