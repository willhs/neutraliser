---
type: note
status: active
owner: will
contributors: []
updated: 2026-08-08
review_cycle: 90d
agent_write: false
links: []
summary: "Prior-art survey: volume-normalisation tools on reddit/HN/GitHub, their traction and gaps"
tags: [research, positioning, release]
---
## Context / Purpose

Before investing in a public launch (README polish, demo, r/selfhosted / r/PleX / r/DataHoarder posts), find out whether this ground has already been covered — who else has built and shared a loudnorm-based leveller, what traction they got, and what they left unsolved. This decides positioning: is neutraliser "yet another ffmpeg-normalize wrapper," or does it have a genuine angle worth a public release?

Methodology: searched GitHub + web for competing tools, pulled GitHub star/activity data via the API, and read actual reddit threads (r/PleX, r/selfhosted, r/DataHoarder) via an authenticated browser session — not the Reddit API, which is closed to new registrations. Checked HN via the Algolia search API.

## Current State

### Direct competitors (loudness normalisation)

| Tool | Stars | Language | Status | Scope |
|---|---|---|---|---|
| [slhck/ffmpeg-normalize](https://github.com/slhck/ffmpeg-normalize) | 1,525 | Python | **Actively maintained** — updated within the last week, v1.41 as of Aug 2026 | General-purpose CLI/library. EBU R128, RMS, peak normalisation; presets (podcast/music/streaming-video); `--batch` album mode; Docker; Python API |
| [mdhiggins/sickbeard_mp4_automator](https://github.com/mdhiggins/sickbeard_mp4_automator) | 1,589 | Python | Maintained | Broader "standardise + tag a media library" tool (Sonarr/Radarr post-processing, container/codec conversion, metadata); normalisation is one feature among many |
| [indiscipline/ffmpeg-loudnorm-helper](https://github.com/indiscipline/ffmpeg-loudnorm-helper) | 23 | Rust | Maintained, low traffic | Interactive single-file helper — prints the ffmpeg filter string for you to paste, not a batch/library tool |
| [r0n0c/Normalize-Audio](https://github.com/r0n0c/Normalize-Audio) | 0 | Bash | Low activity | Near-identical concept to neutraliser: caches loudness analysis in JSON, skips files already in range, batch over `.mkv`. **Zero stars, no visible sharing anywhere** — proof the idea alone doesn't travel; execution/distribution is what's missing |
| auricgoldfinger/audio-normalize | 0 | Python | Dormant since 2020 | Basic ffmpeg loudnorm wrapper script |

**Key finding that changes positioning**: ffmpeg-normalize added `--threshold` (skip-files-already-at-target) in v1.40, released recently. The "skip already-normalised files" feature we were planning to lead with in the README is no longer a unique differentiator against the 1,500-star incumbent — it now matches ffmpeg-normalize's own recent work. It also lacks stream-metadata preservation depth and any library/Plex awareness, but "we skip files that don't need it" alone won't read as novel to anyone who's looked at ffmpeg-normalize's changelog.

### Adjacent competitors (transcode-automation platforms with normalisation as one flow)

| Tool | Stars | Notes |
|---|---|---|
| [HaveAGitGat/Tdarr](https://github.com/HaveAGitGat/Tdarr) | 4,261 | The dominant "run stuff against my whole library" tool in this space. Distributed transcode automation (FFmpeg/HandBrake) + library analytics + health checks. Runs as a server+node with a DB (originally MongoDB), has a plugin marketplace. Audio normalisation is achievable via a community flow/plugin, not a first-class feature. Launch thread on r/selfhosted (6 yrs ago): 114 points, 26 comments — genuinely well-received, and still active today (updated this week) |
| Unmanic | — | Same category as Tdarr — surfaced repeatedly in r/DataHoarder search alongside Tdarr. General-purpose library transcode automation, not normalisation-focused |

### What reddit actually says (read via browser, not API)

**r/PleX — "Constantly having to adjust volume!"** (51 pts, 55 comments, 5 yrs old, still getting replies in 2025) — this is the canonical version of the complaint neutraliser solves. Notable from the thread:
- Plex's own "Normalize Multi-Channel Audio" server setting is widely reported as **not actually fixing it** — it doesn't touch dynamic range within a file and doesn't apply to all clients.
- The community's actual workarounds are all client-side band-aids: soundbar "night mode," Windows "Loudness Equalization," buying a centre-channel soundbar, FxSound (a Windows audio enhancer).
- One 2024 comment explicitly names the real fix people already use: *"I use Tdarr to do this — creates a 2 channel audio and normalizes volume before it scans into Plex... 2 is the free but annoying option."* Confirms Tdarr is the incumbent "solve it once at the library level" answer, and that it's perceived as *annoying* to set up — an opening for a simpler single-purpose CLI.

**r/PleX — "Thought I'd share some ffmpeg scripts..."** (131 pts, 44 comments, submitted 2018, **still receiving comments as recently as 2024/2025**) — a hand-rolled Windows `.bat` script using ffmpeg's `loudnorm` + downmix + DRC, shared informally, no packaged tool/repo. Its longevity (new "thank you" comments 6+ years later) is itself a strong signal: this pain point is evergreen and a properly packaged, cross-platform tool would keep finding an audience the same way. Gaps versus neutraliser: Windows-only batch file, no macOS/Linux, no caching, no resume, no Plex-library scan, unmaintained since ~2020, requires editing scripts by hand.

**r/selfhosted — Tdarr launch thread**: 114 pts / 26 comments (2019), still the most-starred (4,261) tool anyone shares in this space when the topic is "process my whole library."

**r/DataHoarder**: searches for "Tdarr," "ffmpeg-normalize," "volume normalization" surfaced no dedicated volume-normalisation launch posts — only Tdarr/Unmanic threads (general transcode automation) and one "AV1 library squishing" post. Confirms: nobody has shared a *dedicated, lightweight* normalisation tool here. The audience's attention on this topic goes entirely to the two general-purpose transcode platforms.

**Hacker News** (via Algolia API, not scraped): essentially no traction for this niche. The only "Show HN" for an ffmpeg loudnorm tool (2019) got 1 point, 0 comments. HN is not a productive venue for this launch — skip it or treat it as a low-priority stretch, not a target community.

## Decisions / Rationale

1. **It's worth sharing.** The pain point is real, recurring, and evergreen (people are still commenting gratitude on a 2018 hand-rolled script thread). No one has shared a maintained, cross-platform, purpose-built CLI for this on any of the three target subreddits — the field is either (a) informal one-off scripts with no ongoing maintenance, (b) a general-purpose normalisation library with no library/Plex awareness, or (c) a heavyweight transcode-automation platform (Tdarr/Unmanic) where normalisation is a side feature bolted onto a server-and-DB setup people describe as "annoying."

2. **Drop "skip already-normalised" as the headline differentiator.** ffmpeg-normalize (1,525 stars, updated this week) shipped the same idea as `--threshold` recently. Keep it in the feature list, don't lead with it.

3. **Reposition around what's actually missing from the landscape:**
   - **Purpose-built for a Plex/video library, not general audio files.** `analyze-plex`, home-theatre-tuned profiles (reference/livingroom/night), and matching source codec/bitrate are things neither ffmpeg-normalize nor sickbeard_mp4_automator do.
   - **Single-purpose and lightweight vs. Tdarr/Unmanic.** No server, no node, no database, no plugin marketplace to configure — just a CLI you point at a directory. This directly answers the "2 is the free but annoying option" sentiment about Tdarr from the r/PleX thread.
   - **Resume manifest + local-staging for large batches** — genuinely not present in any competitor found; addresses the actual failure mode DataHoarder-scale libraries hit (interrupted runs over SMB/NFS).
   - **Maintained and cross-platform**, unlike the informal scripts that keep circulating on r/PleX with no owner.

4. **Target order stays r/PleX → r/selfhosted → r/DataHoarder.** r/PleX has the clearest, most recurring pain-point threads and the most direct audience (people who already run Plex against a library). r/selfhosted is where Tdarr/Unmanic get shared and compared — go there once the README's differentiation from Tdarr is sharp. r/DataHoarder has weaker signal for this specific niche (attention goes to transcoding, not normalisation) — still worth a post but expect less traction than the other two. Skip HN or treat as optional/low-effort — no evidence of an audience there.

5. **Demo priority**: the r/PleX thread makes clear the audience doesn't trust "trust me, it's normalised" — they've been burned by Plex's own broken setting. A before/after loudness graph or waveform comparison (not just a claim) will land better than prose alone.

## Next Actions
- [ ] README: cut or downplay "skip-already-normalised" as a headline feature; lead with Plex-library-awareness + lightweight single-binary-CLI vs. Tdarr/Unmanic instead.
- [ ] README/positioning: explicitly (briefly, factually, no disparagement) note the Tdarr/ffmpeg-normalize alternative and why neutraliser is a better fit for "I just want my Plex library level, nothing else."
- [ ] Demo: build the before/after loudness comparison (graph or waveform), not just a terminal recording — the audience is skeptical of unverified claims.
- [ ] Drop/deprioritise an HN post; no evidence of an audience for this niche there.

## References / Links
- https://github.com/slhck/ffmpeg-normalize (1,525★, actively maintained, `--threshold` skip-logic added v1.40)
- https://github.com/mdhiggins/sickbeard_mp4_automator (1,589★)
- https://github.com/HaveAGitGat/Tdarr (4,261★)
- https://github.com/indiscipline/ffmpeg-loudnorm-helper (23★)
- https://github.com/r0n0c/Normalize-Audio (0★ — same concept as neutraliser, no distribution)
- https://old.reddit.com/r/PleX/comments/l233fo/constantly_having_to_adjust_volume/ (51pts/55 comments)
- https://old.reddit.com/r/PleX/comments/9rc7sp/thought_id_share_some_ffmpeg_scripts_i_made_to/ (131pts/44 comments)
- https://old.reddit.com/r/PleX/comments/1at4hy6/my_solution_for_plex_sound_being_too_low/ (client-side workaround thread, low relevance but shows appetite)
- https://old.reddit.com/r/selfhosted/comments/diy66s/tdarr_audiovideo_library_analytics_transcode/ (114pts/26 comments, Tdarr launch)
- HN Algolia search: "loudnorm"/"ffmpeg-normalize"/"volume normalization" — no meaningful traction found (best result: 1 point)

### Change Log
- 2026-08-08 (agent:steady-task e2589b88): Completed prior-art survey — filled in landscape.md with GitHub competitor data, reddit thread findings (via browser, API unavailable), and HN search. Positioning recommendation: drop "skip-already-normalised" as headline differentiator (ffmpeg-normalize now has it), lead with Plex-awareness + lightweight-vs-Tdarr instead.
- 2025-09-24 (agent:create-project): Created landscape placeholder
