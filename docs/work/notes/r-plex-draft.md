---
type: note
status: draft
owner: will
contributors: []
updated: 2026-11-01
review_cycle: 30d
agent_write: false
links: []
summary: "Draft r/PleX post for Will to edit (not posted)"
tags: [release, community, draft]
---

# r/PleX draft

**Do not post until you have read the live rules.** I could not load reddit.com from the job (blocked) and found no copy of the r/PleX rules, so the self-promotion rule is **unverified**. Generic expectations only: many subs cap self-promotion near 10% of your activity there, so comment helpfully in volume threads first. Check the sidebar, flair options (look for a "Software"/"Tool" style flair) and whether open-source projects are exempt. Landscape note says r/PleX is the clearest audience: the "Constantly having to adjust volume!" thread (55 comments) and the 2018 ffmpeg-scripts thread.

## Claims audit (2026-11-01, this tree)

Plex's Normalize Loudness / Boost Dialog facts re-read from Plex's announcement on 2026-11-01 (no update to the post; Web/Smart TV still listed "coming soon"). Re-check the thread right before posting: client support may have shipped. If it has, soften "need client support" to "need a supporting client" and keep the Plex Pass and per-play transcode points. I haven't tested these Plex features, so the draft makes no claim about how well they work.

Every claim in the body was checked against the README, `demo/README.md`, the code or a run in this job. Left out on purpose: the August "716 of 804 films within 1 LU" figure and the ten-film real-library chart (they predate the constant-gain default, and the films were picked from processed files). The synthetic figures were re-run 2026-11-01 on FFmpeg 7.1.1 (`demo/README.md#verified-synthetic-rerun`) and are pink noise, not films.

**`analyze-plex`:** movie libraries were measured against your live Plex server in October (the sampling research). TV libraries returned nothing until this job: a show library's `/all` lists shows, which carry no media, so it now asks for episodes. That is tested against a fake Plex server only. Run it on a real TV library before you post the TV claim.

**Not verified by anyone but you** (kept only as first-person statements, or marked): what Plex's own settings do on your clients, your August library run, and anything said about other tools (star counts, features), which comes from `docs/research/landscape.md` (2026-08-08), not from a fresh look.

## Title options

- I got tired of reaching for the remote between films, so I wrote a tool that levels a whole library
- Fix volume jumps between films once, at the file level (free, open source CLI)

Title note: don't say "Plex's setting doesn't work". Say what is different.

## Body

My workarounds for volume jumps between films were soundbar night mode and the remote. Plex now has Normalize Loudness and Boost Dialog (Sept 2026, Plex Pass). They work at playback: Plex transcodes the audio on every play, and they need client support (Web and Smart TV apps were "coming soon" at the announcement). I wanted the opposite trade: change the file once, so every client plays it level, direct play included, no Plex Pass needed.

So I wrote Neutraliser. It costs one audio re-encode per file, once. It measures each file with ffmpeg's EBU R128 loudnorm filter and moves it to the same loudness with one constant gain. No compression by default, so quiet scenes stay quiet relative to loud ones. Only the overall level moves.

What it does to a file:

- Video is stream-copied (MD5-identical in my test)
- Only the main audio track is re-encoded, at the source's own codec and bitrate (files whose codec it can't re-encode to itself, like DTS or TrueHD, are skipped unless you pass `--allow-codec-change`)
- Other audio tracks, subtitles, chapters and language tags are kept
- Writes `*_normalized` copies by default. `--replace` is opt-in, and `--keep-original-audio` keeps the untouched track as an extra track
- Atmos and DTS:X files are skipped and logged, not flattened. Detection needs FFmpeg 7.1+; on older ffmpeg it warns and only catches files named as Atmos
- Interrupted a big run? `--resume` carries on

```
neutraliser process /media/movies --profile livingroom
```

There's also `neutraliser analyze-plex`, which reads loudness over Plex's own stream and changes nothing. By default it samples five 60s windows per title, so it only gives a verdict when the error range allows it and otherwise says "Unclear". `--full` measures end to end, at roughly 2 to 7 minutes a film. I've run it on a real movie library. TV libraries (it reads the episodes) are new and I've only tested them against a stand-in server, so tell me if yours misbehaves.

Does it work? On 4 synthetic clips played back to back, the swing in short-term loudness went from 15.5 LU to 0.3 LU. I measured it with ffmpeg's ebur128 filter, not the loudnorm filter the tool uses, so it isn't marking its own homework. Those clips are pink noise with plenty of headroom. Real films are messier: because gain is capped at the profile's true-peak ceiling (-1.5 dBTP), a quiet but peaky film can land short of -20 LUFS (the log tells you by how much). `demo/ab.rb` builds before.mkv and after.mkv from your own files so you can listen to the difference.

Honest caveats: it's v0.1, run from source or Docker (not on RubyGems), and a lossy re-encode still costs one generation of quality. Files already close to target are left alone for that reason.

Alternatives, if they suit you better: Tdarr is great if you want a general transcode pipeline (it can normalise via a community flow, but it's a server plus nodes). ffmpeg-normalize is the flexible general-purpose option and works on audio files too.

Repo: https://github.com/willhs/neutraliser
Happy to hear what breaks on your setup.

## Notes for Will

- Add the chart: `demo/loudness-over-time.svg` (captioned synthetic). Reddit wants an image upload or link, not SVG, so export a PNG.
- The Tdarr quote in the landscape note is a 2024 commenter; don't quote it without permission.
- Say once, in your own words, that you're the author.
