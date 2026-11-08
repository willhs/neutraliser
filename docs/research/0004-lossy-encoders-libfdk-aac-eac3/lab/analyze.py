"""Aggregate run.py (and score_lowpass.py) output into per-source tables: mean over the four windows, plus how many
windows each candidate beats the 'today' row on ViSQOL.

Usage: python3 -I analyze.py RUN_JSONL [LOWPASS_JSONL]
"""
import collections, json, statistics, sys

rows = [json.loads(l) for l in open(sys.argv[1])]
lp = {}
if len(sys.argv) > 2:
    for r in map(json.loads, open(sys.argv[2])):
        lp[(r['kind'], r['window'], r['cand'])] = r

by = collections.defaultdict(lambda: collections.defaultdict(list))
for r in rows:
    by[r['kind']][r['cand']].append(r)

for kind, cands in by.items():
    today = next((c for c in cands if 'today' in c), None)
    print(f'\n### {kind}  (gain per window: {sorted({r["gain_db"] for c in cands.values() for r in c})})')
    print('| candidate | file kbit/s | ViSQOL mean | min channel | ViSQOL <16 kHz | bandwidth kHz | SNR dB | windows better than today |')
    print('|---|---|---|---|---|---|---|---|')
    base = {r['window']: r['visqol_mean'] for r in cands[today]} if today else {}
    for cand, rs in cands.items():
        rs = sorted(rs, key=lambda r: r['window'])
        lps = [lp[(r['kind'], r['window'], cand)] for r in rs if (r['kind'], r['window'], cand) in lp]
        better = sum(r['visqol_mean'] > base.get(r['window'], 9) + 0.005 for r in rs) if today and cand != today else None
        print('| {} | {:.0f} | {:.3f} | {:.3f} | {} | {} | {:.1f} | {} |'.format(
            cand, statistics.mean(r['file_kbps'] for r in rs), statistics.mean(r['visqol_mean'] for r in rs),
            statistics.mean(r['visqol_min'] for r in rs),
            '{:.3f}'.format(statistics.mean(x['visqol_lp16_mean'] for x in lps)) if lps else '-',
            '{:.1f}'.format(statistics.mean(x['bandwidth_khz'] for x in lps)) if lps else '-',
            statistics.mean(r['snr_db'] for r in rs),
            f'{better}/{len(rs)}' if better is not None else 'n/a'))
