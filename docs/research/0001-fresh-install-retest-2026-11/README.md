# Fresh-install retest, 2026-11-01

Follow-up to the 2026-08-08 test (task 1e605e7f), which pre-dates the October changes and the Docker image. Followed the README literally as a stranger, on `main` at `801ea90` (the commit the `:latest` GHCR image was built from: its `org.opencontainers.image.revision` label matches).

**Result: all four routes work as documented. No bugs found.** One README gap fixed (the Docker `--user` warning).

Setup: macOS arm64, Ruby 3.2.3, FFmpeg 7.1.1 on the host. Each route used its own temp `HOME` and gem dir (`BUNDLE_PATH` / `GEM_HOME` under `/tmp/nt/`), and a synthetic 20 s clip (`testsrc` video, 440 Hz sine at -25 dB, AAC 128k, mkv) in a temp media dir. Nothing touched the real library, NAS, tags or releases.

Clip generation (every route):

```bash
ffmpeg -y -f lavfi -i "testsrc=duration=20:size=320x240:rate=24" -f lavfi -i "sine=frequency=440:duration=20" \
  -af volume=-25dB -c:v libx264 -c:a aac -b:a 128k -shortest quiet.mkv
```

## Route A: run from source (`git clone` + `bundle install`)

```bash
git clone https://github.com/willhs/neutraliser.git && cd neutraliser   # HEAD 801ea90
bundle install                       # Bundle complete! 4 Gemfile dependencies, 29 gems now installed.
bundle exec neutraliser --help       # lists analyze-plex, cache, import-manifest, process, profiles, report, tree, version
bundle exec neutraliser process quiet.mkv
```
```
Current: -46.8 LUFS, Target: -20.0 LUFS (26.8 LU adjustment)
Audio: aac (LC) 68k -> aac 128k
Normalization: Linear
Saved: .../quiet_normalized.mkv
Summary: found=1, queued=1, resumed=0, done=1, skipped=0, failed=0, linear=1, dynamic=0, limited=0     (exit 0)
```
Re-run: `Already processed, skipping`, `done=0, skipped=1` (exit 0). `process --replace DIR` then `Replaced: .../quiet.mkv`, a second `--replace` run skips. `report DIR`:
```
Files: 2
  normalised linear:  2
  normalised limited: 0
  normalised dynamic: 0
  untouched:          0
Profiles: livingroom=2
```
Also checked: `--dry-run` (`[DRY RUN] Would normalize: -46.8 LUFS → -20.0 LUFS`), `profiles --verbose`, `version` (`Neutraliser v0.1.0`).

## Route B: local gem

```bash
gem build neutraliser.gemspec        # Successfully built RubyGem, neutraliser-0.1.0.gem
gem install ./neutraliser-0.1.0.gem  # 7 gems installed
neutraliser process quiet.mkv        # same output as route A, exit 0
neutraliser process quiet.mkv        # Already processed, skipping
neutraliser report DIR               # normalised linear: 1, untouched: 1 (the original), Profiles: livingroom=1
```

## Route C: published image `ghcr.io/willhs/neutraliser:latest`

```bash
docker pull ghcr.io/willhs/neutraliser:latest    # image built 2026-10-31, revision 801ea90, ffmpeg 7.1.5 (Debian 13)
docker run --rm -v $M:/media ghcr.io/willhs/neutraliser:latest process --replace --resume /media
```
```
Found 1 video file(s) ... Audio: aac (LC) 68k -> aac 128k ... Replaced: /media/quiet.mkv
Summary: found=1, queued=1, resumed=0, done=1, ... linear=1
Manifest: /media/.neutraliser-run-manifest.jsonl     (exit 0)
```
Same command again: `Resume mode: skipping 1 completed file(s)`, `resumed=1` (exit 0). `report /media` shows `normalised linear: 1`. With `--user $(id -u):$(id -g)` it runs and skips correctly, but prints `Warning: not keeping a log file (Permission denied @ dir_s_mkdir - /.local)`. README said "Logs then go to stdout only" without mentioning the warning; now it does.

## Route D: `docker build -t neutraliser .`

Builds; `docker run --rm neutraliser version` prints `Neutraliser v0.1.0`.

## Other README commands

`neutraliser movie.mkv --dry-run` (default command works), `--target-level -18.0`, `--profile night --lock-file`, `report --format tsv`, `cache stats`, `--replace --fast --allow-dynamic --resume` all behave as documented. `--fast` alone errors with the documented message (exit 1).

Raw captured output is in the job's `evidence/` directory (`routeA-run.txt`, `routeB-gem.txt`, `routeC-ghcr.txt`, `routeD-dockerbuild.txt`, `readme-commands.txt`).

## Not covered

`analyze-plex` (needs a Plex server), and Linux hosts without Docker (only the Debian image was exercised on Linux).
