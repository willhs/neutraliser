# Neutraliser

A Ruby CLI tool for consistent audio volume normalisation across your video library.

## What it does

Never adjust your volume between videos again. Neutraliser analyses and adjusts the audio volume of your video files to create consistent playback levels throughout your entire library.

## Features

- **Consistent Volume**: Normalises audio tracks to a standard level across all video files
- **Safe by Default**: Creates copies of your files, leaving originals untouched
- **Flexible**: Option to replace original files with `--replace` flag
- **Batch Processing**: Process entire directories or individual files
- **Quality Preservation**: Matches source audio codec and bitrate — no unnecessary quality loss during normalization
- **Video Preservation**: Maintains video quality while only adjusting audio levels

## Installation

Install FFmpeg (see `Requirements`), then run the CLI straight from source:

```bash
git clone https://github.com/your-username/neutraliser.git
cd neutraliser
bundle install
bundle exec neutraliser --help
```

For optional gem builds or development workflow details, see the sections below.

## Quick start

- **Process a single video**

  ```bash
  bundle exec neutraliser movie.mp4
  ```

- **Process an entire directory**

  ```bash
  bundle exec neutraliser process /path/to/video/library
  ```

- **Replace the original file instead of saving a copy**

  ```bash
  bundle exec neutraliser process --replace movie.mp4
  ```

- **Dry-run to inspect loudness only**

  ```bash
  bundle exec neutraliser process --dry-run movie.mp4
  ```

## CLI commands

### `process`

`neutraliser process PATH`

- Run the full normalisation pipeline on the file or directory located at `PATH`.

- **`--profile`**: Normalisation profile (`reference`, `livingroom` *(default)*, `night`).
- **`--target-level`**: Override LUFS target explicitly.
- **`--tolerance`**: Skip files within this LU range *(default: 1.0)*.
- **`--replace`**: Replace originals rather than writing `*_normalized` copies.
- **`--cache/--no-cache`**: Toggle loudness analysis caching.
- **`--dry-run`**: Analyse only; no output files.
- **`--parallel/--no-parallel`**: Enable or disable multi-file parallel processing.
- **`--max-threads`**: Set worker thread count for parallel processing.
- **`--fast-verify/--no-fast-verify`**: Enable or disable quick pre-verification before full analysis.
- **`--resume`**: Resume a prior directory run using `.neutraliser-run-manifest.jsonl` and skip completed files.
- `process` exits with status `1` when any file fails, so batch runners can detect partial failure.

### `profiles`

`neutraliser profiles [--verbose|-v]`

- Display the built-in loudness profiles and their associated targets.

- Lists available normalisation profiles and their LUFS / true-peak targets.
- Add `--verbose` for descriptions of each profile.

### `cache`

`neutraliser cache SUBCOMMAND`

- Inspect or maintain stored loudness analysis caches.

- **`stats PATH`**: Show cache counts and storage for analysed files in `PATH`.
- **`clean PATH`**: Remove cache data older than the configured `--max-age` (days).

### `analyze-plex`

`neutraliser analyze-plex [options]`

- Audit audio loudness levels across your Plex media libraries.

- **`--server-url`**: Plex host (`http://localhost:32400` by default).
- **`--token`**: Plex auth token (falls back to `PLEX_TOKEN` in `.env`).
- **`--library`**: Restrict analysis to a single Plex library.
- **`--output-format`**: `table`, `csv`, or `json` reporting.
- **`--sample-percent`**: Sample percentage for large libraries *(default: 100)*.

### `version`

`neutraliser version`

- Print the currently installed Neutraliser CLI version number.

- Prints the currently installed version of the CLI.

## Requirements

- **Ruby** 2.7+
- **FFmpeg** 4.2+ available on the command line
- *(Optional)* **Plex token** in `.env` when using `analyze-plex`

## Development

```bash
git clone https://github.com/your-username/neutraliser.git
cd neutraliser
bundle install
```

Run tests:
```bash
bundle exec rspec
```

## License

MIT
