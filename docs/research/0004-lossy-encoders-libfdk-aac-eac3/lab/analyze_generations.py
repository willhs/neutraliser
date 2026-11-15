"""Aggregate generations.py output: per source and generation, the mean over the four windows, the bitrate the shipped
code chose, and the paired per-window change from the previous generation.

Usage: python3 -I analyze_generations.py GENERATIONS_JSONL
"""
import collections, json, statistics, sys

rows = [json.loads(l) for l in open(sys.argv[1])]
by = collections.defaultdict(dict)  # (kind, gen) -> window -> row
for r in rows:
    by[(r['kind'], r['gen'])][r['window']] = r
kinds = list(dict.fromkeys(r['kind'] for r in rows))
gens = sorted({r['gen'] for r in rows})

print('| Source | Gen | Encoder, target kbit/s | Stamp first-gen kbit/s read | File kbit/s | ViSQOL | SNR dB | ViSQOL change from previous gen (per window: min to max) | SNR change |')
print('|---|---|---|---|---|---|---|---|---|')
for kind in kinds:
    for g in gens:
        cur = by[(kind, g)]
        ws = sorted(cur)
        mean = lambda f: statistics.mean(f(cur[w]) for w in ws)
        targets = {cur[w]['target_bps'] for w in ws}
        t = '/'.join(f'{x/1000:.0f}' for x in sorted(targets))
        seen = {cur[w]['stamp_source_bps_in'] for w in ws}
        s = 'none (no stamp)' if seen == {None} else '/'.join(f'{x/1000:.0f}' for x in sorted(seen))
        if g > 1:
            prev = by[(kind, g - 1)]
            dv = [cur[w]['visqol_mean'] - prev[w]['visqol_mean'] for w in ws]
            ds = [cur[w]['snr_db'] - prev[w]['snr_db'] for w in ws]
            dvs = f'{statistics.mean(dv):+.3f} ({min(dv):+.3f} to {max(dv):+.3f})'
            dss = f'{statistics.mean(ds):+.1f}'
        else:
            dvs = dss = '-'
        print(f"| {kind} | {g} | {cur[ws[0]]['encoder']} {t} | {s} | {mean(lambda r: r['file_kbps']):.0f} | "
              f"{mean(lambda r: r['visqol_mean']):.3f} | {mean(lambda r: r['snr_db']):.1f} | {dvs} | {dss} |")

print('\nGeneration 1 to 3, paired per window:')
for kind in kinds:
    a, c = by[(kind, 1)], by[(kind, gens[-1])]
    dv = [c[w]['visqol_mean'] - a[w]['visqol_mean'] for w in sorted(a)]
    ds = [c[w]['snr_db'] - a[w]['snr_db'] for w in sorted(a)]
    print(f'- {kind}: ViSQOL {statistics.mean(dv):+.3f} ({min(dv):+.3f} to {max(dv):+.3f}), SNR {statistics.mean(ds):+.1f} dB')

print('\nBitrate check, every window: generation N target == generation 1 target?')
for kind in kinds:
    for w in sorted(by[(kind, 1)]):
        t = [by[(kind, g)][w]['target_bps'] for g in gens]
        print(f'- {kind} {w}: targets {t}, first-generation figure read by pass {[by[(kind, g)][w]["first_generation_bps"] for g in gens]}, lag {[by[(kind, g)][w]["lag"] for g in gens]}')
