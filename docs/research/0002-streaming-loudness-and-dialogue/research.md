---
id: streaming-loudness-and-dialogue
type: note
purpose: "What streaming services do about volume jumps and quiet dialogue, whether it works, and what neutraliser should copy."
scope:
  - "Delivery specs, playback behaviour and evidence of outcomes for streaming services"
  - "Player support for loudness metadata, and what Plex and Jellyfin already offer"
  - "Feasibility of dialogue measurement and metadata, tested on synthetic clips and public test samples"
non_goals:
  - "No real library or NAS access, no listening tests, no code changes, no tag or release"
tags: ["research", "loudness", "dialogue", "vision", "positioning"]
related:
  - "docs/philosophy/vision.md"
  - "docs/research/landscape.md"
---

# How streamers handle loudness and dialogue, and what neutraliser should copy

Researched 2026-11-01. Vision alignment: Have an online presence (goal: Release neutraliser publicly).

## Recommendation

**Have streamers solved it? Half of it, on their own terms.** They level jumps between titles by measuring dialogue before encoding and moving the whole mix, and [Netflix's spec](https://partnerhelp.netflixstudios.com/hc/en-us/articles/360001794307) says so. Nobody independent has measured how well that works. Quiet dialogue isn't solved: [Netflix lists five causes](https://netflixtechblog.com/measuring-dialogue-intelligibility-for-netflix-content-58c13d2a6f6e), from acting to TV speakers, and [AES says](https://aes.org/wp-content/uploads/2025/12/5297fea6-25ba-4865-92f6-dc1d0ba52ce4.pdf) DRC "cannot reduce masking".

**Copy their anchor, not their plumbing. This changes both the vision and the default, but flip the default only after a test on real files.**

| | Today or proposed | Change to |
|---|---|---|
| **Vision** | Consistent volume between files | Consistent *dialogue level* between files, with loud passages kept within a limit. Keep "least lossy". Say plainly that it can't fix masked or mumbled dialogue. |
| **Default** | -20 LUFS, whole programme | -27 LKFS dialogue ±2 LU, or -24 whole programme when under 15% of the file is dialogue (Netflix's published numbers) |
| **Ladder** | Gain, limiter, then compression when LRA is high | Same rungs, anchored on dialogue. Compress only when the programme sits over 5 LU above dialogue ([EBU R 128 s4](https://tech.ebu.ch/docs/r/r128s4.pdf)), not on LRA. Centre boost stays opt-in: it's the only rung that lifts dialogue over the background. |
| **Metadata** | Considered as an alternative to changing audio | Don't rely on it: few clients are known to honour it. But stop damaging it. |

**Fix two bugs first, whatever you decide.** The constant-gain path isn't constant on Dolby tracks. It bakes in the stream's DRC (LRA 20 to 12 LU on a test clip, still stamped `linear`) and resets dialnorm, which turned a +6 LU gap between two files into -7 LU on a decoder that honours it. Both are permanent without `--keep-original-audio`, so **keep the NAS sweep paused until they're fixed.**

**What the test supports:** on seven synthetic 5.1 mixes with a known dialogue level, today's default spread dialogue across 13.0 LU. Anchoring on an open-tool dialogue estimate cut that to 1.3 LU. Stereo estimates are weaker, with errors spanning 3.6 LU. All of that is synthetic. Accuracy on real films is the open question, and it's why the default waits.

**Also:** Plex shipped [Normalize Loudness and Boost Dialog](https://forums.plex.tv/t/audio-enhancements-boost-dialog-normalize-loudness/942925) on 15 Sept 2026, pitched as "no more reaching for the remote". The README and post drafts don't mention it. Fix that before posting.

**Order of work** (all filed in Steady):

1. Fix the DRC and dialnorm bugs: `bb559c56`
2. Update the README and drafts for Plex's new features: `1d89336a`
3. Add a read-only dialogue estimate to `report` and `rate-sample`: `7b0e5fc9`
4. Play a [test pair](#test-your-own-clients) on your own clients (your job, ten minutes): `9125b183`
5. Validate the estimate on real files, then decide the default: `3da9b750`

The queued `--lra-target` task (`9a0a9fc3`) conflicts with this: it triggers on LRA. I left it as written because it's your spec, but I'd change its trigger before it's built.

## How to read this

Every quotation below was matched by script against the source's raw text, 193 of 193 ([list](spike/results/quote_check.tsv)). Each claim is labelled with its kind:

| Label | Means |
|---|---|
| **Spec** | Published spec or standard, read directly |
| **Engineering** | Written by the vendor's engineers: primary, but self-reported |
| **Peer-reviewed** | Journal or reviewed conference paper |
| **Expert report** | AES technical document: written by named experts, not peer reviewed |
| **Marketing** | Press or product page: shows a feature exists, not that it works |
| **Secondary** | Third party only, not checked against the original |
| **Not public** | I looked and found nothing |
| **Measured** | Run for this note, on synthetic clips or public test samples |

My own reasoning is tagged **[Inferred]**. Anything else carrying a source is what that source states. No hardware decoder or TV was tested. "Honours dialnorm" in test results means FFmpeg's `-target_level -31`, which applies the gain [ATSC describes](https://www.atsc.org/atsc-glossary/dialnorm/).

I couldn't read the vision doc (the claude.ai link returned only a title). Its ladder is taken from this task's text and the `--lra-target` task.

## 1. What services require before delivery

| Service | Target | Measured on | True peak | LRA guidance | Mix | Kind |
|---|---|---|---|---|---|---|
| [Netflix](https://partnerhelp.netflixstudios.com/hc/en-us/articles/360001794307) branded, v OC-1-6, 2024-10-29 | -27 LKFS ±2 LU | Dialogue-gated, BS.1770-1, with a ["Dolby speech-gating dialogue loudness algorithm"](https://studiopartner.netflix.net/studio/loudness-and-true-peaks-how-to-measure-and-when-to-flag). Under 15% dialogue: -24 ±2 whole programme | -2 dBTP | Programme 4 to 18 LU; dialogue "10 LU or less" | Near-field, rooms "similar in size to a typical living room". Theatrical mixes have "no LKFS loudness requirement" | Spec |
| [Amazon](https://videocentral.amazon.com/support/welcome-to-prime-video-slate/supply-chain-updates-june-2026) | "written certifications confirming ATSC A/85 compliance" from 1 July 2026. No number given | Not stated | Not stated | None | Not stated | Spec. Done "in response to California Senate Bill 576", about ads. Originals' spec: **not public** |
| [Apple](https://help.apple.com/itc/videoaudioassetguide/en.lproj/static.html) store films, Atmos | Dialogue "-31 LKFS to -10 LKFS", ideally "between -30 LKFS and -18 LKFS" | "BS.1770 + Dialogue Intelligence" on a 5.1 render. Under 10% dialogue, it "may not be the anchor element" | Not found | None | Not stated | Spec. Apple TV+ originals: **not public** |
| [Paramount](https://pop.paramount.com/?p=1006) | US "-24 LKFS +/-2 dB"; EU -23 ±1 | Whole programme | -2 / -1 dBTP | None | "near field mix is preferred over a Theatrical mix" | Spec |
| Disney+ | -27 ±2 | Dialogue | -2 dBTP | Unknown | Unknown | Secondary: [RTW chart](https://www.rtw.com/en/blog/worldwide-loudness-delivery-standards.html), [named mixers](https://www.production-expert.com/production-expert-1/atsc-a/85-loudness-spec-updated-whats-changed-and-what-you-need-to-do). Primary **not reachable** |
| Max / HBO | Sources conflict: RTW's chart says -27 dialogue, mixers report an "adjustment to Full Program Loudness" | Conflict | -2 dBTP (chart) | Unknown | Unknown | Secondary. Primary **not public** |
| Hulu | "our spec is -24 Full Program" | Whole programme | Unknown | Unknown | Unknown | Secondary (same mixers). Primary **not public** |
| Peacock, YouTube | No programme spec found | | | | | **Not public**. YouTube's -14 LUFS exists only on third-party charts |
| BBC iPlayer | Unknown | | | | | **Not reached**: site blocked my tools |

**The standards behind them:**

| Document | What it says | Kind |
|---|---|---|
| [ITU BS.1770-5](https://www.itu.int/dms_pubrec/itu-r/rec/bs/R-REC-BS.1770-5-202311-I!!PDF-E.pdf) (2023) | Gates at -70 LKFS and -10 relative. Defines no dialogue measurement | Spec |
| [EBU R 128 v5](https://tech.ebu.ch/files/live/sites/tech/files/shared/r/r128v5_0.pdf) (2023) | -23 LUFS programme, "without emphasis on specific foreground elements such as speech". Peaks under -1 dBTP | Spec |
| [EBU R 128 s4](https://tech.ebu.ch/docs/r/r128s4.pdf) (2023) | For films, normalising programme or dialogue alone: "Both solutions are not satisfactory". The "Loudness-to-Dialogue Ratio of Cinematic Content should not exceed 5 LU"; under that, "no dynamic adaptation needs to be performed" | Spec |
| [EBU R 128 s2](https://tech.ebu.ch/docs/r/r128s2.pdf) (2023) | Programmes "should be streamed unchanged" at -23, with metadata. "-20.0 to -16.0 LUFS" only as an interim value for mobile-style playback | Spec |
| [ATSC A/85:2026-07](https://www.atsc.org/wp-content/uploads/2026/07/A85-2026-07.pdf) | -24 LKFS on the anchor element (dialogue-gated). Streaming: "-23 to -27 LKFS represents a practical range". "LRA values should not be enforced in Content specifications" | Spec |
| [AES TD1006](https://aes.org/wp-content/uploads/2024/01/AESTD1006_1_17_10.pdf) (2017) | "An Anchor Element (for instance, dialog) should be used" where regional recommendations say so | Spec |
| [AES TD1009](https://aes.org/wp-content/uploads/2025/12/5297fea6-25ba-4865-92f6-dc1d0ba52ce4.pdf) (Nov 2025) | Services have "disparate loudness specifications". "specifying an LRA target value is misleading, ineffective and discouraged" | Expert report |

**So:** dialogue-anchored -27 is the best-documented pattern for long-form streaming, not a universal one. Sources disagree on LRA: Netflix publishes guidance and [Torcoli et al](https://arxiv.org/html/2405.17364v1) say "Controlling the LRA can bring great advantages", while AES TD1009 and A/85 reject LRA targets.

## 2. What happens at playback

**Do they normalise across titles? Netflix says yes. For the others, nothing is public.**

| Service | What's stated | Kind |
|---|---|---|
| Netflix, all deliveries | ["Netflix normalizes all audio deliveries to ensure all audio plays at the same level on the service. We raise or lower the overall mix level to ensure consistent playback between titles."](https://partnerhelp.netflixstudios.com/hc/en-us/articles/360001794307) It also describes "refraining from compressing, limiting, or altering audio mixes". | Spec |
| Netflix, measuring | ["speech-gated loudness is computed for every audio master track and used for loudness normalization"](https://netflixtechblog.com/detecting-speech-and-music-in-audio-content-afd64e6a5bf8) | Engineering |
| Netflix, Android mobile | [xHE-AAC on "Android 9 and newer"](https://netflixtechblog.com/optimizing-the-aural-experience-on-android-devices-with-xhe-aac-c27714292a33): "The measured dialog level is delivered in MPEG-D DRC metadata". "The decoder applies a gain equal to the difference between the output level and the" dialogue level. "Each device can set a target output level", "such as -16 dBFS" on small speakers. Netflix can also "defeat loudness normalization completely". | Engineering |
| Netflix, TVs | Whether the raise-or-lower is metadata or in the audio, and any device-specific DRC: **not public** | Not public |
| Apple, HLS streams | ["Loudness management or Dynamic range control SHOULD be present unless all content (including ads) has been encoded at the same audio levels."](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices) "The loudness value MUST indicate the actual loudness of the content". Dolby tracks use `dialnorm`; a `ludt` box "takes precedence" | Spec. What Apple TV+ does: **not public** |
| Amazon, Disney+, Max, Hulu | Nothing on across-title normalisation at playback. [Max's audio help](https://help.hbomax.com/us/Answer/Detail/000002549) covers formats only (per the researcher; not checked by script) | Not public |
| YouTube | [Stable volume](https://support.google.com/youtube/answer/14106294?hl=en) is on by default, no figures. "Turns down only" rests on one independent engineer's 2017 post | Support doc, secondary |

**The metadata itself:**

- **Dialnorm (AC-3, E-AC-3):** ["The decoder applies an amount of gain reduction equal to the difference between -31 and the dialnorm value."](https://www.atsc.org/atsc-glossary/dialnorm/) It can only turn down. I read ATSC's glossary, not A/52's normative text.
- **Dolby DRC:** ["Six preset DRC profiles are available"](https://www.tvtechnology.com/miscellaneous/a-closer-look-at-audio-metadata); "Line Mode is relatively light dynamic range compression." (2002 trade article; Dolby's own guide failed to load.)
- **MPEG-D DRC (xHE-AAC):** on [Android](https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/master/media/java/android/media/MediaFormat.java), "The default value on mobile devices is 64 (-16 LKFS)" and "The default DRC effect type is 3" (limited playback range). The standard itself wasn't reachable.

**Device and client features:** these exist; none below publishes evidence of working.

| Feature | What it does | Limits stated | Kind |
|---|---|---|---|
| [Apple TV Reduce Loud Sounds](https://support.apple.com/guide/tv/change-audio-settings-atvba773c3c9/tvos) | "lower the overall sound level for all audio by reducing the dynamic range" | Silent on passthrough. [Infuse users and its developer disagree](https://community.firecore.com/t/apple-tv-4k-enhanced-dialogue-and-reduced-loud-sounds-dont-work/53098) about whether it works there | Support doc; forum |
| [Apple TV Enhance Dialogue](https://support.apple.com/en-us/106336) | "Enhance More makes dialogue very prominent, but may alter the original audio mix" | tvOS 18; "Available on TV speakers, HDMI-connected receivers or speakers, and Bluetooth-connected devices" | Support doc |
| [Prime Video Dialogue Boost](https://www.amazon.science/blog/dialogue-boost-how-amazon-is-using-ai-to-enhance-tv-and-movie-dialogue) | First "relied on cloud-based processing to pre-enhance audio tracks", now also runs "directly on-device" | [Help page](https://www.primevideo.com/help?nodeId=TYiAAjz4wR2wWsttiy) says "on Web, Amazon Devices, and Mobile Devices"; About Amazon says all devices | Engineering, marketing |
| [Roku Leveling](https://support.roku.com/article/manage-volume-levels), [Speech Clarity](https://support.roku.com/article/learn-about-sound-modes) | Level and dialogue modes | "Volume modes are not available for some audio formats"; Speech Clarity "only available when using a Roku audio device" | Support doc |
| [Samsung Auto Volume](https://www.samsung.com/au/support/tv-audio-video/use-auto-volume-on-a-samsung-tv/) | "can equalise the volume up to 12db" | [LG's equivalent](https://www.lg.com/ca_en/support/product-support/troubleshoot/help-library/cs-CT20098005-20150154759710/): with a set-top box "Auto Volume and Smart Sound Mode features will have no effect" | Support doc |

**Does it vary by device? Yes, wherever it's stated:** Netflix sets a target per device on Android, and Prime Video, Apple TV, Roku and TV makers all limit features by device or format. On TVs the mechanism itself is not public.

## 3. Do they solve it?

**How well does it work? Almost no evidence exists, and the best of it is the vendor's own.**

| Evidence | Finding | Limit | Kind |
|---|---|---|---|
| [Netflix A/B test](https://netflixtechblog.com/optimizing-the-aural-experience-on-android-devices-with-xhe-aac-c27714292a33) | ["volume change interactions are noticeably reduced"](https://www.production-expert.com/production-expert-1/netflix-loudness-and-dynamic-range-developments-update). Members "switched away from built-in speakers 7% less often" (16% for high-range titles) | Android only, behaviour not intelligibility, and "the content itself is 11dB louder" | Engineering |
| [Amazon](https://www.amazon.science/blog/dialogue-boost-how-amazon-is-using-ai-to-enhance-tv-and-movie-dialogue) | "over 86% of participants preferred the clarity" | No sample size or method given | Engineering, self-reported |
| [Dialog+, IBC 2021](https://arxiv.org/pdf/2112.09494) | 46% preferred the dialogue-boosted mix, 21% the original; 83% liked having the choice | Preference, not intelligibility. Self-selected: peaks "coincided with publication dates" of reports | Conference, vendor and broadcaster |
| [Torcoli et al, QoMEX 2022](https://ar5iv.labs.arxiv.org/html/2207.14240) | "a consistent trend of decreasing LE along with decreasing background level" (LE: listening effort) | 28 normal-hearing listeners. Background level, not whole-mix level | Peer-reviewed |
| Title-to-title match on any service | **None found.** Compliance alone allows a 4 LU gap between titles at ±2 LU **[Inferred]** | | Not public |

**Why complaints persist.** Three different problems get called "quiet dialogue", and loudness work reaches only the first:

| Problem | What fixes it | Can constant gain help? |
|---|---|---|
| **Level:** speech below hearing or room noise | More level | Yes |
| **Masking:** music and effects compete with speech | A better speech-to-background ratio | **No.** AES: "DRC does not change the balance between dialogue and simultaneously competing elements in the mix, so it cannot reduce masking". Measured here: 0.0 dB change |
| **Articulation:** performance, recording, accents | Nothing downstream | No |

[Netflix's own list](https://netflixtechblog.com/measuring-dialogue-intelligibility-for-netflix-content-58c13d2a6f6e) says "Dialogue intelligibility can break down at multiple points", and it spans all three: "Naturalistic acting styles, diverse speech patterns, and accents", noisy locations, cinematic mixing, the distribution pipeline, "TVs with inadequate speakers, noisy home environments". Its answer is upstream: tools that show mixers when "competing Music and Effects can distract the listener" (Engineering).

- **Mixes.** EBU says film mixes can be ["not suitable for a typical domestic listening environment"](https://tech.ebu.ch/docs/tech/tech3343.pdf), with the programme "sometimes more than 15 LU" above dialogue. AES calls the home mix often an "afterthought", and re-recording mixer Lora Hirschberg says ["A lot of people are hearing the worst possible mix."](https://cinemontage.org/?p=59745) (opinion). [Lund & Skovenborg](https://journal.smpte.org/periodicals/SMPTE%20Motion%20Imaging%20Journal/123/5/17/) measured gaps of up to 14 dB between the two ways of normalising (Peer-reviewed; I read the abstract only).
- **TV speakers.** AES: "Many modern flat-screen television designs compromise dialogue intelligibility" (Expert report, no effect size). I found no measured study of consumer TVs and downmix on intelligibility.
- **Downmix.** I looked for "the 5.1 to stereo downmix drops dialogue 3 dB" and didn't find support. The -3 dB coefficient goes into both left and right, which sums back to the same loudness (Measured: the fixtures' dialogue reads the same in 5.1 and Lo/Ro). AES's concern is masking from everything else landing in the same two channels.
- **Client settings.** Netflix's own help [sends Samsung owners to a TV setting](https://help.netflix.com/en/node/11650) ("Set Auto Volume to Normal.") and says of quiet voices on Apple TV, ["We're looking into this problem."](https://help.netflix.com/en/node/116198)
- **Hearing and taste.** Surveys are weak. [YouGov UK](https://yougov.com/en-gb/articles/55819-most-young-people-now-watch-tv-and-movies-with-the-subtitles-on) reasons are unquantified ("poor sound mixing, loud music and a more naturalistic, mumbled style of acting"), and the youngest use subtitles most, so subtitles are a poor proxy for hearing problems [**Inferred**]. [Preply](https://preply.com/en/blog/americas-subtitles-use/)'s "78%" is marketing with no stated method. AES's claim that "Acting styles have become more subdued" is opinion with no data. I found no trend data showing dialogue has got worse.

## 4. What's different for a personal library

| | Streamer | Personal library |
|---|---|---|
| **The mix** | Can require a near-field mix before accepting a title | One finished mix. A theatrical mix stays theatrical |
| **Measuring** | On the master, sometimes with [dialogue labelled separately](https://partnerhelp.netflixstudios.com/hc/en-us/articles/360001794307) | After the fact, on the blended mix |
| **Delivery** | Encodes per device and picks the codec | One file serves every client |
| **Metadata** | Owns the player, so metadata is reliable | Doesn't own the player. Behaviour differs by client, as section 5b shows |
| **Sources** | One spec per service | Disc and web sources in Dolby, DTS, AAC and FLAC, with mixed or missing metadata |
| **Changing audio** | Re-encode from the master | Another lossy generation, once, unless the track is lossless |
| **Failure** | Bad mix goes back to the supplier | No one to send it back to |

**What this means [Inferred]:** a streamer's fix is mostly the near-field mix requirement. Neutraliser can't ask for one. Its closest move is the one EBU recommends for films that arrive unadapted: measure the gap, then compress just enough.

## 5. What neutraliser should do differently

### Two bugs this research found

Both were reproduced with a real `process --replace` run on synthetic clips ([results](spike/results/dolby_results.json), T3 and T4). `lib/` never sets `drc_scale` or `dialnorm`.

**Bug 1: stream DRC gets baked in.** FFmpeg [applies DRC words by default](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/doc/decoders.texi) ("The default value is 1"), and FFmpeg's encoders [write none back](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/ac3enc.c) ("no compression control word"). So measuring and re-encoding both hear the compressed version, and it's now permanent.

| Clip with DRC words | LRA | Stamp says |
|---|---|---|
| Source, DRC off | 20.0 LU | |
| Source, FFmpeg's default decode | 12.0 LU | |
| After `process --replace` | 12.1 LU, no DRC words left | `mode=linear`, measured LRA 12.00 |
| Control clip with no DRC words, after the same run | 20.0 LU (unchanged) | `mode=linear` |

Decoder DRC is a playback choice. mpv's manual: ["The standard mandates that DRC is enabled by default, but mpv (and some other players) ignore this for the sake of better audio quality."](https://raw.githubusercontent.com/mpv-player/mpv/master/DOCS/man/options.rst) A viewer who turned DRC off now gets it anyway **[Inferred]**. This breaks [the vision's](../../philosophy/vision.md) promise that "the mix keeps its original dynamics".

**Bug 2: dialnorm is reset to -31.** FFmpeg's encoders default to it ("with -31 being the default"), so a re-encoded track loses its source's attenuation while a left-alone file keeps it. Two clips, both dialnorm -24, 6 LU apart:

| | Before: raw | Before: honours dialnorm | After: raw | After: honours dialnorm | Dialnorm after |
|---|---|---|---|---|---|
| Near target (left alone) | -29.2 | -36.2 | -29.2 | -36.2 | -24 |
| Quiet (gets +6 dB) | -35.2 | -42.2 | -29.2 | **-29.2** | -31 |
| **Gap** | 6.0 | 6.0 | **0.0** | **-7.0** | |

Neutraliser reports success, while a client honouring dialnorm now hears a bigger jump, the other way round. E-AC-3 gives identical numbers. Every kind of left-alone file is exposed: within tolerance, peak-capped, Atmos **[Inferred]**.

**Do real tracks carry these?** Yes, on the small sample tested. Seven of FFmpeg's [public FATE samples](spike/results/fate_results.json) (real commercial encodes, short clips, nothing from any personal library):

- Six carry dialnorm of -26 or -27, one carries -31.
- All three AC-3 clips carry DRC words in 99 to 100% of frames.
- FFmpeg's default decode changed the audio on all seven, by up to 7.1 LU on one short clip.

Seven clips show it happens. They can't say how often.

**Fix** (`bb559c56`): decode with `-drc_scale 0` and pass the source's dialnorm through `-dialnorm`, so the output differs from the source by the gain and nothing else. This needs a recipe bump because measured levels change.

### (a) Measuring dialogue: feasible?

**Yes for 5.1, with open tools and small dependencies. Stereo is weaker. Real films are untested.**

I built seven mixes from text-to-speech over synthetic score, crowd and explosions, spanning -3 to +12 LU of programme above dialogue, plus one with no dialogue. Because the speech stays separate, the true level is known. My meter matched FFmpeg's `ebur128` within 0.05 LU.

| Method | New dependency | Error, 5.1 (LU) | Error, stereo (LU) | Verdict |
|---|---|---|---|---|
| Whole programme (today) | None | -3.3 to +12.0 | -3.7 to +10.4 | What we're replacing |
| Centre channel through `ebur128` | **None** | -0.7 to +3.4 | n/a | First step for 5.1 |
| Silero VAD gate on the centre channel | onnxruntime, small model | **+0.12 to +0.87** | n/a | Best here. No torch needed |
| Silero gate on the whole mix | Same | +0.13 to +5.73 | +0.13 to +4.98 | Loud effects over speech inflate it |
| Silero gate, loud blocks trimmed | Same | Mix -1.57 to +1.40; centre -3.04 to -0.12 | -1.53 to +2.11 | Best for stereo, worse on the centre |
| Perfect detector on the whole mix | (reference) | +0.15 to +3.22 | | Even perfect gating reads high |
| Perfect detector on the centre | (reference) | +0.13 to +0.64 | | |
| WebRTC VAD | Small | -2.92 to +12.17 | -2.12 to +11.13 | **Rejected**: flagged 81 to 96% of music and effects as speech |
| FFmpeg `dialoguenhance` centre | None (FFmpeg 5.1+) | n/a | +0.8 to +5.1 | **Rejected** |

Other results:

- **No-dialogue fixture:** Silero flagged 0%, so the under-15% fallback fires correctly. WebRTC flagged 94%.
- **Speed:** Silero ran about 470x real time on one thread on this Mac, so a two-hour film takes about 15 seconds plus decoding. No NAS-class timing.
- **Reading high is expected.** [Torcoli et al](https://arxiv.org/html/2405.17364v1): "Speech-gated loudness consistently overestimates" speech loudness, "even considering a perfect ( oracle )" detector. The perfect-detector rows above reproduce that.

**Why this doesn't settle real films.** Text-to-speech over simple beds is far easier than film. The fixtures have no songs, and speech sits only in the centre.

- **Songs are the likely failure:** on [French music radio](https://arxiv.org/html/2406.04429v1), Silero's speech precision was 23.9% against inaSpeechSegmenter's 88.4% (Peer-reviewed status not stated; TensorFlow dependency).
- **WebRTC on film agrees with my rejection:** ["WebRTC VAD results in a low accuracy of 61%"](https://cdn.amazon.science/61/88/7d000a8041e1a0fd4a92976b1e86/a-comprehensive-empirical-review-of-modern-voice-activity-detection-approaches-for-movies-and-tv-shows.pdf) on movies and TV (Engineering, Amazon).
- **The centre channel leaks:** AES warns it "may contain other program elements and dialogue may be present in other channels", though [EBU](https://tech.ebu.ch/docs/r/r128s4.pdf) says a surround programme's speech track "is typically the Centre channel".
- **Dialogue-gated isn't a precise number, even from Dolby.** On 44 dubbed films already adapted for TV, Dolby's gate and hand-marking differed by a mean of ["small (0.4 LU)"](https://tech.ebu.ch/docs/tech/tech3343.pdf). On feature films, a [secondary report](https://www.production-expert.com/home-page/2018/11/10/is-dolby-dialog-intelligence-still-fit-for-purpose-for-netflix-to-use-for-speech-gating) quoting Lund & Skovenborg's abstract gives "a typical difference of 4.5 dB, with the automatic measurement producing the highest level".

**Free real-world reference [Inferred]:** a track's own dialnorm. By spec it says ["how far the average Dialogue Level of the Content is below 0 LKFS"](https://www.atsc.org/wp-content/uploads/2026/07/A85-2026-07.pdf). That gives (1) ground truth to validate an open gate on real films, and (2) a free measurement for many Dolby tracks, once checked for plausibility. -31 may just mean "unset".

**Other open options:**

- [PLVS](https://github.com/SounDoer/PLVS): the only open dialogue-gated meter found ("Dialogue-gated CLI analysis with selectable VAD engines"; MIT, Rust, no accuracy claim).
- [Dolby's speech-gating reference code](https://professional.dolby.com/support/dolbys-speech-gating-reference-code/): "a free download" behind a form, terms unread. Worth one try as a reference.
- Source separation: [Torcoli et al](https://arxiv.org/html/2405.17364v1) report "MAE is below 1.0" LU with a non-public model, but [Demucs](https://github.com/facebookresearch/demucs) takes "roughly equal to 1.5 times the duration of the track" on CPU, or 3 to 7 GB of GPU memory. Too heavy for a NAS sweep; keep it as the fallback if VAD fails.

Silero's [LICENSE file](https://raw.githubusercontent.com/snakers4/silero-vad/master/LICENSE) says MIT, while a README badge's alt text says CC BY-NC. Check before bundling.

### (b) Metadata instead of changing the audio: who honours it?

**Not enough clients to make it the default.** "Tested" rows ran here.

| Client | Dialnorm | Stream DRC | Other | Basis |
|---|---|---|---|---|
| FFmpeg default decode | **Ignored** | **Applied** | Opus output gain applied | Tested |
| VLC 3.0.24 | **Ignored** | **Applied** | | Tested, via its transcode path |
| mpv | Not requested **[Inferred]**: it sets only `drc_scale` | [Off by default](https://raw.githubusercontent.com/mpv-player/mpv/master/DOCS/man/options.rst) | ReplayGain off by default; [reads the tags](https://raw.githubusercontent.com/mpv-player/mpv/master/demux/demux.c) | Manual, source |
| Kodi | FFmpeg's defaults when decoding **[Inferred]**: [unset unless configured](https://raw.githubusercontent.com/xbmc/xbmc/master/xbmc/settings/AdvancedSettings.cpp) | Same | ReplayGain is [music player code](https://raw.githubusercontent.com/xbmc/xbmc/master/xbmc/cores/paplayer/PAPlayer.cpp) | Source |
| Jellyfin transcode | FFmpeg's defaults **[Inferred]**: no `drc_scale` in its encoder code | Same | | Source |
| Plex transcode | **Not public** | **Not public** | Own loudness analysis | Closed source |
| Plex direct play or passthrough | Goes to the TV or receiver (per Plex's docs, via search summary) | Same | | Secondary |
| Infuse | [Decodes to LPCM](https://support.firecore.com/hc/en-us/articles/217735707-Audio-Options-Capabilities); dialnorm **not stated** | **Not stated** | | Vendor doc |
| Apple TV | A [forum repost](https://community.getchannels.com/t/volume-level-much-louder-with-channels-app-than-other-apple-tv-apps/34763) says it honours dialnorm, unverified | **Not public** | | Secondary |
| Android | AC-3 in vendor decoders: **not found** | AAC keys documented; none for AC-3 | | Spec (AAC only) |
| [Denon receivers](https://manuals.denon.com/AVRX2800H/EU/EN/GFNFSYvdfworfs.php) | Applied by default; "Loudness Management" Off means "Dialogue normalization are disabled" | Dynamic Compression selectable | | Vendor manual |

**Writing metadata back is also limited:**

- FFmpeg's AC-3 and E-AC-3 encoders write no DRC words. [libfdk_aac](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/libfdk-aacenc.c) can carry program reference level, but common builds lack it.
- FFmpeg's native [xHE-AAC decoder](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/aac/aacdec_usac.c) says "DRC is not applied".
- Matroska has [no loudness element, only tags](https://www.matroska.org/technical/tagging.html).
- Apple's `ludt` box [takes precedence in HLS](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices), but [FFmpeg's MP4 reader](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/mov.c) has no entry for it (searched its source).

**Two lossless tools worth knowing (Measured):**

- **Dialnorm can be rewritten in place.** FFmpeg has [no filter for it](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/doc/bitstream_filters.texi), but a [small bit edit](spike/dolby_bits.py) worked on AC-3 and E-AC-3: decoded PCM byte-identical, CRCs clean, level shift exactly +3.0 LU for -24 to -27 on a decoder honouring it. A third-party tool reportedly [breaks Atmos](https://forum.doom9.org/archive/index.php/t-160159.html) (Secondary), so don't apply this to Atmos untested. Dialnorm can only turn down.
- **Opus output gain** can be edited with FFmpeg's `opus_metadata` filter and FFmpeg applies it: -1536 gave -6.0 LU. [RFC 7845](https://www.rfc-editor.org/rfc/rfc7845.txt): "Players and media frameworks SHOULD apply it by default." Only useful for Opus tracks.

**Recommendation [Inferred]:** changing the audio stays the default because it's the only thing that behaves the same on every client. Metadata's job is to not get in the way. Whether to go further and rewrite left-alone Dolby tracks to -31 so every client agrees depends on your clients: [test them](#test-your-own-clients). One risk to check first: Dolby's RF mode reportedly [shifts level up 11 dB](https://professionalsupport.dolby.com/s/article/Controlling-and-Measuring?language=en_US) (Secondary; page wouldn't load), and FFmpeg's -31 tracks carry no overload protection words.

### (c) -20 whole programme, or a dialogue target?

**A dialogue target fits better. Use -27, with -24 whole programme under 15% dialogue.**

A worked example from published numbers **[Inferred]**, using Netflix's reported [dialogue at -27 with programme at -24](https://auphonic.com/blog/2020/10/08/dialog-loudness-normalization/) (Secondary) and peaks at -2, and [EBU's example film](https://tech.ebu.ch/docs/r/r128s4.pdf) (programme -17, dialogue -29), assuming 0 dBTP peaks:

| Target | Near-field title | EBU's film | Dialogue jump between them |
|---|---|---|---|
| **-20 programme**, peak-capped | +0.5 dB, dialogue **-26.5**, short of target by 3.5 LU | -3 dB, dialogue **-32** | **5.5 LU** |
| **-27 dialogue** | 0 dB: **no re-encode** | +2 dB: 3.5 dB limiting, dialogue -27 | **0** |
| **-24 dialogue** | +3 dB: 2.5 dB limiting | +5 dB: 6.5 dB limiting, dialogue -24 | **0** |

Why -27 over -24:

- It's Netflix's number, and inside [A/85's streaming range](https://www.atsc.org/wp-content/uploads/2026/07/A85-2026-07.pdf), where "others use -27 LKFS (provides greater headroom)".
- Titles already to that spec stay untouched, which is the "least lossy" win. A ±2 LU tolerance (Netflix's, against today's 1.0) keeps more of them untouched.
- In the fixtures, -24 ran into the 6 dB limiter on both high-range films (F4 and F5); -27 reached target on F4 and came within 1.4 LU on F5.

**The costs, plainly:**

- **Dialogue targets need dynamics processing on films, and this is the best evidence against the change.** [Lund & Skovenborg](https://journal.smpte.org/periodicals/SMPTE%20Motion%20Imaging%20Journal/123/5/17/): "All programs and a majority of the films could be broadcast" at -24 LKFS on programme loudness without dynamics processing, but speech-normalised, "not a single film could be broadcast at that target level". -27 gives 3 dB more room than that study's -24, but expect the limiter and compression rungs to run on many films, against "least lossy". The validation task should count how many.
- The library plays quieter than today: 3 to 7 dB of volume knob, once **[Inferred]**. If a TV can play Netflix loud enough, it can play this.
- Files already levelled to -20 would sit louder than new ones, and moving them means another lossy generation. The validation task should count them: this is the main argument for -24, which would leave more of them alone.
- High-range films get louder peaks than today, because their dialogue comes up. That's what the compression rung is for.

The `report` remote-free rate should follow: dialogue within 2 LU of target, and programme no more than 5 LU above dialogue, instead of LRA at or under 12.

### (d) What Plex, Jellyfin and common clients already offer

| Product | Feature | Video? | How | Kind |
|---|---|---|---|---|
| **[Plex](https://forums.plex.tv/t/audio-enhancements-boost-dialog-normalize-loudness/942925)** | **Normalize Loudness** (Sept 2026): "takes the edge off very loud scenes". **Boost Dialog**: "Isolates the frequencies where dialog lives and brings them forward" | Yes | "enabling either option will cause the audio to be transcoded". Plex Pass only. Mobile, Android TV, Apple TV, Fire TV, Roku; "Plex Web (Coming Soon)", Smart TVs later | Vendor announcement. Method undisclosed, no test data |
| Plex | Multi-Channel Audio Boost, Normalize Multi-Channel | Downmix only | When downmixing (per Plex's docs, via search summary) | Secondary |
| **[Jellyfin](https://raw.githubusercontent.com/jellyfin/jellyfin/master/Emby.Server.Implementations/ScheduledTasks/Tasks/AudioNormalizationTask.cs)** | LUFS normalisation | **Music only** (`MediaTypes = [MediaType.Audio]`) | Client gain | Source |
| [Jellyfin](https://jellyfin.org/docs/general/post-install/transcoding/downmix/) | Downmix boost; [NightmodeDialogue](https://raw.githubusercontent.com/jellyfin/jellyfin/master/MediaBrowser.Controller/MediaEncoding/DownMixAlgorithmsHelper.cs) ("c0=c2+0.30*c0+0.30*c4") | Yes | Transcode, stereo downmix | Docs, source |
| [Emby](https://emby.media/support/articles/Transcoding.html) | Audio Boost: "the volume will be doubled when converting surround audio to stereo" | Yes | Transcode | Docs |
| [Kodi](https://raw.githubusercontent.com/xbmc/xbmc/master/xbmc/cores/VideoPlayer/AudioSinkAE.cpp) | Volume amplification | Yes | Local decode only | Source |
| [Infuse](https://support.firecore.com/hc/en-us/articles/360015608854-Settings-Overview) | Volume Boost "up to 300%" | Yes | Local | Vendor doc |
| [NVIDIA Shield](https://support-shield.nvidia.com/android-tv-release-notes/9.1.1/) | "Night listening mode automatically levels both loud explosions and quiet dialog" | Yes | Device | Release notes |

**Positioning [Inferred]:** "Plex's setting doesn't fix it" is no longer a safe line. The honest difference: Plex's feature costs Plex Pass, transcodes on every play, and needs client support, while neutraliser is a one-time change that works everywhere, direct play included, at the cost of one re-encode. Jellyfin has nothing for video levelling in its code, so Jellyfin users may be a better audience than assumed.

### The ladder compared

Each recipe on the same seven mixes. These ran as FFmpeg filter chains using the same gain logic and limiter settings as `GainPlan`, not through the CLI. Recipes marked "known" use the true dialogue level, so their small spreads are partly by construction. I uses the Silero estimate on the centre channel throughout, so it's the honest one. J uses the estimate too, but its second pass on the two compressed films reads the known stem, which flatters its spread. S/B is the median speech-to-background change during speech, split out with [Hagerman's method](spike/dialogue_spike.py).

| Recipe | Dialogue lands | Spread (LU) | S/B change (dB) | LRA, talky F2 (was 13.2) | LRA, war film F5 (was 24.0) |
|---|---|---|---|---|---|
| **A** -20 programme, peak-capped (today) | -34.4 to -21.4 | **13.0** | 0.0 | 13.2 | 24.0 |
| **B** -20, limiter up to 6 dB | -32.0 to -17.8 | 14.1 | 0.0 | 12.3 | 23.8 |
| **C** -20, gentle compression | -24.9 to -18.5 | 6.5 | -0.3 to -0.9 | 6.5 | 14.4 |
| **D** -20, strong compression | -24.2 to -20.0 | 4.3 | -0.9 to -1.9 | 1.8 | 7.8 |
| **E** -27 known, peak-capped | -34.4 to -27.0 | 7.4 | 0.0 | 13.2 | 24.0 |
| **F** -27 known, limiter up to 6 dB | -28.4 to -27.0 | 1.4 | 0.0 | 13.2 | 22.9 |
| **G** -24 known, limiter up to 6 dB | -28.4 to -24.0 | 4.4 | 0.0 | 13.2 | 22.9 |
| **H** -27 known, centre +4 dB, limiter | -27.0 to -27.0 | 0.0 | **+3.0 to +4.0** | 16.8 | 24.1 |
| **I** -27 estimated, limiter up to 6 dB | -28.4 to -27.1 | **1.3** | 0.0 | 13.2 | 22.9 |
| **J** -27 estimated, compress only if over 5 LU above dialogue | -27.2 to -27.0 | **0.2** (see above) | 0.0; -0.4 and -0.3 on the two compressed films | **13.2** | **14.5** |

What this shows:

1. **Whole-programme gain is the problem.** A leaves dialogue 13.0 LU apart, and a limiter (B) doesn't help.
2. **Your ladder's compression rung does work on a -20 target**, closing the spread to 4.3 to 6.5 LU. But applied everywhere, it crushes talky files that were fine: F2's LRA falls from 13.2 to 1.8 under D.
3. **Moving the anchor does most of the job with less processing.** F reaches 1.4 LU and I reaches 1.3 LU with no compression at all.
4. **F and I still leave high-range films too loud**, with the programme 6.9 to 10.7 LU above dialogue. So compression is still needed, but only for those films.
5. **LRA can't pick them out; the gap can.** LRA read 15.8 on a quiet drama and 16.6 on near-field action, while the gap read -0.3 and -0.4. It then read 7.6 and 12.0 on the two films that need help. (Sparse speech inflates these fixtures' LRA, so don't read the numbers across to real films.)
6. **J is the ladder I'd build.** Talky files get gain alone (F2's LRA stays 13.2) and only the two high-range films are compressed (F5's LRA falls from 24.0 to 14.5). It overshoots, though: the gentle preset takes them to 1.0 and 1.4 LU above dialogue when 5 is enough. A real rung should stop at the limit and keep more of the mix.
7. **Only centre boost helps masking.** Gain and limiter change S/B by nothing, compression makes it slightly worse (as [May et al](https://pmc.ncbi.nlm.nih.gov/articles/PMC6100123) found in a hearing-aid context: "All tested compression systems led to a reduction in the output SNR"), and centre +4 dB adds 3.0 to 4.0 dB. AES calls a listener's own centre boost "the least desirable method", because the channel holds other sounds, so it stays opt-in, 5.1 only, and by ear.

No perceptual claim follows from any of this. Which amounts sound right is still your call by ear.

### Test your own clients

No source says what most consumer clients do with dialnorm, and only your hardware can answer it. Same audio, different dialnorm:

```bash
for dn in 31 24; do
  ffmpeg -f lavfi -i "color=c=black:s=640x360:r=25:d=60" \
         -f lavfi -i "anoisesrc=color=pink:amplitude=0.3:sample_rate=48000:duration=60" \
         -c:v libx264 -preset veryfast -c:a ac3 -ac 2 -b:a 192k -dialnorm -$dn dialnorm-$dn.mkv
done
```

Play each by direct play on every client you use. If the -24 file is about 7 dB quieter, that client honours dialnorm. If they match, it ignores it. FFmpeg confirms the pair: identical on a default decode (-25.2 LUFS), about 7 LU apart with `-target_level -31` (-25.2 and -32.3).

## What we don't know

- **The vision doc's wording.** I couldn't read it, so the thresholds and six decisions it holds aren't addressed directly.
- **Accuracy of any open dialogue gate on real films.** I found no published test against Dolby's gate or against clean dialogue. Searched: "deep learning dialogue loudness estimation compared to Dolby Dialogue Intelligence"; GitHub for "dialogue gated" and "speech gated loudness".
- **How common these Dolby problems are.** Seven short clips only. A read-only scan of real tracks would tell.
- **What real TVs, soundbars and receivers do**, apart from one Denon manual: dialnorm, line versus RF mode, passthrough. Dolby's own guide and ATSC A/52's normative text weren't readable with my tools.
- **Streamers' TV playback.** Whether Netflix's level change is metadata or in the audio on TVs. Anything at playback for Prime Video, Apple TV+, Disney+, Max and Hulu.
- **Primary specs** for Disney+, Max, Hulu and Peacock. BBC's site blocked my tools. Amazon originals and Apple TV+ originals aren't public.
- **Independent measurement** of title-to-title consistency on any service, or of Dialogue Boost, Enhance Dialogue or Plex's features. Whether dialogue has actually got worse over time. Searched and found none.
- **Plex's method** for both new features, and what its transcoder does with DRC and dialnorm.
- **Sources disagree, and I didn't pick:** LRA targets (section 1); dialogue LRA of 7 versus 10 LU in older summaries of Netflix (the current spec says 10); Dolby's gate versus hand-marking, 0.4 versus 4.5 dB (different films); whether Max is dialogue or programme.
- **Papers read only as abstracts or via secondary reports:** Lund & Skovenborg, Skovenborg & Lund.

## Method and reproducing

Investigation playbook, size L. Five parallel web researchers, then every cited quote matched against raw text by script, because their fetch tool summarises and misreads digits. Decisions and what was ruled out are in [decisions.tsv](decisions.tsv).

Text from JS-only pages (Netflix, Apple HLS, Amazon, Plex support) came through the r.jina.ai extractor. Files in [spike/](spike/) are evidence, not product code:

```bash
# Needs: pip install --target PKGS numpy scipy onnxruntime webrtcvad-wheels pypdf; pip install --no-deps --target PKGS silero-vad
python3 spike/dolby_tests.py REPO SCRATCH        # T1-T5: FFmpeg and the real CLI on Dolby metadata
python3 spike/fate_check.py DOWNLOADS OUT.json   # public FATE samples (filenames are FFmpeg's)
python3 -I spike/dialogue_spike.py SCRATCH RESULTS PKGS   # fixtures, estimators, recipes (about 15 minutes)
python3 -I spike/check_quotes.py spike/quotes.tsv CACHE OUT.tsv PKGS
```

The VLC check isn't scripted: it ran `vlc -I dummy --sout "#transcode{acodec=s16l,...}"` over the T1 and T4 clips and measured the output with `ebur128`.
