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

## Claims checked against main (801ea90)

Everything in the draft maps to the README or `demo/README.md` on main. Left out on purpose: the August "716 of 804 films within 1 LU" figure and the ten-film real-library chart (they predate the constant-gain default and the films were picked from processed files). If you want them, keep the caveat: "from v0.1 first runs in August 2026, two-pass loudnorm, ten films picked from processed files, not random". The synthetic figures below were re-run 2026-11-01 on FFmpeg 7.1.1 (`demo/README.md#verified-synthetic-rerun`) and are pink noise, not films.

## Title options

- I got tired of reaching for the remote between films, so I wrote a tool that levels a whole library
- Fix volume jumps between films once, at the file level (free, open source CLI)

## Body

Plex's "Normalize Multi-Channel Audio" setting never fixed this for me. It doesn't touch the level difference between films, and it doesn't apply on every client. My workarounds were soundbar night mode and the remote.

So I wrote Neutraliser. It measures each file with ffmpeg's EBU R128 loudnorm filter and moves it to the same loudness with one constant gain. No compression by default, so quiet scenes stay quiet relative to loud ones. Only the overall level moves.

What it does to a file:

- Video is stream-copied (MD5-identical in my test)
- Only the main audio track is re-encoded, at the source's own codec and bitrate
- Other audio tracks, subtitles, chapters and language tags are kept
- Writes `*_normalized` copies by default. `--replace` is opt-in, and `--keep-original-audio` keeps the untouched track as an extra track
- Atmos and DTS:X files are skipped and logged, not flattened (detecting them needs FFmpeg 7.1+)
- Interrupted a big run? `--resume` carries on

```
neutraliser process /media/movies --profile livingroom
```

There's also `neutraliser analyze-plex`, which reads loudness over Plex's own stream and changes nothing. By default it samples five 60s windows per title, so it only gives a verdict when the error range allows it and otherwise says "Unclear". `--full` measures end to end, at roughly 2 to 7 minutes a film.

Does it work? On 4 synthetic clips played back to back, the swing in short-term loudness went from 15.5 LU to 0.4 LU. I measured it with ffmpeg's ebur128 filter, not the loudnorm filter the tool uses, so it isn't marking its own homework. Those clips are pink noise with plenty of headroom. Real films are messier: because gain is capped at -1.5 dBTP true peak, a quiet but peaky film can land short of -20 LUFS (the log tells you by how much). `demo/ab.rb` builds before.mkv and after.mkv from your own files so you can listen to the difference.

Honest caveats: it's v0.1, run from source or Docker (not on RubyGems), and a lossy re-encode still costs one generation of quality. Files already close to target are left alone for that reason.

Alternatives, if they suit you better: Tdarr is great if you want a general transcode pipeline (it can normalise via a community flow, but it's a server plus nodes). ffmpeg-normalize is the flexible general-purpose option and works on audio files too.

Repo: https://github.com/willhs/neutraliser
Happy to hear what breaks on your setup.

## Notes for Will

- Add the chart: `demo/loudness-over-time.svg` (captioned synthetic). Reddit wants an image upload or link, not SVG, so export a PNG.
- The Tdarr quote in the landscape note is a 2024 commenter; don't quote it without permission.
- Say once, in your own words, that you're the author.
