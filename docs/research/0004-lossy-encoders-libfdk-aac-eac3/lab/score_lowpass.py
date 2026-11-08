"""Second scoring pass over run.py's decodes: ViSQOL after low-passing BOTH reference and test at 16 kHz.

Why: libfdk_aac at 128 kbit/s stereo cuts the top of the spectrum (about 16 kHz) where FFmpeg's encoder keeps more, and ViSQOL's
audio mode charges that as damage. This pass asks the narrower question: how good is the content below 16 kHz, where
most adults hear?  Also reports each decode's measured bandwidth (highest 1 kHz band within 40 dB of the reference's level).

Usage: python -I score_lowpass.py WORK_DIR RUN_JSONL OUT_JSONL
"""
import concurrent.futures as cf
import json, pathlib, sys
import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfiltfilt

work, run_jsonl, out_jsonl = (pathlib.Path(a).resolve() for a in sys.argv[1:4])
CUT = 16000


def tag(cand):
    return ''.join(c if c.isalnum() else '_' for c in cand)


def bandwidth_khz(x, sr):
    """Highest frequency whose 500 Hz-band power is above (loudest band - 70 dB), i.e. where the encoder stops."""
    n = min(len(x), sr * 20)
    X = np.abs(np.fft.rfft(x[:n] * np.hanning(n))) ** 2
    f = np.fft.rfftfreq(n, 1 / sr)
    edges = np.arange(0, 24000, 500)
    p = np.array([10 * np.log10(X[(f >= a) & (f < a + 500)].sum() + 1e-20) for a in edges])
    live = np.where(p > p.max() - 70)[0]
    return float(edges[live.max()] + 500) / 1000


def score(rec):
    from visqol import VisqolApi
    base = f"{rec['kind']}_{rec['window']}"
    ref, sr = sf.read(work / f'ref/{base}.wav', dtype='float32')
    test, _ = sf.read(work / f"dec/{base}__{tag(rec['cand'])}.wav", dtype='float32')
    lag = rec['lag']
    if lag > 0:
        test = test[lag:]
    elif lag < 0:
        ref = ref[-lag:]
    m = min(len(ref), len(test))
    ref, test = ref[:m], test[:m]
    sos = butter(8, CUT, btype='low', fs=sr, output='sos')
    chans = [0, 1] if ref.shape[1] == 2 else [0, 1, 2, 4, 5]
    tmp = work / 'tmp'
    tmp.mkdir(exist_ok=True)
    api = VisqolApi()
    api.create(mode='audio')
    vals = []
    for c in chans:
        rp, tp = tmp / f'lp_{base}_{tag(rec["cand"])}_{c}_r.wav', tmp / f'lp_{base}_{tag(rec["cand"])}_{c}_t.wav'
        sf.write(rp, sosfiltfilt(sos, ref[:, c]).astype('float32'), sr, subtype='FLOAT')
        sf.write(tp, sosfiltfilt(sos, test[:, c]).astype('float32'), sr, subtype='FLOAT')
        vals.append(float(api.measure(str(rp), str(tp)).moslqo))
        rp.unlink(); tp.unlink()
    return {'kind': rec['kind'], 'window': rec['window'], 'cand': rec['cand'], 'visqol_lp16_mean': float(np.mean(vals)),
            'bandwidth_khz': bandwidth_khz(test[:, 0], sr), 'ref_bandwidth_khz': bandwidth_khz(ref[:, 0], sr)}


if __name__ == '__main__':
    recs = [json.loads(l) for l in open(run_jsonl)]
    with cf.ProcessPoolExecutor(8) as pool, open(out_jsonl, 'w') as out:
        for r in pool.map(score, recs):
            out.write(json.dumps(r) + '\n')
            out.flush()
            print(r['kind'], r['window'], r['cand'], round(r['visqol_lp16_mean'], 3), r['bandwidth_khz'], flush=True)
