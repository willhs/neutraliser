"""Re-encode each source the way neutraliser does (decode with -drc_scale 0, constant gain, encode), once per
candidate encoder setting, and score the result against the source's own decode with the same gain.

reference = decode(source) + gain dB      (what a perfect re-encode would give; gain = min(+4, peak ceiling -1 dBFS minus the clip's peak))
test      = decode(encode(reference))
Metrics: ViSQOL v3 audio mode (pure-Python port, MOS-LQO 1-5, mean over the full-range channels, higher is better)
         and aligned SNR in dB (null test: reference minus test; not perceptual, shown to cross-check ViSQOL).

FFmpeg runs in the `fdk-lab` image (Dockerfile beside this file): 7.1.1 with libfdk_aac, same base as production.

Usage: python -I run.py WORK_DIR OUT_JSONL [kind ...]
"""
import concurrent.futures as cf
import json, pathlib, subprocess, sys
import numpy as np
import soundfile as sf

work = pathlib.Path(sys.argv[1]).resolve()
out_path = pathlib.Path(sys.argv[2]).resolve()
only = set(sys.argv[3:])
GAIN_MAX_DB = 4   # the most gain a clip gets
PEAK_CEILING_DB = -1  # neutraliser's peak cap: the output's sample peak lands no higher than this
GAINS = {}
DUR = 30

# name -> (container extension, encoder args). {r} is the 5.1(side)->5.1 relabel libfdk_aac needs.
NATIVE = lambda b, *x: ['-c:a', 'aac', '-b:a', f'{b}k', *x]
FDK = lambda b, *x: ['-c:a', 'libfdk_aac', '-b:a', f'{b}k', *x]
CANDIDATES = {
    'aac_20_128': {  # AAC-LC stereo 128k source
        'native_128 (today)': NATIVE(128), 'native_160 (+25%)': NATIVE(160), 'native_192': NATIVE(192),
        'native_128_no-pns-is': NATIVE(128, '-aac_pns', '0', '-aac_is', '0'),
        'native_96 (anchor)': NATIVE(96),
        'fdk_128': FDK(128), 'fdk_160 (+25%)': FDK(160), 'fdk_192': FDK(192),
        'fdk_vbr3': FDK(0, '-vbr', '3'), 'fdk_96 (anchor)': FDK(96),
    },
    'aac_51_384': {  # AAC-LC 5.1 384k source
        'native_384 (today: floor 256k, source 384k)': NATIVE(384), 'native_480 (+25%)': NATIVE(480),
        'fdk_384': FDK(384), 'fdk_480 (+25%)': FDK(480), 'native_256 (anchor)': NATIVE(256),
    },
    'ac3_51_448': {  # real Dolby AC-3 5.1 448k source
        'ac3_448 (today)': ['-c:a', 'ac3', '-b:a', '448k'], 'ac3_576 (+25%)': ['-c:a', 'ac3', '-b:a', '576k'],
        'ac3_640 (cap)': ['-c:a', 'ac3', '-b:a', '640k'],
        'eac3_448 (not today)': ['-c:a', 'eac3', '-b:a', '448k'], 'eac3_640': ['-c:a', 'eac3', '-b:a', '640k'],
    },
    'eac3_51_640': {  # E-AC-3 5.1 640k source (made with FFmpeg's encoder)
        'eac3_640 (today)': ['-c:a', 'eac3', '-b:a', '640k'], 'eac3_800 (+25%)': ['-c:a', 'eac3', '-b:a', '800k'],
        'eac3_640_no-coupling': ['-c:a', 'eac3', '-b:a', '640k', '-channel_coupling', '0'],
        'eac3_448 (anchor)': ['-c:a', 'eac3', '-b:a', '448k'],
        'ac3_640 (not today)': ['-c:a', 'ac3', '-b:a', '640k'],
    },
}


def ff(*args):
    cmd = ['docker', 'run', '--rm', '-v', f'{work}:/w', 'fdk-lab', 'ffmpeg', '-hide_banner', '-nostats',
           '-loglevel', 'error', '-y', *args]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr.strip()[-400:])


def run_one(kind, window, cand, enc):
    base = f'{kind}_{window}'
    src = f'src/{base}.' + ('ac3' if kind.startswith('ac3') else 'mkv')
    tag = ''.join(c if c.isalnum() else '_' for c in cand)
    enc_file = f'enc/{base}__{tag}.mkv'
    dec_file = f'dec/{base}__{tag}.wav'
    af = f'volume={gain_db(kind, window)}dB'
    if not (work / dec_file).exists():  # resumable: a finished decode is kept
        ff('-drc_scale', '0', '-i', f'/w/{src}', '-af', af, *enc, f'/w/{enc_file}')
        ff('-i', f'/w/{enc_file}', '-c:a', 'pcm_f32le', f'/w/{dec_file}')
    return enc_file, dec_file


def gain_db(kind, window):
    """Constant gain for this clip, peak-capped the way the real pipeline caps it (can be negative on a hot clip)."""
    if (kind, window) not in GAINS:
        base = f'{kind}_{window}'
        src = f'src/{base}.' + ('ac3' if kind.startswith('ac3') else 'mkv')
        cmd = ['docker', 'run', '--rm', '-v', f'{work}:/w', 'fdk-lab', 'ffmpeg', '-hide_banner', '-nostats', '-drc_scale', '0',
               '-i', f'/w/{src}', '-af', 'astats=measure_overall=Peak_level:measure_perchannel=none', '-f', 'null', '-']
        r = subprocess.run(cmd, capture_output=True, text=True)
        peak = float([l for l in r.stderr.splitlines() if 'Peak level dB' in l][-1].split(':')[-1])
        GAINS[(kind, window)] = round(min(GAIN_MAX_DB, PEAK_CEILING_DB - peak), 2)
    return GAINS[(kind, window)]


def ensure_ref(kind, window):
    base = f'{kind}_{window}'
    src = f'src/{base}.' + ('ac3' if kind.startswith('ac3') else 'mkv')
    ref = f'ref/{base}.wav'
    if not (work / ref).exists():
        ff('-drc_scale', '0', '-i', f'/w/{src}', '-af', f'volume={gain_db(kind, window)}dB', '-c:a', 'pcm_f32le', f'/w/{ref}')
    return ref


def aligned(ref, test, max_lag=4096):
    """Trim the encoder delay: shift `test` to the lag that best matches `ref` (on the first channel pair)."""
    n = min(len(ref), len(test), 48000 * 20)
    a, b = ref[:n, 0], test[:n, 0]
    best = (np.inf, 0)
    for lag in range(-max_lag, max_lag + 1, 1):
        x = a[max_lag:n - max_lag]
        y = b[max_lag + lag:n - max_lag + lag]
        e = float(np.mean((x - y) ** 2))
        if e < best[0]:
            best = (e, lag)
    lag = best[1]
    if lag > 0:
        test = test[lag:]
    elif lag < 0:
        ref = ref[-lag:]
    m = min(len(ref), len(test))
    return ref[:m], test[:m], lag


def score(args):
    kind, window, cand, ref_file, dec_file, enc_file, gain = args
    from visqol import VisqolApi
    ref, sr = sf.read(work / ref_file, dtype='float32')
    test, sr2 = sf.read(work / dec_file, dtype='float32')
    ref, test, lag = aligned(ref, test)
    chans = [0, 1] if ref.shape[1] == 2 else [0, 1, 2, 4, 5]  # skip LFE
    tmp = work / 'tmp'
    tmp.mkdir(exist_ok=True)
    api = VisqolApi()
    api.create(mode='audio')
    moslqo = {}
    for c in chans:
        rp, tp = tmp / f'{kind}_{window}_{abs(hash(cand))}_{c}_r.wav', tmp / f'{kind}_{window}_{abs(hash(cand))}_{c}_t.wav'
        sf.write(rp, ref[:, c], sr, subtype='FLOAT')
        sf.write(tp, test[:, c], sr, subtype='FLOAT')
        moslqo[c] = float(api.measure(str(rp), str(tp)).moslqo)
        rp.unlink(); tp.unlink()
    diff = ref - test
    snr = {int(c): float(10 * np.log10(np.sum(ref[:, c] ** 2) / max(np.sum(diff[:, c] ** 2), 1e-20))) for c in chans}
    kbps = (work / enc_file).stat().st_size * 8 / DUR / 1000
    return {'kind': kind, 'window': window, 'cand': cand, 'visqol': moslqo, 'visqol_mean': float(np.mean(list(moslqo.values()))),
            'visqol_min': min(moslqo.values()), 'snr_db': float(np.mean(list(snr.values()))), 'lag': lag,
            'file_kbps': round(kbps, 1), 'gain_db': gain}


def main():
    for d in ('enc', 'dec', 'ref'):
        (work / d).mkdir(exist_ok=True)
    jobs = []
    for kind, cands in CANDIDATES.items():
        if only and kind not in only:
            continue
        for window in ('w60', 'w200', 'w380', 'w520'):
            ensure_ref(kind, window)
            for cand, enc in cands.items():
                jobs.append((kind, window, cand, enc))
    print(f'{len(jobs)} encodes', flush=True)
    with cf.ThreadPoolExecutor(4) as pool:
        futs = {pool.submit(run_one, *j): j for j in jobs}
        done = []
        for f in cf.as_completed(futs):
            kind, window, cand, _ = futs[f]
            try:
                enc_file, dec_file = f.result()
            except Exception as e:  # keep going, record the failure
                print('ENC FAIL', kind, window, cand, e, flush=True)
                continue
            done.append((kind, window, cand, f'ref/{kind}_{window}.wav', dec_file, enc_file, gain_db(kind, window)))
    print(f'{len(done)} to score', flush=True)
    have = {(r['kind'], r['window'], r['cand']) for r in map(json.loads, open(out_path))} if out_path.exists() else set()
    done = [d for d in done if d[:3] not in have]
    with cf.ProcessPoolExecutor(6) as pool, open(out_path, 'a') as out:
        for r in pool.map(score, done, chunksize=1):
            out.write(json.dumps(r) + '\n')
            out.flush()
            print(r['kind'], r['window'], r['cand'], round(r['visqol_mean'], 3), round(r['snr_db'], 1), flush=True)


if __name__ == '__main__':
    main()
