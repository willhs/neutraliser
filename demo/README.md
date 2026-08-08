# Demo

Generates the before/after loudness chart in the main README.

```bash
ruby demo/run.rb
```

The default run builds 8 synthetic clips deliberately spread from about −30 to
−11 LUFS, normalises them with `--profile livingroom --replace`, and measures
each one before and after. It writes `demo/loudness-before-after.svg` and prints
a table:

```
file                             before      after
clip_01.mkv                      -29.4     -20.2
clip_02.mkv                      -24.9     -20.2
clip_03.mkv                      -22.4     -20.2
clip_04.mkv                      -18.9     -20.3
clip_05.mkv                      -17.4     -20.2
clip_06.mkv                      -14.9     -20.1
clip_07.mkv                      -12.4     -20.1
clip_08.mkv                      -10.7     -20.0

spread: 18.7 LU -> 0.3 LU
```

## Run it against your own library

The synthetic clips prove the mechanism, not that it works on your files. Point
it at a real directory to check for yourself:

```bash
ruby demo/run.rb --source ~/media/movies --limit 8
```

Files are **copied** into the scratch work dir first and normalised there — your
originals are never touched.

## How it's measured

Loudness is measured with ffmpeg's `ebur128` filter, deliberately a different
filter from the `loudnorm` one Neutraliser uses to make its decisions. The
numbers are an independent check, not the tool grading its own homework.

## Options

| Flag | Default | Description |
|---|---|---|
| `--source DIR` | — | Use real video files from `DIR` instead of synthetic clips |
| `--limit N` | `8` | Max files to take from `--source` |
| `--work-dir DIR` | temp dir | Scratch directory; wiped at the start of each run |
| `--profile NAME` | `livingroom` | Profile to normalise against |
| `--duration SECS` | `20` | Length of each synthetic clip |
| `--output PATH` | `demo/loudness-before-after.svg` | Where to write the chart |
