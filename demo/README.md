# Demo

Three scripts, all regenerating charts used in the main README.

| Script | Output | Answers |
|---|---|---|
| `demo/ab.rb` | `loudness-over-time.svg` | "What does a sitting sound like?" — four files back to back, perceived loudness before vs after |
| `demo/run.rb` | `loudness-before-after.svg` | "What happens across a library?" — per-file integrated loudness before vs after |
| `demo/real_library.rb` | `real-library.svg` | "Does this hold on real films?" — before/after from a production library's own sidecars |

## A/B test — `demo/ab.rb`

```bash
ruby demo/ab.rb
```

Builds two playlists from the same source clips (one untouched, one normalised),
plots short-term loudness across each, and writes `before.mkv` / `after.mkv` into
the work dir **so you can listen to the difference**, not just look at it.

Example output:

```
  quiet film        -26.9 ->  -20.0 LUFS
  loud remaster     -11.6 ->  -20.1 LUFS
  quiet doco        -23.4 ->  -20.2 LUFS
  TV episode        -15.4 ->  -20.2 LUFS

swing across the sitting: 15.5 LU -> 0.5 LU
```

## Library sweep — `demo/run.rb`

```bash
ruby demo/run.rb
```

The default run builds 8 synthetic clips deliberately spread from about −30 to
−11 LUFS, normalises them with `--profile livingroom --replace`, and measures
each one before and after. It writes `demo/loudness-before-after.svg` and prints
a table (exact figures vary slightly run to run — the synthetic audio is random):

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

The synthetic clips prove the mechanism, not that it works on your files. Both
scripts take `--source`:

```bash
ruby demo/run.rb --source ~/media/movies --limit 8
ruby demo/ab.rb  --source ~/media/movies
```

Files are **copied** into the scratch work dir first and normalised there — your
originals are never touched.

## Charting a real library — `demo/real_library.rb`

The synthetic charts prove the mechanism. This one uses data Neutraliser already
left behind in a real library, so nothing is staged.

Every analysis writes a `.loudnorm_<profile>.json` sidecar recording the file's
loudness at that moment. When the file is later normalised in place, the sidecar
keeps the **pre-normalisation** number while the file on disk holds the
**result** — a genuine before/after pair for the same film.

Find the pairs (sidecar whose recorded `video_size` no longer matches the file):

```bash
find /path/to/library -name '*.loudnorm_*.json' | while read p; do
  d=$(dirname "$p")
  vf=$(grep -o '"video_file": "[^"]*"' "$p" | sed 's/.*: "//;s/"$//')
  ii=$(grep -o '"input_i": "[^"]*"' "$p" | sed 's/.*: "//;s/"$//')
  vs=$(grep -o '"video_size": [0-9]*' "$p" | grep -o '[0-9]*$')
  cur=$(stat -Lc %s "$d/$vf" 2>/dev/null || echo -1)   # -L: follow symlinks
  [ "$vs" != "$cur" ] && echo "$ii|$d/$vf"
done
```

Note the `-L` on `stat`. Libraries that symlink across volumes will otherwise
report the *link* size (a hundred-odd bytes) for every linked file, and every one
of them looks stale.

Re-measure those files to get the "after" side, build a
`before<TAB>after<TAB>label` TSV, then:

```bash
ruby demo/real_library.rb --pairs pairs.tsv
```

Measuring runs wherever the library lives (a NAS is usually far slower than a
laptop — budget minutes per film), which is why this step is a separate script
rather than folded into `run.rb`.

## Verified on real film audio

A real film clip at −34.9 LUFS, normalised to `livingroom` (a 14.7 LU boost):

| | before | after |
|---|---|---|
| Integrated loudness | −34.9 LUFS | −20.2 LUFS |
| Loudness range (LRA) | 12.5 LU | 12.5 LU — unchanged |
| True peak | −17.8 dBFS | −3.0 dBFS |
| Audio codec | AAC 162k | AAC 162k |
| Video bitstream | — | MD5-identical, stream-copied |

The unchanged LRA is the important row: Neutraliser applied constant gain rather
than compression, so the mix's own dynamics survive intact. The clip itself isn't
in the repo (it's copyrighted); reproduce the check on any file with:

```bash
ffmpeg -i FILE -map a:0 -af ebur128=peak=true:framelog=quiet -f null -
```

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
| `--duration SECS` | `20` (`run.rb`) / `15` (`ab.rb`) | Length of each synthetic clip |
| `--output PATH` | per script | Where to write the chart |

`--limit` applies to `run.rb` only; `ab.rb` always uses up to 4 files.
