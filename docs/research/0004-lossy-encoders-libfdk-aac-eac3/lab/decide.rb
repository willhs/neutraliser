# frozen_string_literal: true

# What would the shipped code write for this file's next pass? Runs the real FFmpegWrapper.decide_codec
# (-> CodecChoice.decide, with the file's own NEUTRALISER_* stamp, the packet-size bitrate sample and the
# AC-3 dialnorm read) and the real FFmpegWrapper.build_stamp, and prints the answer as JSON for generations.py:
#   { encoder, bitrate (bps), first_generation_bitrate, source_bitrate, dialnorm, tags: {NEUTRALISER_*: value} }
#
# Usage: ruby decide.rb REPO_ROOT FILE OUTPUT_EXT GAIN_DB     (OUTPUT_EXT is '.mkv': what the pass writes)
require 'json'
repo, file, ext, gain = ARGV
$LOAD_PATH.unshift(File.join(repo, 'lib'))
require 'neutraliser'

stdout, stderr = Neutraliser::FFmpegWrapper.probe_file(file)
source = Neutraliser::Source.from_ffprobe(file, stdout, stderr)
decision = Neutraliser::FFmpegWrapper.decide_codec(source, "out#{ext}")
# build_stamp is a private class method; send reaches the real one rather than copying it
stamp = Neutraliser::FFmpegWrapper.send(
  :build_stamp, Neutraliser::Profiles.default_profile, Neutraliser::Mode::LINEAR, decision, gain: gain.to_f, measured: nil
)
puts JSON.generate(
  decision.slice(:encoder, :bitrate, :first_generation_bitrate, :source_bitrate, :dialnorm, :source_codec)
          .merge(stamp_in: source.stamp&.source_bitrate, tags: stamp.to_tags.reject { |_, v| v.empty? })
)
