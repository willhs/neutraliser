# Neutraliser - Video Audio Volume Normalisation CLI

## Project Overview
A Ruby CLI tool that normalises audio volume in video files to create consistent playback levels throughout your video library.

## Technical Context
- **Language**: Ruby
- **Type**: Command-line interface
- **Purpose**: Video audio volume normalisation
- **Dependencies**: FFmpeg for video/audio processing

## Architecture Notes
- Pipeline-based processing
- Creates copies by default, option to replace originals
- Must preserve video quality while adjusting only audio levels
- Target consistent audio volume across entire video library
- Video stream copying with audio reencoding for efficiency

## Development Guidelines
- Follow Ruby best practices and conventions
- Use Thor or similar for CLI argument parsing
- Implement proper error handling for video file processing
- Consider batch processing capabilities
- Add progress indicators for long operations
- Use FFmpeg stream copying for video to avoid quality loss

## Testing Strategy
- Unit tests for core volume analysis logic
- Integration tests with sample video files
- CLI interface testing
- Performance tests for large video libraries
- Verify video quality preservation after processing