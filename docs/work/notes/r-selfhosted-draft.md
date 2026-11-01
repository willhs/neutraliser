---
type: note
status: draft
owner: will
contributors: []
updated: 2026-11-01
review_cycle: 30d
agent_write: false
links: []
summary: "Draft r/selfhosted post for Will to edit (not posted)"
tags: [release, community, draft]
---

# r/selfhosted draft

## Self-promotion rules (partly verified, check live)

From search snippets of the r/selfhosted wiki rules (page itself would not load; confirm on the sidebar/wiki):

- Projects under 3 months old, measured from first public presence (git commit or social post), reportedly belong only in the weekly **New Project Megathread**, not standalone posts. The repo's first commit is 2025-09-24, but whether it counts as public that early is yours to judge; the 0.1.0 release is 2026-10-31.
- Promoted apps are expected to be production-ready and documented.
- Don't over-promote; mention your own project in comments only where relevant.
- Tools that help self-hosters are reportedly allowed on a specific weekday with the right flair.
- Nothing found on AI-assisted projects. If Claude wrote much of this, check whether the rules want it disclosed, and be upfront either way.

Landscape note: this is where Tdarr's launch thread did well (114 points), so differentiation from Tdarr must be clear. 

## Claims audit (2026-11-01, this tree)

Every claim in the body was checked against the README, `demo/README.md`, the code or a run in this job. Left out on purpose: the August "716 of 804 films within 1 LU" figure and the ten-film real-library chart (they predate the constant-gain default, and the films were picked from processed files). The synthetic figures were re-run 2026-11-01 on FFmpeg 7.1.1 (`demo/README.md#verified-synthetic-rerun`) and are pink noise, not films.

**`analyze-plex`:** movie libraries were measured against your live Plex server in October (the sampling research). TV libraries returned nothing until this job (a show library's `/all` lists shows, which carry no media), so it now asks for episodes. That is tested against a fake Plex server only, so the draft says so.

**Not verified by anyone but you** (kept only as first-person statements, or marked): what Plex's own settings do on your clients, your August library run, and anything said about other tools (star counts, features), which comes from `docs/research/landscape.md` (2026-08-08), not from a fresh look.

Plex facts re-read from Plex's announcement on 2026-11-01; Jellyfin's music-only claim is from `AudioNormalizationTask.cs` on master as read in research 0002 (not re-fetched in this job). Re-check both before posting. Jellyfin users may be a better audience than assumed here, since they have no video option at all.

## Title options

- Neutraliser: levels the audio across a media library, one CLI, no server or database
- Self-hosted Plex annoyance fixed at the file level: a small CLI for volume jumps between films

## Body

I run my own media library and got fed up with volume jumping between films. I wrote a small CLI, Neutraliser, that fixes it once, in the files.

Why not the built-in options: Plex added Normalize Loudness in Sept 2026, but it needs Plex Pass, transcodes the audio on every play, and needs client support. Jellyfin's loudness normalisation task only covers music (`MediaTypes = [Audio]` in its source), so there's nothing for video. A one-time change to the file works on any client, direct play included, at the cost of one audio re-encode.

It's one job: measure each file with ffmpeg's EBU R128 loudnorm filter, then apply one constant gain to reach a target (-20 LUFS by default). No daemon, no database, no web UI. Point it at a directory.

```
docker run --rm --user $(id -u):$(id -g) -v /path/to/media:/media \
  ghcr.io/willhs/neutraliser:latest process --resume /media/movies
```

Things that matter if you run it on a NAS:

- Safe by default: writes `*_normalized` copies. `--replace` writes under a hidden temp name, checks the result against the source, then renames. A file that changes mid-run is left alone
- Video stream-copied; only the main audio track re-encoded, at the source's codec and bitrate
- Every change is recorded in `NEUTRALISER_*` tags on the track (so records survive renames). AVI and some MP4s with cover art fall back to a sidecar. `neutraliser report` reads it all back
- `--resume` uses a manifest written as each file finishes. `--local-stage` copies to local disk first for slow SMB/NFS mounts
- A free-space floor checked before each file (`--min-free-gb`), a flock run lock, and a fail-fast check that the folder is writable
- Files already tagged for the same profile are skipped without re-measuring, so a re-run over a done library is cheap
- Atmos and DTS:X are skipped and logged rather than flattened (detection needs FFmpeg 7.1+, which the Docker image has; older ffmpeg only catches files named as Atmos)
- Optional `analyze-plex` triage (read-only, uses your Plex token, which is visible in `ps` while a title is read). Sampled results say "Unclear" when the sample can't support a verdict. Movie libraries are tested on a real server; TV libraries only against a stand-in so far

Measured, not claimed: 4 synthetic pink-noise clips played back to back went from a 15.5 LU swing to 0.3 LU, measured with ebur128 rather than the loudnorm filter used to decide. The scripts in `demo/` re-run it on copies of your own library. Real films with high peaks can land short of target, because gain is capped at the profile's true-peak ceiling (-1.5 dBTP). The log says by how much.

How it differs from the usual answers:

- (Third-party facts below are from the 2026-08-08 landscape note: refresh before posting.)
- **Tdarr / Unmanic**: better if you want a general transcode pipeline with workers and a plugin ecosystem. Normalisation there is a community flow. Neutraliser is the opposite trade: narrow and no infrastructure
- **ffmpeg-normalize**: the mature general-purpose tool (1.5k stars, actively maintained, also does audio files and has a Python API). It now has a threshold to skip files already at target too. Neutraliser is narrower and built around Plex-style video libraries and resumable big runs
- **sickbeard_mp4_automator**: Sonarr/Radarr post-processing where this is one feature among many

MIT licensed, v0.1, Ruby 3.2+ or Docker. Not on RubyGems yet.
https://github.com/willhs/neutraliser

## Notes for Will

- Star counts are from the 2026-08-08 landscape note; refresh before posting.
- The workflow publishes `ghcr.io/willhs/neutraliser:latest` on every push to main, and anonymous pulls worked at the pre-release review. Confirm it still pulls before posting.
- `--replace` breaks hard links (the old copy stays under its other names). It's in the README; consider saying so if your audience seeds from the same files.
- Not claimed: any speed numbers, any "89%" library figure.
