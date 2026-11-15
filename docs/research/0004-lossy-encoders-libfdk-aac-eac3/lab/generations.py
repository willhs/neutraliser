"""Generation loss across repeated `--redo-recipe` passes: re-encode each source three times the way neutraliser does,
each pass reading the previous pass's output and the bitrate / encoder / stamp coming from the shipped code.

generation 1 = decode(source) + gain  -> encode      (the first pass; same gain rule as run.py)
generation 2 = decode(generation 1)   -> encode      (a --redo-recipe pass on a file already at target: gain 0 dB)
generation 3 = decode(generation 2)   -> encode
Each pass asks `decide.rb` (the real FFmpegWrapper.decide_codec, so CodecChoice with the file's own NEUTRALISER_*
stamp, and the real build_stamp) which encoder and bitrate to use, and writes the stamp tags into the output.

reference = decode(source) + gain dB, the same for every generation, so each score is the *cumulative* cost since the
source. ViSQOL v3 audio mode (pure-Python port, MOS-LQO) and aligned SNR, as in run.py.

FFmpeg runs in the `gen-lab` image (Debian 13's own `ffmpeg` package, 7.1.5: what the shipped image uses).
Usage: python -I generations.py WORK_DIR OUT_JSONL REPO_ROOT RUBY [kind ...]
"""
import concurrent.futures as cf
import json, pathlib, subprocess, sys
import numpy as np
import soundfile as sf

work = pathlib.Path(sys.argv[1]).resolve()
out_path = pathlib.Path(sys.argv[2]).resolve()
repo, ruby = sys.argv[3], sys.argv[4]
only = set(sys.argv[5:])
IMAGE = 'gen-lab'
GAIN_MAX_DB = 4
PEAK_CEILING_DB = -1
GENERATIONS = 3
DUR = 30
KINDS = ('aac_20_128', 'aac_51_384', 'ac3_51_448', 'eac3_51_640')
WINDOWS = ('w60', 'w200', 'w380', 'w520')


def docker(*args, check=True):
    r = subprocess.run(['docker', 'run', '--rm', '-v', f'{work}:/w', IMAGE, *args], capture_output=True, text=True)
    if check and r.returncode:
        raise RuntimeError(r.stderr.strip()[-400:])
    return r


def ff(*args):
    docker('ffmpeg', '-hide_banner', '-nostats', '-loglevel', 'error', '-y', *args)


def src_of(kind, window):
    return f'src/{kind}_{window}.' + ('ac3' if kind.startswith('ac3') else 'mkv')


def gain_db(kind, window):
    r = docker('ffmpeg', '-hide_banner', '-nostats', '-drc_scale', '0', '-i', f'/w/{src_of(kind, window)}',
               '-af', 'astats=measure_overall=Peak_level:measure_perchannel=none', '-f', 'null', '-')
    peak = float([l for l in r.stderr.splitlines() if 'Peak level dB' in l][-1].split(':')[-1])
    return round(min(GAIN_MAX_DB, PEAK_CEILING_DB - peak), 2)


def decide(path, gain):
    """The shipped code's answer for the next pass over `path`."""
    r = subprocess.run([ruby, str(pathlib.Path(repo) / 'docs/research/0004-lossy-encoders-libfdk-aac-eac3/lab/decide.rb'),
                        repo, str(path), '.mkv', str(gain)], capture_output=True, text=True, cwd=repo)
    if r.returncode:
        raise RuntimeError(r.stderr.strip()[-600:])
    return json.loads(r.stdout.strip().splitlines()[-1])


def encode_generations(kind, window):
    """Run the three passes; returns [(generation, decision, enc_file, dec_file)]."""
    base = f'{kind}_{window}'
    gain = gain_db(kind, window)
    ref = f'ref/{base}.wav'
    if not (work / ref).exists():
        ff('-drc_scale', '0', '-i', f'/w/{src_of(kind, window)}', '-af', f'volume={gain}dB', '-c:a', 'pcm_f32le', f'/w/{ref}')
    out, prev = [], src_of(kind, window)
    for g in range(1, GENERATIONS + 1):
        enc_file, dec_file = f'gen/{base}__g{g}.mkv', f'gen/{base}__g{g}.wav'
        d = decide(work / prev, gain if g == 1 else 0.0)
        if not (work / dec_file).exists():
            args = ['-drc_scale', '0', '-i', f'/w/{prev}']
            if g == 1:
                args += ['-af', f'volume={gain}dB']
            args += ['-c:a', d['encoder'], '-b:a', f"{d['bitrate'] // 1000}k"]
            if d.get('dialnorm'):
                args += ['-dialnorm', str(d['dialnorm'])]
            for k, v in d['tags'].items():
                args += ['-metadata:s:a:0', f'{k}={v}']
            ff(*args, f'/w/{enc_file}')
            ff('-i', f'/w/{enc_file}', '-c:a', 'pcm_f32le', f'/w/{dec_file}')
        out.append((g, d, enc_file, dec_file))
        prev = enc_file
    return ref, gain, out


def aligned(ref, test, max_lag=8192):
    """Trim the accumulated encoder delay: the lag that best matches `ref` on the first channel, by FFT cross-correlation."""
    n = min(len(ref), len(test), 48000 * 20)
    a, b = ref[:n, 0].astype(np.float64), test[:n, 0].astype(np.float64)
    size = 1 << (2 * n - 1).bit_length()
    xc = np.fft.irfft(np.fft.rfft(b, size) * np.conj(np.fft.rfft(a, size)), size)
    cand = np.concatenate([xc[:max_lag + 1], xc[-max_lag:]])
    lags = np.concatenate([np.arange(0, max_lag + 1), np.arange(-max_lag, 0)])
    lag = int(lags[int(np.argmax(cand))])
    if lag > 0:
        test = test[lag:]
    elif lag < 0:
        ref = ref[-lag:]
    m = min(len(ref), len(test))
    return ref[:m], test[:m], lag


def score(args):
    kind, window, g, ref_file, dec_file, enc_file, gain, d = args
    from visqol import VisqolApi
    ref, sr = sf.read(work / ref_file, dtype='float32')
    test, _ = sf.read(work / dec_file, dtype='float32')
    ref, test, lag = aligned(ref, test)
    chans = [0, 1] if ref.shape[1] == 2 else [0, 1, 2, 4, 5]  # skip LFE
    tmp = work / 'tmp'
    tmp.mkdir(exist_ok=True)
    api = VisqolApi()
    api.create(mode='audio')
    moslqo = {}
    for c in chans:
        rp, tp = tmp / f'{kind}_{window}_g{g}_{c}_r.wav', tmp / f'{kind}_{window}_g{g}_{c}_t.wav'
        sf.write(rp, ref[:, c], sr, subtype='FLOAT')
        sf.write(tp, test[:, c], sr, subtype='FLOAT')
        moslqo[c] = float(api.measure(str(rp), str(tp)).moslqo)
        rp.unlink(); tp.unlink()
    diff = ref - test
    snr = {int(c): float(10 * np.log10(np.sum(ref[:, c] ** 2) / max(np.sum(diff[:, c] ** 2), 1e-20))) for c in chans}
    return {'kind': kind, 'window': window, 'gen': g, 'visqol_mean': float(np.mean(list(moslqo.values()))),
            'visqol_min': min(moslqo.values()), 'snr_db': float(np.mean(list(snr.values()))), 'lag': lag,
            'file_kbps': round((work / enc_file).stat().st_size * 8 / DUR / 1000, 1), 'gain_db': gain,
            'encoder': d['encoder'], 'target_bps': d['bitrate'], 'first_generation_bps': d['first_generation_bitrate'],
            'source_bps_seen': d['source_bitrate'], 'stamp_source_bps_in': d['stamp_in']}


def main():
    for d in ('gen', 'ref', 'tmp'):
        (work / d).mkdir(exist_ok=True)
    cases = [(k, w) for k in KINDS for w in WINDOWS if not only or k in only]
    jobs = []
    with cf.ThreadPoolExecutor(4) as pool:
        for (kind, window), (ref, gain, gens) in zip(cases, pool.map(lambda c: encode_generations(*c), cases)):
            for g, d, enc_file, dec_file in gens:
                jobs.append((kind, window, g, ref, dec_file, enc_file, gain, d))
    print(f'{len(jobs)} to score', flush=True)
    have = {(r['kind'], r['window'], r['gen']) for r in map(json.loads, open(out_path))} if out_path.exists() else set()
    jobs = [j for j in jobs if j[:3] not in have]
    with cf.ProcessPoolExecutor(6) as pool, open(out_path, 'a') as out:
        for r in pool.map(score, jobs, chunksize=1):
            out.write(json.dumps(r) + '\n')
            out.flush()
            print(r['kind'], r['window'], r['gen'], r['encoder'], r['target_bps'], r['file_kbps'], round(r['visqol_mean'], 3),
                  round(r['snr_db'], 1), flush=True)


if __name__ == '__main__':
    main()
