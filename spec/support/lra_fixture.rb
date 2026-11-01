# frozen_string_literal: true

require 'open3'
require 'json'

# A 5.1 clip with the structure of a film mix, for the --lra-target specs and
# demo/compression_ladder.rb: quiet dialogue that lives only in the centre
# channel, between loud effects on all six channels, over a quiet bed. Pink noise
# at fixed levels per scene stands in for the sound, so the loudness range is
# known and repeatable (about -22 LUFS and LRA 15, near the clip the first tests used). It says nothing about how real dialogue or music is
# affected: it is a way to check the arithmetic (LRA, level, tags), not the ear.
module LraFixture
  # [seconds, noise amplitude, where it plays]
  SCENES = [
    [4, 0.15, :centre], [4, 0.25, :all], [4, 0.20, :centre], [4, 0.06, :all],
    [4, 0.40, :all], [4, 0.17, :centre], [4, 0.12, :all], [4, 0.22, :centre]
  ].freeze

  LAYOUT_PAN = {
    centre: 'pan=5.1|c2=c0',
    all: 'pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0'
  }.freeze

  module_function

  # Writes a Matroska file with the 5.1 mix as its default audio track (AC-3),
  # a stereo commentary track that must be left alone, and a video stream.
  def build(path, dir)
    inputs = SCENES.flat_map do |seconds, amplitude, _where|
      ['-f', 'lavfi', '-i', "anoisesrc=color=pink:duration=#{seconds}:sample_rate=48000:amplitude=#{amplitude}"]
    end
    chains = SCENES.each_with_index.map { |(_, _, where), i| "[#{i}:a]#{LAYOUT_PAN.fetch(where)}[s#{i}]" }
    labels = SCENES.each_index.map { |i| "[s#{i}]" }.join
    graph = "#{chains.join(';')};#{labels}concat=n=#{SCENES.length}:v=0:a=1[mix]"
    total = SCENES.sum(&:first)
    run!('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
         *inputs,
         '-f', 'lavfi', '-i', "color=c=blue:size=64x64:duration=#{total}:rate=10",
         '-f', 'lavfi', '-i', "anoisesrc=color=pink:duration=#{total}:sample_rate=48000:amplitude=0.1",
         '-filter_complex', graph,
         '-map', "#{SCENES.length}:v", '-map', '[mix]', '-map', "#{SCENES.length + 1}:a",
         '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a:0', 'ac3', '-b:a:0', '448k', '-c:a:1', 'aac', '-ac:a:1', '2',
         '-metadata:s:a:0', 'language=eng', '-metadata:s:a:1', 'language=fre',
         '-disposition:a:0', 'default', '-disposition:a:1', '0', File.join(dir, File.basename(path)))
    path
  end

  # Integrated loudness, loudness range and true peak of audio stream `index`,
  # read with ebur128 (a different filter from the loudnorm one neutraliser
  # decides with, so this is not the tool marking its own work).
  def measure(path, index = 0)
    out, = Open3.capture2e('ffmpeg', '-hide_banner', '-nostats', '-i', path, '-map', "0:a:#{index}",
                           '-af', 'ebur128=peak=true', '-f', 'null', '-')
    summary = out[/Summary:.*\z/m] or raise "no ebur128 summary for #{path}\n#{out}"
    {
      i: summary[/^\s+I:\s+(-?[\d.]+) LUFS/, 1].to_f,
      lra: summary[/^\s+LRA:\s+(-?[\d.]+) LU/, 1].to_f,
      peak: summary[/^\s+Peak:\s+(-?[\d.]+) dBFS/, 1].to_f
    }
  end

  def run!(*cmd)
    out, status = Open3.capture2e(*cmd)
    raise "#{cmd.first} failed:\n#{out}" unless status.success?

    out
  end
end
