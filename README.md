# Neutraliser

A Ruby CLI tool for consistent audio volume normalisation across your video library.

## What it does

Never adjust your volume between videos again. Neutraliser analyses and adjusts the audio volume of your video files to create consistent playback levels throughout your entire library.

## Features

- **Consistent Volume**: Normalises audio tracks to a standard level across all video files
- **Safe by Default**: Creates copies of your files, leaving originals untouched
- **Flexible**: Option to replace original files with `--replace` flag
- **Batch Processing**: Process entire directories or individual files
- **Video Preservation**: Maintains video quality while only adjusting audio levels

## Installation

```bash
gem install neutraliser
```

## Usage

Process a single video:
```bash
neutraliser movie.mp4
```

Process a directory:
```bash
neutraliser /path/to/video/library
```

Replace original files instead of creating copies:
```bash
neutraliser --replace movie.mp4
```

## Requirements

- Ruby 2.7+
- FFmpeg (for video/audio processing)

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
