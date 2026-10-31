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

## Claims checked against main (801ea90)

Everything in the draft maps to the README or `demo/README.md` on main. Left out on purpose: the August "716 of 804 films within 1 LU" figure and the ten-film real-library chart (they predate the constant-gain default and the films were picked from processed files). If you want them, keep the caveat: "from v0.1 first runs in August 2026, two-pass loudnorm, ten films picked from processed files, not random". The synthetic figures below were re-run 2026-11-01 on FFmpeg 7.1.1 (`demo/README.md#verified-synthetic-rerun`) and are pink noise, not films.

## Title options

- Neutraliser: levels the audio across a media library, one CLI, no server or database
- Self-hosted Plex annoyance fixed at the file level: a small CLI for volume jumps between films

## Body

I run my own media library and got fed up with volume jumping between films. I wrote a small CLI, Neutraliser, that fixes it once, in the files.

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
- Disk floors (`--min-free-gb`), a flock run lock, and a fail-fast check that the folder is writable
- Files already tagged for the same profile are skipped, so a re-run over a done library takes seconds
- Atmos and DTS:X are skipped and logged rather than flattened (needs FFmpeg 7.1+; the Docker image has it)
- Optional `analyze-plex` triage (read-only, uses your Plex token). Sampled results say "Unclear" when the sample can't support a verdict

Measured, not claimed: 4 synthetic pink-noise clips played back to back went from a 15.5 LU swing to 0.4 LU, measured with ebur128 rather than the loudnorm filter used to decide. The scripts in `demo/` re-run it on copies of your own library. Real films with high peaks can land short of target, because gain is capped at -1.5 dBTP. The log says by how much.

How it differs from the usual answers:

- **Tdarr / Unmanic**: better if you want a general transcode pipeline with workers and a plugin ecosystem. Normalisation there is a community flow. Neutraliser is the opposite trade: narrow and no infrastructure
- **ffmpeg-normalize**: the mature general-purpose tool (1.5k stars, actively maintained, also does audio files and has a Python API). It now has a threshold to skip files already at target too. Neutraliser is narrower and built around Plex-style video libraries and resumable big runs
- **sickbeard_mp4_automator**: Sonarr/Radarr post-processing where this is one feature among many

MIT licensed, v0.1, Ruby 3.2+ or Docker. Not on RubyGems yet.
https://github.com/willhs/neutraliser

## Notes for Will

- Star counts are from the 2026-08-08 landscape note; refresh before posting.
- Docker image is published on every push to main (README); confirm it pulls before posting.
- Not claimed: any speed numbers, any "89%" library figure.
