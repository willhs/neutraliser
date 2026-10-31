---
type: note
status: draft
owner: will
contributors: []
updated: 2026-11-01
review_cycle: 30d
agent_write: false
links: []
summary: "Draft r/DataHoarder post for Will to edit (not posted)"
tags: [release, community, draft]
---

# r/DataHoarder draft

**Self-promotion rules: unverified.** The r/DataHoarder rules did not load and searches found no copy. Sister subs (r/musichoarder) have started requiring mod approval for software posts, so expect something similar: read the live rules, and consider modmail before posting. Landscape note: expect the least traction here, since attention goes to Tdarr/Unmanic and transcoding. Lead with the archive angle (safe, reversible, non-destructive), not "fix the volume".

## Claims checked against main (801ea90)

Everything in the draft maps to the README or `demo/README.md` on main. Left out on purpose: the August "716 of 804 films within 1 LU" figure and the ten-film real-library chart (they predate the constant-gain default and the films were picked from processed files). If you want them, keep the caveat: "from v0.1 first runs in August 2026, two-pass loudnorm, ten films picked from processed files, not random". The synthetic figures below were re-run 2026-11-01 on FFmpeg 7.1.1 (`demo/README.md#verified-synthetic-rerun`) and are pink noise, not films.

## Title options

- Tool for levelling audio across a video archive without re-encoding the video, with originals kept
- Open-source CLI: normalise audio loudness in a big video library, resumable, reversible

## Body

Writing this for people with libraries too big to babysit. I wrote an open-source CLI, Neutraliser, that evens out loudness across a video archive. The design goal was to touch as little as possible.

- **Video is stream-copied** (MD5-identical in my test). Only the main audio track is re-encoded, at the source's own codec and bitrate. FLAC stays lossless
- **Constant gain, not compression** by default, so dynamic range is unchanged (LRA 12.5 LU before and after on a real film clip). The gain is capped at -1.5 dBTP true peak
- **Lossy is still lossy**: re-encoding AAC or AC3 costs one generation. Files close to target are left alone to avoid it
- **Reversible**: copies by default. `--keep-original-audio` stream-copies the untouched original track into the output as an extra non-default track, even with `--replace`
- **Everything else preserved**: other audio and subtitle tracks, fonts, per-stream metadata, chapters, dispositions. If any go missing, the original isn't replaced
- **Atmos / DTS:X** are skipped and logged, not flattened (FFmpeg 7.1+ to detect)
- **Records**: each normalised track carries `NEUTRALISER_*` tags (profile, gain, source codec, measured loudness, date); `neutraliser report` summarises a tree and can write TSV or JSON. AVI and some MP4s fall back to a sidecar
- **Big-batch handling**: manifest-based `--resume`, `--local-stage` for slow network mounts, free-space floors, a run lock, atomic replace with verification

Evidence: 8 synthetic clips spread over 18.6 LU came out 0.2 LU apart (ebur128, independent of the loudnorm filter used to decide). That's pink noise with plenty of headroom, not films. The scripts in `demo/` run the same check on copies of your own files.

I won't claim more than that. I ran it over my own library in August and it looked good, but that was an early version using two-pass loudnorm and hand-picked processed files, so treat it as anecdote.

Alternatives: ffmpeg-normalize is the mature general tool (EBU R128, RMS, peak, Python API, audio files). Tdarr and Unmanic are the full pipeline option if you already run transcode workers. Neutraliser is the narrow one.

MIT, Ruby 3.2+ or Docker: https://github.com/willhs/neutraliser

Feedback welcome, especially on odd containers and codecs I haven't hit.

## Notes for Will

- Check the "LRA unchanged" claim wording: README shows 12.5 LU before and after on one real clip, so keep it as "one clip".
- Avoid size or space-saving claims; none are verified.
