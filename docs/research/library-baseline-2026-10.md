---
type: note
status: active
owner: will
contributors: []
updated: 2026-11-08
review_cycle: 90d
agent_write: false
links: ["docs/research/prod-parity-audit-2026-10.md", "docs/philosophy/vision.md", "docs/ops/runbook.md"]
summary: "Read-only baseline of the NAS library on 2026-11-08 from every record there is: report stamps, the Aug CLI run manifests and the shell fork's manifests. The library is still 98% unstamped: 1,935 files from the Aug run are on disk as dynamic, 12 Atmos episodes were flattened, ~255 shell-processed files have untagged streams, and the Aug failures are 318 not_writable files plus 3 subtitle and 2 other"
tags: [research, production, library, baseline]
---

# NAS library baseline, 2026-11-08

What state is the NAS library in, counted from every record that exists, before any fixing. Nothing was written: the report ran in the published image with every root mounted `:ro`, and the manifests were copied off.

Reproduce: `docs/research/library-baseline-2026-10.py RAW_DIR` (the join and every number below; inputs listed in its header).

## Premise check

The task's notes held up, with these corrections:

- **"797 failed" counts failure records, not files.** 343 were timeouts that a later retry completed, 445 were `not_writable`-style permission errors, 6 subtitles, 3 other. One status per file (a file's last `done`, else its last record) leaves **323 files that never succeeded**: 318 permission, 3 subtitle, 1 file missing, 1 AC-3 probe error. See [Failures](#failures).
- **"2,026 / 3,208 dynamic (63%)" is right as records** (2,026 Dynamic + 1,182 Linear `done`, all `/volume1/media/tv`, none of the movies). As a share of today's 7,011 TV files on `/volume1` it is 29%.
- **The CLI's `report` cannot see any of it.** The Aug run wrote no `NEUTRALISER_*` stamps, so `report` calls those files `untouched`. Dynamic and flattened files are findable only through the Aug manifests.
- **The `.loudnorm_*.json` sidecars were not needed.** The manifests carry the same mode (`normalization_type`) and failure message, and the sidecars hold measurements, not outcomes.
- **The sweep is not running.** The driver's status file says `stopped (signal)` on 2026-11-01 02:42, and `/volume1` TV has 6 stamped files out of 7,011 (the "backlog sweep is back on" status of 2026-10-28 got that far).
- The retired shell fork's `skip_tp_capped` and `mode` are in `manifest.jsonl` only from some point in its run: 364 `done` rows have no `mode` at all.

## Where the library stands now (report stamps)

`neutraliser report --format=tsv`, image `ghcr.io/willhs/neutraliser:latest` (v0.1.0), 2026-11-08.

| Root | Files | linear | limited | dynamic | untouched (no stamp) |
|---|---:|---:|---:|---:|---:|
| `/volume1/media/tv` | 7,011 | 6 | 0 | 0 | 7,005 |
| `/volume1/media/movies` | 816 | 0 | 0 | 0 | 816 |
| `/volume2/media/tv` | 672 | 165 | 0 | 0 | 507 |
| `/volume2/media/movies` | 34 | 7 | 0 | 0 | 27 |
| `/share/USB3-2/TV Shows` | 1,253 | 0 | 39 | 0 | 1,214 |
| `/share/USB3-2/Movies` | 0 | | | | |
| **Total** | **9,786** | **178** | **39** | **0** | **9,569** |

- **No stamped file is dynamic**: the goal's "no new dynamic-mode files" holds for everything the CLI has written. All 217 stamps are `livingroom`, version 0.1.0.
- 98% of files carry no stamp, so "untouched" mixes four different things; the next table splits them for `/volume1`.

## `/volume1` by what recorded each file

Joins the report (stamp), the Aug CLI manifests (one status per file) and `manifest.jsonl` (the shell fork's, final row per path). A path that moved or was replaced since (the HEVC campaign) shows as no record.

| Aug CLI run | Shell fork | Files | What it means |
|---|---|---:|---|
| Dynamic | none | 1,838 | on disk dynamically compressed, no stamp |
| Dynamic | done / skip_tol | 97 | same; the shell fork re-measured or re-did 53+44 |
| Linear | none / skip_tol | 1,175 | fine; constant gain, no stamp |
| skipped | none | 1,746 | left alone in Aug (already within tolerance) |
| skipped | skip_tol | 1,340 | within tolerance by both engines |
| skipped | done | 179 | shell fork changed it afterwards |
| failed | none | 304 | still failed (see below) |
| failed | done / fail_measure | 18 | failed in Aug, shell fork did it (17) or failed it (1) |
| skipped | fail_measure | 7 | shell fork could not measure it |
| none | fail_measure / skip_object_audio | 2 | a film each (Forrest Gump is the Atmos one) |
| none | skip_tol | 692 | movies 679, tv 13 |
| none | done (linear/limited/unmoded) | 78 | shell fork only |
| none | skip_tp_capped | 47 | peak-capped, left alone (The Office 20, Mock the Week 4, films) |
| none | skip_codec | 22 | lossy codec changes refused (mp3 etc.) |
| none | none | 276 | no engine has looked: 243 tv, 33 movies |
| stamped linear | | 6 | the CLI since 2026-10-28 |

## Aug CLI run

Source: 199 per-folder `.neutraliser-run-manifest.jsonl` files, 59,590 lines, mostly `queued` (Feb/Mar planning runs and the Aug queue). The run that did the work is 2026-08-09 to 08-17, `/volume1/media/tv` only.

| Records | Count |
|---|---:|
| done, `Dynamic` | 2,026 |
| done, `Linear` | 1,182 |
| done, no type | 2 |
| failed | 797 |
| skipped | 5,520 |

Of the 2,026 Dynamic files, 1,935 are still on disk at the same path (91 were replaced or removed since); the biggest shows: The Simpsons 221, South Park 138, The Office (US) 125, King of the Hill 95, The Sopranos 76, The Wire 57, SpongeBob 55, Attack on Titan 52. Full list: `evidence/analysis-output.txt` (outside git; rerun the script).

### Atmos / TrueHD files re-encoded before the Atmos skip

Aug `done` files whose release name says Atmos, TrueHD or DTS:X: **12, all `Dynamic`, all TV**: Fallout S02E01, Severance S02E01/E03/E04/E07 and The Mandalorian S01E01, E03-E08. ffprobe of each file on the NAS now: `eac3` (11) or `ac3` (Severance S02E01), profile `unknown` where the untouched original would read "Dolby Digital Plus + Dolby Atmos". The object-audio layer is gone. Name matching is a floor: an Atmos release with no hint in its name would be missed, and the output has no way to tell (no stamp, no source codec kept).

Forrest Gump (1994) TrueHD Atmos is intact: the shell fork refused it (`skip_object_audio`), and ffprobe reads `truehd`, "Dolby TrueHD + Dolby Atmos". A 4 GB copy of it sits in `flattened-backup/` in the stage directory (from the 2026-10-07 test).

### Failures

By record (797) and by file (323 never succeeded):

| Reason | Records | Files never done | Where |
|---|---:|---:|---|
| permission (`not_writable`-style) | 445 | 318 | The Simpsons 135, Futurama 113, Bob's Burgers 17, Yes Minister 14, King of the Hill 14, Twin Peaks 11, Stranger Things 4, Pokemon 3, Rick and Morty 3, The Office 2, SpongeBob 1, Wrexham 1 |
| timeout | 343 | 0 | all retried and completed later |
| subtitle | 6 | 3 | |
| AC-3 probe ("low score of 25") | 2 | 1 | |
| file missing | 1 | 1 | The Office S03 |

The listed show folders are now `drwxrwxrwx` on `/volume1`, so the ACL fix may already have happened; nothing was written to prove it (read-only run), so writability needs checking when the writes begin. The subtitle failures are the "known unfixable" kind. Failure messages are ffmpeg's full stream dump, so the class comes from a keyword match in the script.

## neutralise.sh (shell fork) manifests

`manifest.jsonl` (`/volume1`) 2,941 rows, plus the three USB3-2 batch manifests (94 rows).

| File | done | skip_tol | skip_tp_capped | skip_codec | fail_measure | skip_object_audio |
|---|---:|---:|---:|---:|---:|---:|
| `manifest.jsonl` | 446 (364 no mode, 74 linear, 8 limited) | 2,401 | 59 | 22 | 12 | 1 |
| `manifest-usb3-2.jsonl` | 28 linear | 14 | 17 | | | |
| `manifest-usb3-2-limited.jsonl` | 31 limited | 1 | 2 | | | |
| `manifest-usb3-2-limited-8db.jsonl` | 1 limited | | | | | |

No row is `dynamic`: the fork's own constant-gain modes only. The 364 rows with no `mode` come from before it recorded one.

### Tag-stripped files (~400 per the notes)

The fork's per-stream metadata fix landed 2026-10-08 and the notes say 400 `done` files precede it; the manifest has no timestamps, so the exact set cannot be cut. The 364 mode-less `done` rows are the core, and 446 is the ceiling for `/volume1`. Of the 446 `done` paths, 327 are still on disk (the other 119 were replaced or moved).

Whether a file still has stripped tags was measured with ffprobe (any audio or subtitle stream without a `language` tag):

| Set | Files read | With an untagged audio/subtitle stream |
|---|---:|---:|
| the 327 shell-`done` files still on disk | 327 | 255 (78%) |
| control: 400 random shell `skip_tol` files (never rewritten), 360 present | 360 | 142 (39%) |

Many untouched releases ship untagged subtitles, so 39% is the background rate. About 39 points over it, **around 130 of the 327 present files (a rough estimate, not a list) lost tags to the fork**. Without originals nothing says which. Repair means re-tagging from another source, or re-downloading.

The Aug CLI run shows the same pattern: the 7 Mandalorian S01 files above read 14 of 15 audio/subtitle streams untagged, so the CLI's Aug build may have stripped tags too. That run's files were not controlled for; worth a check before deciding what to do with them.

## USB3-2 and volume2

- `/share/USB3-2/TV Shows`: 1,253 files, 39 stamped `limited` (from the shell fork's limited runs or the manifest import; not traced), 1,214 unstamped. Movies is empty.
- `/volume2/media`: 706 files, 172 stamped linear (165 tv + 7 films) since 2026-10-28; none dynamic.

## What this changes for the goal

1. **Dynamic files**: 1,935 on `/volume1` are only visible through the Aug manifests; `report` cannot count them, so a "no new dynamic" check must also read manifests or the next run must stamp them.
2. **Atmos**: 12 files flattened, all lossy-to-lossy (DDP to DDP/AC-3); originals not kept. Re-sourcing is the only repair.
3. **Failures**: 318 files fixable by permission alone (check writability first), 4 not.
4. **Tags**: roughly 130 damaged shell-fork files; the Aug CLI files need a control check.
5. **Backlog**: 276 `/volume1` files no engine has looked at, plus all unstamped TV (7,005) waiting on the sweep, which is stopped.

## Limits

- Atmos names: a name match, so a floor.
- The tag control compares rates, so it estimates a count and names no file.
- "File gone" is by path: a renamed or HEVC-replaced file shows as gone, though it exists.
- Roots with `.neutraliser` sidecars carry left-alone reasons the TSV does not print; `skip_tol` reasons here come from the shell manifest.
