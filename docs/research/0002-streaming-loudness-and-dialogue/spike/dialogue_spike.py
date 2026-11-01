#!/usr/bin/env python3
"""Can dialogue loudness be measured with open tools, and does anchoring on it level dialogue better?

Evidence for docs/research/0002-streaming-loudness-and-dialogue/research.md. Not product code. All audio is
synthetic: speech from macOS `say`, music and effects from noise and sines. Because the speech stem is kept
separate, the true dialogue level is known exactly, which real films can't give us. The price is that TTS over
synthetic beds is far easier than film dialogue: this shows the mechanism and the cost, not film accuracy.

Usage: dialogue_spike.py <scratch dir> <results dir> <pkgs dir>
<pkgs dir> holds numpy, scipy, onnxruntime, webrtcvad and silero-vad (pip install --target); silero-vad is only
used for its model file, so torch isn't needed.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

SCRATCH, RESULTS, PKGS = (Path(arg).resolve() for arg in sys.argv[1:4])
sys.path.append(str(PKGS))

import numpy as np  # noqa: E402
import onnxruntime as ort  # noqa: E402
import webrtcvad  # noqa: E402
from scipy.signal import lfilter, resample_poly  # noqa: E402

FS = 48000
SECONDS = 240
CHANNELS = ["FL", "FR", "FC", "LFE", "BL", "BR"]
WEIGHTS = np.array([1.0, 1.0, 1.0, 0.0, 1.41, 1.41])
SILERO = PKGS / "silero_vad/data/silero_vad.onnx"

SENTENCES = [
    "Nobody told me the road was closed until we got there.",
    "I kept the letter, but I never opened it.",
    "If the rain holds off we can leave before dark.",
    "She said the old bridge would not last another winter.",
    "Why did you come back here after all this time?",
    "We have about ten minutes before they notice the door is open.",
    "There was a light on in the kitchen when I drove past.",
    "He wanted to sell the farm and move to the coast.",
    "You can't keep pretending that nothing has changed.",
    "The boat was already gone when the harbour master woke up.",
    "I don't remember signing anything, and neither do you.",
    "Tell them we need another day to finish the survey.",
    "My brother used to walk this way to school every morning.",
    "It isn't about the money, it never was about the money.",
    "Put the map away and listen to me for a moment.",
    "The doctor said to wait until the end of the month.",
    "They found the car three miles north of the river.",
    "What would you have done if I hadn't called you?",
    "All the windows on the east side were left open.",
    "We should talk to her before anybody else does.",
]
VOICES = ["Daniel", "Karen", "Moira", "Fred"]

# name: dialogue level, music level (None = none), burst level (None = none), speech share of the timeline.
# Burst levels are set so peaks stay at or under about 0 dBTP and the programme sits 0 to about 14 LU above the
# dialogue, the span the published figures give (EBU Tech 3343, Skovenborg & Lund).
FIXTURES = {
    "F1 quiet drama": dict(dialogue=-27, music=None, burst=None, share=0.55, overlap=0.0),
    "F2 drama with score": dict(dialogue=-27, music=-37, burst=None, share=0.45, overlap=0.0),
    "F3 near-field action": dict(dialogue=-27, music=-38, burst=-20, share=0.35, overlap=0.1),
    "F4 theatrical action": dict(dialogue=-31, music=-40, burst=-18, share=0.30, overlap=0.1),
    "F5 war film": dict(dialogue=-33, music=-42, burst=-17, share=0.18, overlap=0.3),
    "F6 loud score under speech": dict(dialogue=-24, music=-29, burst=None, share=0.45, overlap=0.0),
    "F7 crowd under speech": dict(dialogue=-28, music=None, burst=None, share=0.40, overlap=0.0, crowd=-37),
    "F8 no dialogue": dict(dialogue=None, music=-24, burst=-19, share=0.0, overlap=0.0),
}


# --- BS.1770 ---------------------------------------------------------------------------------------------------------
def k_weight(x):
    """K-weighting at 48 kHz, coefficients from ITU-R BS.1770."""
    y = lfilter([1.53512485958697, -2.69169618940638, 1.19839281085285], [1.0, -1.69065929318241, 0.73248077421585], x, axis=0)
    return lfilter([1.0, -2.0, 1.0], [1.0, -1.99004745483398, 0.99007225036621], y, axis=0)


def block_energy(x, weights):
    """Mean-square K-weighted energy of each 400 ms block, 100 ms hop, summed over channels with weights."""
    x = x.reshape(len(x), -1)
    kw = k_weight(x) ** 2
    cum = np.vstack([np.zeros((1, x.shape[1])), np.cumsum(kw, axis=0)])
    size, hop = int(0.4 * FS), int(0.1 * FS)
    starts = np.arange(0, len(x) - size, hop)
    per_channel = (cum[starts + size] - cum[starts]) / size
    return (per_channel * np.asarray(weights)).sum(axis=1), starts, size


def lufs_of(energy):
    return -0.691 + 10 * np.log10(energy) if energy > 0 else float("-inf")


def integrated(x, weights, mask=None):
    """BS.1770 integrated loudness. mask, if given, limits it to blocks at least half inside the mask."""
    energy, starts, size = block_energy(x, weights)
    if mask is not None:
        cum = np.concatenate([[0], np.cumsum(mask.astype(np.float64))])
        keep = (cum[starts + size] - cum[starts]) / size >= 0.5
        if not keep.any():
            return float("-inf")
        energy = energy[keep]
    above_abs = energy[-0.691 + 10 * np.log10(np.maximum(energy, 1e-12)) > -70]
    if len(above_abs) == 0:
        return float("-inf")
    threshold = lufs_of(above_abs.mean()) - 10
    gated = above_abs[-0.691 + 10 * np.log10(above_abs) > threshold]
    return lufs_of(gated.mean())


def trimmed(x, weights, mask, above_median=6.0):
    """Like integrated(x, weights, mask), but first drop flagged blocks far above the median flagged block.

    Energy means are ruled by their loudest members: a few explosions that land on a line of dialogue outweigh
    every quiet line. Tuned on these fixtures only, so treat it as an idea to test, not a finding about films.
    """
    energy, starts, size = block_energy(x, weights)
    cum = np.concatenate([[0], np.cumsum(mask.astype(np.float64))])
    energy = energy[(cum[starts + size] - cum[starts]) / size >= 0.5]
    energy = energy[energy > 10 ** ((-70 + 0.691) / 10)]
    if len(energy) == 0:
        return float("-inf")
    loudness = -0.691 + 10 * np.log10(energy)
    energy = energy[loudness <= np.median(loudness) + above_median]
    threshold = lufs_of(energy.mean()) - 10
    return lufs_of(energy[-0.691 + 10 * np.log10(energy) > threshold].mean())


def scale_to(x, target, weights):
    return x * 10 ** ((target - integrated(x, weights)) / 20)


# --- Fixtures --------------------------------------------------------------------------------------------------------
def tts_pool():
    pool_dir = SCRATCH / "tts"
    pool_dir.mkdir(parents=True, exist_ok=True)
    pool = []
    for v, voice in enumerate(VOICES):
        for s, sentence in enumerate(SENTENCES):
            path = pool_dir / f"{v}_{s}.raw"
            if not path.exists():
                aiff = pool_dir / f"{v}_{s}.aiff"
                subprocess.run(["say", "-v", voice, "-o", str(aiff), sentence], check=True)
                subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(aiff), "-ar", str(FS), "-ac", "1",
                                "-f", "f32le", str(path)], check=True)
                aiff.unlink()
            pool.append(np.fromfile(path, dtype=np.float32))
    return pool


def speech_stem(pool, share, rng, spread_db=4.0):
    """Sentences with pauses, covering about `share` of the timeline, each with its own level."""
    n = SECONDS * FS
    stem, truth = np.zeros(n), np.zeros(n, dtype=bool)
    if share <= 0:
        return stem, truth
    mean_len = np.mean([len(p) for p in pool])
    gap_mean = mean_len * (1 - share) / share
    pos = int(rng.uniform(0, gap_mean))
    while pos < n:
        clip = pool[rng.integers(len(pool))]
        end = min(pos + len(clip), n)
        gain = 10 ** (rng.normal(0, spread_db) / 20)
        stem[pos:end] += clip[: end - pos] * gain
        truth[pos:end] = True  # a whole sentence counts as speech, breaths and word gaps included
        pos = end + int(rng.exponential(gap_mean))
    return stem, truth


def pink(n, rng):
    spec = np.fft.rfft(rng.standard_normal(n))
    spec[1:] /= np.sqrt(np.arange(1, len(spec)))
    y = np.fft.irfft(spec, n)
    return y / np.std(y)


def score(level, rng):
    """Slow chords on sines plus some noise: wide in L/R/surrounds, a quieter part in the centre."""
    n = SECONDS * FS
    t = np.arange(n) / FS
    roots = rng.choice([110, 130.8, 146.8, 164.8, 196], size=SECONDS // 6 + 1)
    tone = np.zeros(n)
    for i, root in enumerate(roots):
        a, b = i * 6 * FS, min((i + 1) * 6 * FS, n)
        if a >= n:
            break
        seg = t[a:b]
        env = np.minimum(1, np.minimum((seg - seg[0]) / 0.5, (seg[-1] - seg + 1e-3) / 0.5))
        chord = sum(np.sin(2 * np.pi * root * r * seg + rng.uniform(0, 6)) / (j + 1) for j, r in enumerate([1, 1.5, 2, 3, 4, 5, 6]))
        tone[a:b] = chord * env
    bed = np.zeros((n, 6))
    for ch, g in (("FL", 1), ("FR", 1), ("BL", 0.6), ("BR", 0.6)):
        i = CHANNELS.index(ch)
        bed[:, i] = g * (0.8 * tone + 0.25 * pink(n, rng))
    bed[:, CHANNELS.index("FC")] = 0.35 * tone
    bed[:, CHANNELS.index("LFE")] = 0.2 * tone
    return scale_to(bed, level, WEIGHTS)


def crowd(pool, level, rng):
    """Babble: many voices at once, spread across the fronts and surrounds. Real speech, but not dialogue."""
    n = SECONDS * FS
    bed = np.zeros((n, 6))
    for ch in ("FL", "FR", "BL", "BR"):
        i = CHANNELS.index(ch)
        for _ in range(4):
            s, _ = speech_stem(pool, 0.9, rng, spread_db=3)
            bed[:, i] += s
    return scale_to(bed, level, WEIGHTS)


def bursts(level, speech_truth, overlap, rng):
    """Explosions: decaying low-heavy noise in all channels. Scaled so a burst's own programme loudness hits level."""
    n = SECONDS * FS
    stem = np.zeros((n, 6))
    pos = int(10 * FS)
    while pos < n - 5 * FS:
        length = int(rng.uniform(1.5, 4.0) * FS)
        # Prefer a gap in the speech unless this burst is one of the overlapping ones.
        if rng.random() > overlap:
            for _ in range(40):
                if not speech_truth[pos:pos + length].any():
                    break
                pos += FS
            if pos >= n - 5 * FS:
                break
        env = np.exp(-np.arange(length) / (0.35 * length))
        for i, g in zip(range(6), (1.0, 1.0, 0.7, 1.4, 0.7, 0.7)):
            stem[pos:pos + length, i] += g * env * pink(length, rng)
        pos += length + int(rng.exponential(14 * FS))
    return scale_to(stem, level, WEIGHTS)


def build_fixtures():
    pool = tts_pool()
    built = {}
    for seed, (name, f) in enumerate(FIXTURES.items()):
        rng = np.random.default_rng(100 + seed)
        n = SECONDS * FS
        speech, truth_mask = speech_stem(pool, f["share"], rng)
        speech6 = np.zeros((n, 6))
        if f["dialogue"] is not None:
            speech6[:, 2] = scale_to(speech, f["dialogue"], [1.0])
        background = np.zeros((n, 6))
        if f["music"] is not None:
            background += score(f["music"], rng)
        if f.get("crowd") is not None:
            background += crowd(pool, f["crowd"], rng)
        if f["burst"] is not None:
            background += bursts(f["burst"], truth_mask, f["overlap"], rng)
        room = np.stack([pink(n, rng) * 10 ** (-62 / 20) for _ in range(6)], axis=1)
        background += room
        built[name] = {"speech": speech6, "background": background, "truth_mask": truth_mask}
    return built


def stereo(x):
    """Lo/Ro downmix with the ITU coefficients, no normalisation."""
    fl, fr, fc, _, bl, br = x.T
    return np.stack([fl + 0.7071 * fc + 0.7071 * bl, fr + 0.7071 * fc + 0.7071 * br], axis=1)


# --- Voice activity --------------------------------------------------------------------------------------------------
def to_16k(x):
    return resample_poly(x, 1, 3).astype(np.float32)


class Silero:
    """Silero VAD v6 through onnxruntime alone: no torch. A 512-sample window at 16 kHz with 64 samples of context."""

    def __init__(self):
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 1
        opts.inter_op_num_threads = 1
        self.session = ort.InferenceSession(str(SILERO), sess_options=opts, providers=["CPUExecutionProvider"])

    def mask(self, mono16, length48):
        peak = np.max(np.abs(mono16)) or 1.0
        audio = mono16 / peak if peak > 1 else mono16
        state = np.zeros((2, 1, 128), dtype=np.float32)
        context = np.zeros((1, 64), dtype=np.float32)
        probs = []
        for i in range(0, len(audio) - 512, 512):
            chunk = audio[i:i + 512].reshape(1, -1)
            out, state = self.session.run(None, {"input": np.concatenate([context, chunk], axis=1), "state": state,
                                                 "sr": np.array(16000, dtype=np.int64)})
            context = chunk[:, -64:]
            probs.append(float(out[0][0]))
        return smooth_mask(np.array(probs) > 0.5, 512 / 16000, length48)


def smooth_mask(active, hop_seconds, length48, min_speech=0.25, min_gap=0.3):
    """Fill short gaps, drop short runs, stretch back to 48 kHz samples."""
    active = active.copy()
    runs = np.flatnonzero(np.diff(np.concatenate([[0], active.astype(int), [0]]))).reshape(-1, 2)
    for i in range(len(runs) - 1):
        if (runs[i + 1, 0] - runs[i, 1]) * hop_seconds < min_gap:
            active[runs[i, 1]:runs[i + 1, 0]] = True
    edges = np.flatnonzero(np.diff(np.concatenate([[0], active.astype(int), [0]])))
    for a, b in edges.reshape(-1, 2):
        if (b - a) * hop_seconds < min_speech:
            active[a:b] = False
    mask = np.zeros(length48, dtype=bool)
    hop48 = int(hop_seconds * FS)
    for a, b in np.flatnonzero(np.diff(np.concatenate([[0], active.astype(int), [0]]))).reshape(-1, 2):
        mask[a * hop48:b * hop48] = True
    return mask


def webrtc_mask(mono16, length48, aggressiveness=3):
    vad = webrtcvad.Vad(aggressiveness)
    pcm = np.clip(mono16 * 32767, -32768, 32767).astype(np.int16)
    frame = 480  # 30 ms
    active = np.array([vad.is_speech(pcm[i:i + frame].tobytes(), 16000) for i in range(0, len(pcm) - frame, frame)])
    return smooth_mask(active, 0.03, length48)


# --- Gates -----------------------------------------------------------------------------------------------------------
def write_wav(path, x):
    x.astype(np.float32).tofile(path)


def ffmpeg_filter(raw_in, channels, layout, chain):
    """Run an FFmpeg filter chain over raw float samples and parse its ebur128 summary or return its samples."""
    return subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-f", "f32le", "-ar", str(FS), "-ch_layout", layout, "-i", str(raw_in),
                           "-af", chain, "-f", "null", "-"], capture_output=True, text=True, check=True).stderr


def parse_ebur128(stderr):
    summary = stderr[stderr.rindex("Summary:"):]
    i = float(summary.split("I:")[1].split("LUFS")[0])
    lra = float(summary.split("LRA:")[1].split("LU")[0])
    tp = float(summary.split("Peak:")[1].split("dBFS")[0]) if "Peak:" in summary else None
    return i, lra, tp


def run_gates(built):
    silero = Silero()
    rows = {}
    cost = {"silero_s": 0.0, "webrtc_s": 0.0, "audio_s": 0.0, "stereo_dialoguenhance_s": 0.0, "centre_ffmpeg_s": 0.0}
    SCRATCH.mkdir(exist_ok=True, parents=True)
    for name, f in built.items():
        speech, background, truth_mask = f["speech"], f["background"], f["truth_mask"]
        mix = speech + background
        lo_ro = stereo(mix)
        raw6, raw2 = SCRATCH / "mix6.raw", SCRATCH / "mix2.raw"
        write_wav(raw6, mix)
        write_wav(raw2, lo_ro)
        row = {}
        has_dialogue = np.any(speech)
        truth = integrated(speech, WEIGHTS) if has_dialogue else None
        truth_stereo = integrated(stereo(speech), [1, 1]) if has_dialogue else None
        row["truth_dialogue"] = truth
        row["truth_dialogue_stereo"] = truth_stereo

        i_ff, lra_ff, tp_ff = parse_ebur128(ffmpeg_filter(raw6, 6, "5.1", "ebur128=peak=true"))
        row["programme"] = integrated(mix, WEIGHTS)
        row["programme_ffmpeg"] = i_ff
        row["lra"] = lra_ff
        row["true_peak"] = tp_ff
        row["programme_stereo"] = integrated(lo_ro, [1, 1])

        # Zero new dependencies: the centre channel on its own, through FFmpeg's normal gating.
        t0 = time.time()
        row["centre_ffmpeg"] = parse_ebur128(ffmpeg_filter(raw6, 6, "5.1", "pan=mono|c0=FC,ebur128"))[0]
        cost["centre_ffmpeg_s"] += time.time() - t0

        # Stereo, zero new dependencies: FFmpeg's dialoguenhance centre estimate (5.1+).
        t0 = time.time()
        row["stereo_dialoguenhance"] = parse_ebur128(ffmpeg_filter(raw2, 2, "stereo", "dialoguenhance,pan=mono|c0=FC,ebur128"))[0]
        cost["stereo_dialoguenhance_s"] += time.time() - t0

        # A perfect detector: how much of the error is the gate itself rather than the detector.
        row["oracle_gate_whole_mix"] = integrated(mix, WEIGHTS, truth_mask) if truth_mask.any() else None
        row["oracle_gate_centre"] = integrated(mix[:, 2], [1.0], truth_mask) if truth_mask.any() else None

        mono_mix = 0.7071 * (mix[:, 0] + mix[:, 1]) + mix[:, 2] + 0.5 * (mix[:, 4] + mix[:, 5])
        mono16 = to_16k(mono_mix)
        centre16 = to_16k(mix[:, 2])
        lo_ro_mono16 = to_16k(lo_ro.mean(axis=1))

        t0 = time.time()
        silero_mix = silero.mask(mono16, len(mix))
        cost["silero_s"] += time.time() - t0
        silero_centre = silero.mask(centre16, len(mix))
        silero_stereo = silero.mask(lo_ro_mono16, len(mix))

        t0 = time.time()
        webrtc_mix = webrtc_mask(mono16, len(mix))
        cost["webrtc_s"] += time.time() - t0
        webrtc_stereo = webrtc_mask(lo_ro_mono16, len(mix))
        cost["audio_s"] += SECONDS

        row["silero_gate_whole_mix"] = integrated(mix, WEIGHTS, silero_mix) if silero_mix.any() else None
        row["silero_gate_centre"] = integrated(mix[:, 2], [1.0], silero_centre) if silero_centre.any() else None
        row["silero_gate_stereo"] = integrated(lo_ro, [1, 1], silero_stereo) if silero_stereo.any() else None
        row["webrtc_gate_whole_mix"] = integrated(mix, WEIGHTS, webrtc_mix) if webrtc_mix.any() else None
        row["webrtc_gate_stereo"] = integrated(lo_ro, [1, 1], webrtc_stereo) if webrtc_stereo.any() else None
        row["silero_trimmed_whole_mix"] = trimmed(mix, WEIGHTS, silero_mix) if silero_mix.any() else None
        row["silero_trimmed_centre"] = trimmed(mix[:, 2], [1.0], silero_centre) if silero_centre.any() else None
        row["silero_trimmed_stereo"] = trimmed(lo_ro, [1, 1], silero_stereo) if silero_stereo.any() else None
        row["silero_speech_share_centre"] = round(float(silero_centre.mean()), 3)
        row["silero_speech_share_stereo"] = round(float(silero_stereo.mean()), 3)
        f["silero_centre_mask"] = silero_centre

        def detector_stats(mask):
            flagged, actual = mask.sum(), truth_mask.sum()
            hit = (mask & truth_mask).sum()
            return {"flagged_share": round(float(flagged / len(mask)), 3),
                    "precision": round(float(hit / flagged), 3) if flagged else None,
                    "recall": round(float(hit / actual), 3) if actual else None}

        row["truth_share"] = round(float(truth_mask.mean()), 3)
        row["silero_stats_mix"] = detector_stats(silero_mix)
        row["silero_stats_centre"] = detector_stats(silero_centre)
        row["webrtc_stats_mix"] = detector_stats(webrtc_mix)
        rows[name] = row
    raw6.unlink()
    raw2.unlink()
    return rows, cost


# --- Recipes ---------------------------------------------------------------------------------------------------------
GENTLE = "acompressor=threshold=0.0398:ratio=2.5:attack=20:release=300:knee=4:detection=rms:link=maximum"
STRONG = "acompressor=threshold=0.0200:ratio=4:attack=10:release=250:knee=4:detection=rms:link=maximum"
CENTRE_4DB = "pan=5.1|c0=c0|c1=c1|c2=1.585*c2|c3=c3|c4=c4|c5=c5"
CEILING = -1.5


def limiter():
    # The same settings GainPlan uses for --limit-db.
    return f"alimiter=limit={10 ** ((CEILING - 0.5) / 20):.4f}:attack=5:release=50:level=0:latency=1"


def apply_chain(x, chain):
    raw_in, raw_out = SCRATCH / "chain_in.raw", SCRATCH / "chain_out.raw"
    write_wav(raw_in, x)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "f32le", "-ar", str(FS), "-ch_layout", "5.1", "-i", str(raw_in),
                    "-af", chain, "-f", "f32le", str(raw_out)], check=True)
    out = np.fromfile(raw_out, dtype=np.float32).reshape(-1, 6)
    if len(out) < len(x):
        out = np.vstack([out, np.zeros((len(x) - len(out), 6), dtype=np.float32)])
    return out[: len(x)]


def measure(x):
    """Integrated loudness, LRA and true peak of a 5.1 mix, from FFmpeg's ebur128."""
    raw = SCRATCH / "tp.raw"
    write_wav(raw, x)
    return parse_ebur128(ffmpeg_filter(raw, 6, "5.1", "ebur128=peak=true"))


def split_process(f, chain):
    """Hagerman's method: run S+B and S-B through the same chain, then S' = (a+b)/2 and B' = (a-b)/2.

    The only way to see what a non-linear chain did to dialogue and background separately.
    """
    a = apply_chain(f["speech"] + f["background"], chain)
    b = apply_chain(f["speech"] - f["background"], chain)
    return (a + b) / 2, (a - b) / 2, a


def speech_to_background(speech, background, mask):
    """The median, over blocks where speech is sounding, of speech energy over background energy, in dB.

    A median over blocks says what a typical line of dialogue has to compete with. An integrated figure would
    be ruled by the few bursts that land on a line.
    """
    s_energy, starts, size = block_energy(speech, WEIGHTS)
    b_energy, _, _ = block_energy(background, WEIGHTS)
    cum = np.concatenate([[0], np.cumsum(mask.astype(np.float64))])
    keep = (cum[starts + size] - cum[starts]) / size >= 0.5
    return float(np.median(10 * np.log10(np.maximum(s_energy[keep], 1e-12) / np.maximum(b_energy[keep], 1e-12))))


def recipe_rows(built, gates):
    """Each recipe on each fixture: where the dialogue lands, what the file measures, and what the audio pays."""
    results = {}

    def recipes_for(g):
        programme, dialogue, tp = g["programme"], g["truth_dialogue"], g["true_peak"]
        limit = CEILING - tp + 6  # the most gain a limiter of up to 6 dB allows
        cap = CEILING - tp  # the most gain strict constant gain allows
        # No dialogue: Netflix's fallback of -24 whole-programme applies, under every dialogue recipe.
        anchor, target_27, target_24 = (dialogue, -27, -24) if dialogue is not None else (programme, -24, -24)
        # The best estimator for 5.1 on these fixtures: Silero on the centre channel, without the trim.
        estimate = g["silero_gate_centre"] if g["silero_speech_share_centre"] >= 0.15 else programme
        estimate_target = -27 if g["silero_speech_share_centre"] >= 0.15 else -24
        yield "A programme -20, peak-capped gain (today's default)", f"volume={min(-20 - programme, cap):.2f}dB"
        yield "B programme -20, limiter up to 6 dB", f"volume={min(-20 - programme, limit):.2f}dB,{limiter()}"
        yield "C programme -20, gentle compression then gain and limiter", (GENTLE, -20, "programme")
        yield "D programme -20, strong compression then gain and limiter", (STRONG, -20, "programme")
        yield "E dialogue -27 (known), peak-capped gain", f"volume={min(target_27 - anchor, cap):.2f}dB"
        yield "F dialogue -27 (known), limiter up to 6 dB", f"volume={min(target_27 - anchor, limit):.2f}dB,{limiter()}"
        yield "G dialogue -24 (known), limiter up to 6 dB", f"volume={min(target_24 - anchor, limit):.2f}dB,{limiter()}"
        yield "H dialogue -27 (known), centre +4 dB, limiter up to 6 dB", (CENTRE_4DB, target_27, "dialogue")
        yield "I dialogue -27 (Silero estimate), limiter up to 6 dB", f"volume={min(estimate_target - estimate, limit):.2f}dB,{limiter()}"
        # The ladder with a new trigger: compress only a file whose programme sits over 5 LU above its dialogue
        # (EBU R 128 s4's limit), using the Silero estimate. Everything else gets gain alone.
        over = dialogue is not None and programme - estimate > 5
        if over:
            yield "J dialogue -27 (Silero estimate), gentle compression only if over 5 LU above dialogue", (GENTLE, target_27, "dialogue")
        else:
            yield "J dialogue -27 (Silero estimate), gentle compression only if over 5 LU above dialogue", f"volume={min(estimate_target - estimate, limit):.2f}dB,{limiter()}"

    for name, f in built.items():
        g = gates[name]
        rows = {}
        before = speech_to_background(f["speech"], f["background"], f["truth_mask"]) if f["truth_mask"].any() else None
        for label, recipe in recipes_for(g):
            if isinstance(recipe, tuple):
                pre, target, anchor_kind = recipe
                # Two passes, as a real run would: apply the pre-chain, measure, then set the gain.
                probe_s, _, probe_mix = split_process(f, pre)
                measured_i, _, measured_tp = measure(probe_mix)
                level = measured_i if anchor_kind == "programme" or g["truth_dialogue"] is None else integrated(probe_s, WEIGHTS)
                applied = min(target - level, CEILING - measured_tp + 6)
                chain = f"{pre},volume={applied:.2f}dB,{limiter()}"
            else:
                chain = recipe
            speech_out, background_out, mix_out = split_process(f, chain)
            i, lra, tp = measure(mix_out)
            row = {"programme": round(i, 2), "lra": round(lra, 1), "true_peak": round(tp, 2), "chain": chain}
            if g["truth_dialogue"] is not None:
                row["dialogue"] = round(integrated(speech_out, WEIGHTS), 2)
                row["loudness_above_dialogue"] = round(i - row["dialogue"], 2)
                row["speech_to_background_change"] = round(speech_to_background(speech_out, background_out, f["truth_mask"]) - before, 2)
            rows[label] = row
        results[name] = rows
    return results


def summarise(gates, recipes):
    estimators = ["programme", "centre_ffmpeg", "oracle_gate_whole_mix", "oracle_gate_centre", "silero_gate_whole_mix",
                  "silero_gate_centre", "webrtc_gate_whole_mix", "silero_trimmed_whole_mix", "silero_trimmed_centre"]
    stereo_estimators = ["programme_stereo", "stereo_dialoguenhance", "silero_gate_stereo", "webrtc_gate_stereo",
                         "silero_trimmed_stereo"]
    errors = {}
    for est in estimators:
        errors[est] = {n: round(g[est] - g["truth_dialogue"], 2) for n, g in gates.items()
                       if g["truth_dialogue"] is not None and g[est] is not None and np.isfinite(g[est])}
    for est in stereo_estimators:
        errors[est] = {n: round(g[est] - g["truth_dialogue_stereo"], 2) for n, g in gates.items()
                       if g["truth_dialogue_stereo"] is not None and g[est] is not None and np.isfinite(g[est])}
    spread = {e: {"min": min(v.values()), "max": max(v.values()), "spread": round(max(v.values()) - min(v.values()), 2),
                  "mean_abs": round(float(np.mean(np.abs(list(v.values())))), 2)} for e, v in errors.items()}
    landing = {}
    labels = next(iter(recipes.values())).keys()
    for label in labels:
        values = [rows[label]["dialogue"] for rows in recipes.values() if "dialogue" in rows[label]]
        landing[label] = {"dialogue_min": min(values), "dialogue_max": max(values), "dialogue_spread": round(max(values) - min(values), 2)}
    return errors, spread, landing


def main():
    SCRATCH.mkdir(parents=True, exist_ok=True)
    RESULTS.mkdir(parents=True, exist_ok=True)
    built = build_fixtures()
    gates, cost = run_gates(built)
    recipes = recipe_rows(built, gates)
    errors, spread, landing = summarise(gates, recipes)
    numbers = {k: (round(v, 2) if isinstance(v, float) else v) for k, v in cost.items()}
    numbers["realtime_factor"] = {k.replace("_s", ""): round(cost["audio_s"] / v, 1) for k, v in cost.items() if k != "audio_s" and v > 0}
    payload = {"fixtures": FIXTURES, "gates": gates, "errors_LU": errors, "error_summary_LU": spread, "cost": numbers,
               "recipes": recipes, "dialogue_landing": landing}
    (RESULTS / "dialogue_results.json").write_text(json.dumps(payload, indent=1, default=lambda o: None if o is None else float(o)))
    print(json.dumps({"error_summary_LU": spread, "errors_LU": errors, "cost": numbers, "dialogue_landing": landing}, indent=1))


main()
