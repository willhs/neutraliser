---
type: note
status: active
owner: will
contributors: []
updated: 2026-11-15
review_cycle: 90d
agent_write: false
links: ["../philosophy/vision.md", "0002-streaming-loudness-and-dialogue/research.md"]
summary: "Prior-art survey: volume-normalisation tools, how each handles dialogue and wide mixes, and neutraliser's honest one-line claim against them"
tags: [research, positioning, release]
---
## Context / Purpose

Before investing in a public launch (README polish, demo, r/selfhosted / r/PleX / r/DataHoarder posts), find out whether this ground has already been covered — who else has built and shared a loudnorm-based leveller, what traction they got, and what they left unsolved. This decides positioning: is neutraliser "yet another ffmpeg-normalize wrapper," or does it have a genuine angle worth a public release?

Methodology: searched GitHub + web for competing tools, pulled GitHub star/activity data via the API, and read actual reddit threads (r/PleX, r/selfhosted, r/DataHoarder) via an authenticated browser session — not the Reddit API, which is closed to new registrations. Checked HN via the Algolia search API.

## Answer (2026-11-15): positioning check

Vision alignment: Have an online presence (goal: Release neutraliser publicly). Confidence labels: **[Verified]** primary source read (docs, source, release notes, or run locally), **[Reported]** forum/blog/user report, **[Not found]** looked, nothing there. Pages were mostly read through a summarising fetch tool, so re-check any quote before it goes into public copy.

**Premise check.** The task notes say the vision doc lists "no compression was a selling point against ffmpeg-normalize" and "I haven't verified how competitors handle this". Neither phrase is in `docs/philosophy/vision.md`; the nearest text is the positioning paragraph in [research 0002](0002-streaming-loudness-and-dialogue/research.md) (Plex section). The worry behind them holds up in part: "no compression" never separated neutraliser from ffmpeg-normalize, whose EBU mode is linear by default [Verified]. What does separate them is below.

**Does anything level a library on dialogue? No.** I found no open-source or consumer tool that rewrites files to a dialogue level using speech detection [Not found; GitHub search was shallow and Reddit was not searchable, so this is absence of evidence]. Dialogue-gated measurement exists only as professional products: Dolby's speech-gating reference code (licence excludes "products intended for Consumer use"), NUGEN, Auphonic (cloud, makes a new file) [Verified/Reported, detail below]. EBU R 128 s4 (Nov 2023) endorses dialogue-anchored loudness for cinematic content [Verified]. The consumer tools that mention dialogue are playback-time and frequency-based (Plex Boost Dialog, Sonos, Prime, tvOS), not level-matching.

**But neutraliser does not do it yet either.** Today's default is constant gain anchored on whole-programme loudness (-20 LUFS), peak-capped. The ladder is real (gain, then `--limit-db` limiter, then opt-in `--lra-target` / `--centre-boost` compression), but dialogue is only a read-only estimate (`--measure`, `rate-sample`); the dialogue-anchored default is vision, not shipped ([roadmap](../work/roadmap.md), README "Where we are"). So the launch claim must not say "levels on dialogue". It may say what the ladder does, and that dialogue targeting is the stated direction.

### The honest one-line claim

> **Neutraliser changes the files once, so every client levels the same: constant gain by default (never silently compressed), a limiter or compression only if you ask, and each file reports what was done.**

Shorter form for post titles: *"Level a video library once, in the files, with constant gain: no per-play transcode, no Plex Pass, no server."*

What backs each clause, against the closest alternatives:

| Clause | ffmpeg-normalize | Plex Normalize Loudness / Boost Dialog | Tdarr / Unmanic plugins |
|---|---|---|---|
| Changes the **file** once | Yes, new file (or overwrite) | No, playback only; audio transcoded on every play | Yes |
| **Constant** gain, guaranteed | EBU "linear" is the default but `loudnorm` "will still fall back to dynamic mode" with a console warning [Verified]; no EBU option that refuses to go dynamic (peak and RMS types are always linear) | Method undisclosed; third-party doc says `loudnorm` analysis (I=-16, LRA 9), gain at playback [Reported] | Tdarr: two-pass `linear=true` but dynamic fallback applies as above; Unmanic `normalise_aac`: single-pass `loudnorm`, i.e. dynamic by ffmpeg default [Verified, inferred from ffmpeg docs] |
| **Compression** only on request | Only via `--dynamic` / LRA flags | Normalize Loudness "takes the edge off very loud scenes" (it does compress) | None built in |
| **Source codec** kept, bitrate headroom | PCM unless `-c:a` given; docs warn about generation loss | Transcodes to AAC on play [Reported] | Tdarr plugin: first track to AAC 192k; Unmanic: AAC only |
| Reports **per file** what it did, skips by stamp | Stateless; `--threshold` re-measures each run | n/a | Tdarr: `NORMALISATIONSTAGE` tag; Unmanic: settings marker |
| Works on **any client, direct play** | Yes | No: Plex Pass, partial client support | Yes |

What neutraliser must not claim: "the only tool that skips already-normalised files" (ffmpeg-normalize `--threshold` since 1.40.0, 2026-06-27; Unmanic and Tdarr have markers), "no compression" as a differentiator on its own, "Plex's setting doesn't work" (one user report of an E-AC3 crash is not that), or anything about dialogue levelling being live.

What it can claim, because it is checked in this repo: strictly constant gain from the `volume` filter (shortfall reported, never a silent dynamic fallback); Dolby DRC and dialnorm handled so "constant" stays constant on AC-3/E-AC-3 (`DolbyStream`); source codec at 1.25x the first-generation bitrate; stream-metadata, chapters and other tracks kept (`RemuxPlan`); `--keep-original-audio`; resumable library runs that skip by an in-file stamp rather than re-measuring. ffmpeg-normalize's docs do not mention Dolby DRC or dialnorm handling [Not found in docs and `--help`; absence only].

### Side-by-side (what it changes, re-encodes, wide mixes, install friction)

Dates are as of 2026-11-15 unless stated.

| Tool | Changes | Re-encodes | Wide mixes (5.1/7.1) | Dialogue-aware | Install friction |
|---|---|---|---|---|---|
| **neutraliser** (this repo) | File, once | Primary track only, source codec +25% bitrate; video/subs/other audio copied | Normalises the primary track on its own layout; `--centre-boost` lifts 5.1 centre (opt-in); dialogue only *measured* (centre channel) | Estimate only, not used for the gain | Ruby + ffmpeg (Docker image) |
| **ffmpeg-normalize** 1.44.0 (2026-11-09), 1,542★ | File (new `normalized/*.mkv` by default; overwrite possible) | Always the selected audio; codec default PCM, `-c:a` to choose; video `copy`; `--keep-other-audio`, metadata/chapters mapped | No dedicated handling; issue #316 (5.1 to stereo peak wrong) fixed 1.37.8, 2026-05-21 | **No**: no speech/dialogue/centre options in docs or `--help` (checked locally on 1.44.0); issue #253 got "downmix first with ffmpeg"; FAQ points to `speechnorm` | `pipx`/`uvx`/pip or Docker; Python >=3.10 |
| **Plex Normalize Loudness / Boost Dialog** (PMS 1.43.4, announced 2026-09-15) | Playback; analysis result stored in the server DB | Audio transcoded on every play with either on | Not stated; Dialog Boost crashes the transcoder on E-AC3 (forum, 2026-10-22, open 2026-11-13) [Reported] | Boost Dialog = frequency boost ("isolates the frequencies where dialog lives"); Normalize Loudness = whole-track `loudnorm` [Reported]. Not dialogue-level matching | Plex Pass for the admin (analysis) and the viewer; clients: mobile, Apple TV, Fire TV, Roku; Android TV preview; Web/Smart TV "coming soon" (X post 2026-09-24; nothing newer found). Reports of 10+ GB RAM, high CPU, no whole-library Analyze |
| **Plex older** Normalize Multi-Channel / boost | Playback, downmix only | Only when downmixing | Downmix only | No | Free |
| **Jellyfin** (to 12.x) | Music: stored value, client gain. Video: nothing | Transcode path: downmix + fixed `volume=` gain | Downmix algorithm and fixed boost; `NightmodeDialogue` pan weights centre | No | Free. No `loudnorm`/`dynaudnorm` in `EncodingHelper.cs` (read 2026-11-15) [Verified]; mod: normalisation "is only for music" (2025-02-28) [Reported] |
| **Emby** | Playback | Only when server downmixes (Audio Boost, default 2x) | Downmix boost only | No | Staff 2025-03-23 on video volume levelling: "possibly for future updates" [Reported] |
| **Kodi** | Playback | No (client DSP) | "Maintain original volume on downmix"; volume amplification routes through DRC for video (PR #20131, 2021) | No | Free; DRC/amplification need decoded PCM (passthrough bypasses) [Reported]. Kodi wiki returned 403 |
| **VLC / mpv / Infuse / Shield / Apple TV** | Playback | No | VLC compressor; mpv user-supplied `loudnorm`/`dynaudnorm` af; Infuse "Downmix: Normalize" is not a leveller (staff); Shield "night listening mode"; tvOS "Reduce Loud Sounds" and "Enhance Dialogue" | Apple Enhance Dialogue and Plex-like boosts are speech-band, per device | Free; per-device, per-app |
| **Soundbars / AVRs** (Dolby dialnorm + DRC, Sonos Night Sound / Speech Enhancement, Samsung Voice Enhance) | Playback | No | Decoder-dependent | Speech-band boosts | Hardware. DRC only works if the stream still carries the metadata and the player passes it through (Infuse thread 2025-11-08 suspects it ignores AC-3 DRC) [Reported] |
| **Tdarr** 4,398★ (Docker image 3.08.00, 2026-11-13) | File | Classic plugin `..._2_Pass_Loudnorm_Audio_Normalisation`: first audio track to AAC 192k; flow `normalizeAudio` (fixed 2026-03-23, `maxGain` 15 LU): AAC 192k, `-map 0 -c copy` | Only first audio stream; no channel options | **None**: no dialogue/night-mode plugin found. `jeons001_Downmix_to_stereo_and_apply_DRC` is blind `dynaudnorm` + centre at 0.707 | Server + node(s); Docker; DB. Plugin repo 229★ |
| **Unmanic** 2,559★ (0.4.1, 2026-08-14) | File | `normalise_aac` v0.1.0: AAC streams only, single-pass `loudnorm`, keeps container | Keeps source channel count | None | Server + web UI. Plugin repo 44★. Has `notify_plex`/`notify_sonarr` plugins |
| **jellyfin-audio-normalizer** (goddenrich fork, 0★) | File, replaces original | AAC 192k, video copied [Reported, search summary] | `loudnorm` I=-16 LRA 11 | No | Bash |
| **ReplayGain taggers** (rsgain 735★, loudgain 233★, mkvrg 13★) | Tags only | No | n/a | No | Needs a player that honours tags; most video players don't [Inferred] |

### Gaps in this check

- Reddit threads were not searchable by the tools used; the older Reddit findings below were read by browser on 2026-08-08 and are not refreshed. Do a manual look at r/PleX, r/selfhosted and r/jellyfin for "normalize loudness" posts since 2026-09-15 before posting.
- Plex's support articles, the Kodi wiki, Sonos and Sony/LG pages returned 403 or were not reachable; Plex rows rest on the announcement thread and forum reports. No Plex statement on 5.1 handling or on whether the gain is dialogue-gated. Plex's playback filter is unconfirmed.
- Tdarr's version numbering (GitHub tags stop at 2020; Docker says 3.08.00) is unreconciled. Third-party Tdarr/Unmanic plugin repos were not covered.
- Plugin source behaviour (ffmpeg-normalize `_media_file.py`, Tdarr/Unmanic plugins) was read through a summariser, not a clone. `--threshold`'s conditions were confirmed in `--help` locally; the rest should be re-read before it appears in public copy.

## Current State (survey of 2026-08-08, with 2026-11-15 corrections)

### Direct competitors (loudness normalisation)

| Tool | Stars | Language | Status | Scope |
|---|---|---|---|---|
| [slhck/ffmpeg-normalize](https://github.com/slhck/ffmpeg-normalize) | 1,542 (1,525 in Aug) | Python | **Actively maintained** — v1.44.0 released 2026-11-09 (v1.41 as of Aug 2026) | General-purpose CLI/library. EBU R128, RMS, peak normalisation; presets (podcast/music/streaming-video); `--batch` album mode; Docker; Python API |
| [mdhiggins/sickbeard_mp4_automator](https://github.com/mdhiggins/sickbeard_mp4_automator) | 1,589 | Python | Maintained | Broader "standardise + tag a media library" tool (Sonarr/Radarr post-processing, container/codec conversion, metadata); normalisation is one feature among many |
| [indiscipline/ffmpeg-loudnorm-helper](https://github.com/indiscipline/ffmpeg-loudnorm-helper) | 23 | Rust | Maintained, low traffic | Interactive single-file helper — prints the ffmpeg filter string for you to paste, not a batch/library tool |
| [r0n0c/Normalize-Audio](https://github.com/r0n0c/Normalize-Audio) | 0 | Bash | Low activity | Near-identical concept to neutraliser: caches loudness analysis in JSON, skips files already in range, batch over `.mkv`. **Zero stars, no visible sharing anywhere** — proof the idea alone doesn't travel; execution/distribution is what's missing |
| auricgoldfinger/audio-normalize | 0 | Python | Dormant since 2020 | Basic ffmpeg loudnorm wrapper script |

**Key finding that changes positioning**: ffmpeg-normalize added `--threshold` (skip-files-already-at-target) in v1.40 (2026-06-27 per its CHANGELOG; re-confirmed in `--help` of 1.44.0 on 2026-11-15; it copies skipped files through unchanged and has no effect in batch mode or with a downmix or filter). The "skip already-normalised files" feature we were planning to lead with in the README is no longer a unique differentiator against the 1,500-star incumbent — it now matches ffmpeg-normalize's own recent work. It also lacks stream-metadata preservation depth and any library/Plex awareness, but "we skip files that don't need it" alone won't read as novel to anyone who's looked at ffmpeg-normalize's changelog.

### Adjacent competitors (transcode-automation platforms with normalisation as one flow)

| Tool | Stars | Notes |
|---|---|---|
| [HaveAGitGat/Tdarr](https://github.com/HaveAGitGat/Tdarr) | 4,261 | The dominant "run stuff against my whole library" tool in this space. Distributed transcode automation (FFmpeg/HandBrake) + library analytics + health checks. Runs as a server+node with a DB (originally MongoDB), has a plugin marketplace. Audio normalisation is achievable via a community flow/plugin, not a first-class feature. Launch thread on r/selfhosted (6 yrs ago): 114 points, 26 comments — genuinely well-received, and still active today (updated this week) |
| Unmanic | 2,559 | Same category as Tdarr (loudness plugin: `normalise_aac`, AAC only; see the table above) — surfaced repeatedly in r/DataHoarder search alongside Tdarr. General-purpose library transcode automation, not normalisation-focused |

### What reddit actually says (read via browser, not API)

**r/PleX — "Constantly having to adjust volume!"** (51 pts, 55 comments, 5 yrs old, still getting replies in 2025) — this is the canonical version of the complaint neutraliser solves. Notable from the thread:
- **Update (2026-11-01):** this thread predates Plex's 15 Sep 2026 [Normalize Loudness and Boost Dialog](https://forums.plex.tv/t/audio-enhancements-boost-dialog-normalize-loudness/942925) for video (re-read 2026-11-01, unchanged). Facts: Plex Pass; enabling either option transcodes the audio; Plex Media Server 1.43.4+; clients at announcement were mobile, Android TV, Apple TV, Fire TV, Roku, with Web, Smart TVs and desktop "coming soon"; method undisclosed. So "Plex's setting doesn't fix it" is no longer a safe line (see `0002-streaming-loudness-and-dialogue/research.md`). The honest difference is per-play transcode plus Plex Pass plus client support versus a one-time file change that works on any client, direct play included, at the cost of one re-encode. Jellyfin's normalisation task is music only (`MediaTypes = [Audio]`), so Jellyfin users may be a better audience than assumed.
- Plex's older "Normalize Multi-Channel Audio" server setting was widely reported (in this thread) as **not actually fixing it** — it doesn't touch dynamic range within a file and doesn't apply to all clients.
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
   - **Resume manifest + local-staging for large batches** — not found in the competitors checked (2026-11-15: Tdarr and Unmanic keep a per-file "done" marker, which is not a resumable manifest); addresses the actual failure mode DataHoarder-scale libraries hit (interrupted runs over SMB/NFS).
   - **Maintained and cross-platform**, unlike the informal scripts that keep circulating on r/PleX with no owner.

4. **Target order stays r/PleX → r/selfhosted → r/DataHoarder.** r/PleX has the clearest, most recurring pain-point threads and the most direct audience (people who already run Plex against a library). r/selfhosted is where Tdarr/Unmanic get shared and compared — go there once the README's differentiation from Tdarr is sharp. r/DataHoarder has weaker signal for this specific niche (attention goes to transcoding, not normalisation) — still worth a post but expect less traction than the other two. Skip HN or treat as optional/low-effort — no evidence of an audience there.

5. **Demo priority**: the r/PleX thread makes clear the audience doesn't trust "trust me, it's normalised" — they've been burned by Plex's own broken setting. A before/after loudness graph or waveform comparison (not just a claim) will land better than prose alone.

## Next Actions
- [ ] (2026-11-15) Use the one-line claim in "Answer" for the README lead and post titles; keep "dialogue levelling" as stated direction only until the roadmap's validation step passes.
- [ ] (2026-11-15) Before the r/PleX post: manual Reddit check for "Normalize Loudness" threads since 2026-09-15, and confirm Plex Web/Smart TV status (still "coming soon" at 2026-09-24).
- [ ] (2026-11-15) Re-read ffmpeg-normalize `_media_file.py` from a clone before quoting `--threshold` conditions publicly.
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

- 2026-11-15 sources: https://slhck.info/ffmpeg-normalize/usage/normalization-options/ , https://github.com/slhck/ffmpeg-normalize/releases , https://forums.plex.tv/t/audio-enhancements-boost-dialog-normalize-loudness/942925 , https://forums.plex.tv/t/plex-transcoder-crashes-when-dialog-boost-is-enabled-for-eac3-audio/944959 , https://github.com/HaveAGitGat/Tdarr_Plugins , https://github.com/Unmanic/unmanic-plugins , https://tech.ebu.ch/docs/r/r128s4.pdf , https://professional.dolby.com/support/dolbys-speech-gating-reference-code/ , https://github.com/jellyfin/jellyfin/blob/master/MediaBrowser.Controller/MediaEncoding/EncodingHelper.cs , https://emby.media/support/articles/Transcoding.html , https://github.com/xbmc/xbmc/pull/20131 , https://github.com/stevezau/media_preview_generator/blob/dev/docs/plex-loudness-normalization.md

### Change Log
- 2026-11-15 (agent:steady-task 7b9b5a42): Positioning check. Added the Answer section (side-by-side table, dialogue-levelling finding, one-line claim), refreshed ffmpeg-normalize (1.44.0) and Tdarr/Unmanic facts, ran `ffmpeg-normalize --help` locally to confirm `--threshold` and the absence of dialogue options.
- 2026-08-08 (agent:steady-task e2589b88): Completed prior-art survey — filled in landscape.md with GitHub competitor data, reddit thread findings (via browser, API unavailable), and HN search. Positioning recommendation: drop "skip-already-normalised" as headline differentiator (ffmpeg-normalize now has it), lead with Plex-awareness + lightweight-vs-Tdarr instead.
- 2025-09-24 (agent:create-project): Created landscape placeholder
