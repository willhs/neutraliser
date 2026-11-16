"""Independent BS.1770-4 / EBU R128 meter for a local audio file (research 0006).

Shares nothing with ffmpeg's loudnorm or ebur128 filters except the decoder: ffmpeg decodes the track to
48 kHz float PCM (DRC off), and everything else (K-weighting, channel weights, gating, loudness range) is
done here with numpy / scipy, streamed so a two-hour 7.1 film does not need to fit in memory.

  python3 bs1770.py FILE AUDIO_INDEX  -> JSON {i, lra, sample_peak_db, channels, layout, weights, seconds}

Channel weights follow BS.1770-4: front L/R/C 1.0, every surround or back or side channel 1.41 (+1.5 dB),
LFE excluded. Channel order comes from the decoder's layout via ffprobe (FFmpeg's native order).
"""
import json
import subprocess
import sys

import numpy as np
from scipy.signal import sosfilt, tf2sos

FS = 48000
# K-weighting stage 1 (high shelf) and stage 2 (RLB high-pass), BS.1770 coefficients at 48 kHz.
SHELF = (np.array([1.53512485958697, -2.69169618940638, 1.19839281085285]),
         np.array([1.0, -1.69065929318241, 0.73248077421585]))
RLB = (np.array([1.0, -2.0, 1.0]), np.array([1.0, -1.99004745483398, 0.99007225036621]))
SOS = np.vstack([tf2sos(*SHELF), tf2sos(*RLB)])

# FFmpeg native channel order, by layout name, as weights (None = LFE, excluded).
FRONT, SURR = 1.0, 1.41
ORDER = {
    'mono': [FRONT], 'stereo': [FRONT, FRONT],
    '5.1': [FRONT, FRONT, FRONT, None, SURR, SURR], '5.1(side)': [FRONT, FRONT, FRONT, None, SURR, SURR],
    '7.1': [FRONT, FRONT, FRONT, None, SURR, SURR, SURR, SURR],
    '7.1(wide)': [FRONT, FRONT, FRONT, None, SURR, SURR, FRONT, FRONT],
    '7.1(wide-side)': [FRONT, FRONT, FRONT, None, FRONT, FRONT, SURR, SURR],
}


def probe(path, index):
    out = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', f'a:{index}', '-show_entries',
                          'stream=channels,channel_layout,sample_rate', '-of', 'json', path],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)['streams'][0]


def weights_for(stream):
    layout = stream.get('channel_layout') or ''
    if layout in ORDER:
        return layout, ORDER[layout]
    raise SystemExit(f'unhandled layout {layout!r} ({stream.get("channels")} ch)')


def meter(path, index):
    stream = probe(path, index)
    layout, weights = weights_for(stream)
    n = len(weights)
    w = np.array([0.0 if x is None else x for x in weights])
    cmd = ['ffmpeg', '-v', 'error', '-nostdin', '-drc_scale', '0', '-i', path, '-map', f'0:a:{index}', '-ar', str(FS),
           '-f', 'f32le', '-acodec', 'pcm_f32le', '-']
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    hop = FS // 10  # 100 ms
    zi = np.zeros((SOS.shape[0], 2, n))  # sosfilt state per section and channel
    leftover = np.zeros((0, n), dtype=np.float32)
    energies = []  # mean-square (weighted, summed over channels) per 100 ms hop
    peak = 0.0
    bytes_per = 4 * n
    while True:
        buf = proc.stdout.read(hop * bytes_per * 20)
        if not buf:
            break
        usable = len(buf) - len(buf) % bytes_per
        chunk = np.frombuffer(buf[:usable], dtype=np.float32).reshape(-1, n)
        peak = max(peak, float(np.abs(chunk).max()))
        chunk = np.vstack([leftover, chunk])
        full = (len(chunk) // hop) * hop
        leftover = chunk[full:]
        if full == 0:
            continue
        x = chunk[:full].astype(np.float64)
        # sosfilt along time per channel, carrying state across chunks
        y, zi = sosfilt(SOS, x, axis=0, zi=zi)
        energies.extend(((y ** 2).reshape(-1, hop, n).mean(axis=1) * w).sum(axis=1))
    proc.wait()
    e = np.array(energies)
    seconds = len(e) / 10.0
    # 400 ms blocks (4 hops), overlapping by 75 %; 3 s short-term (30 hops)
    def window(k):
        c = np.cumsum(np.insert(e, 0, 0.0))
        return (c[k:] - c[:-k]) / k

    def lufs(ms):
        with np.errstate(divide='ignore'):
            return -0.691 + 10 * np.log10(ms)

    m = window(4)
    lm = lufs(m)
    above = lm > -70
    rel = lufs(m[above].mean()) - 10
    gated = m[(lm > rel) & above]
    integrated = float(lufs(gated.mean())) if gated.size else float('-inf')
    s = window(30)
    ls = lufs(s)
    ls = ls[ls > -70]
    if ls.size:
        rel_lra = lufs(np.mean(10 ** ((ls + 0.691) / 10))) - 20
        ls = ls[ls > rel_lra]
    lra = float(np.percentile(ls, 95) - np.percentile(ls, 10)) if ls.size else 0.0
    return {'i': round(integrated, 2), 'lra': round(lra, 2),
            'sample_peak_db': round(20 * np.log10(peak), 2) if peak > 0 else None,
            'channels': n, 'layout': layout, 'weights': weights, 'seconds': seconds}


if __name__ == '__main__':
    print(json.dumps(meter(sys.argv[1], int(sys.argv[2]))))
