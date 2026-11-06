# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'json'
require 'shellwords'

# Golden round trip: a real `process --replace` over a clip with the structure
# of a real library file, checked with real ffprobe. Most specs mock ffmpeg;
# these are what catches metadata silently dropped by build_complete_ffmpeg_command
# (docs/research/library-validation-2026-08.md). Tagged :real_ffmpeg so CI can
# select them (`rspec --tag real_ffmpeg`) and so they skip where ffmpeg is absent.
RSpec.describe 'Golden round trip over a real-structure clip', :real_ffmpeg do
  before do
    skip 'ffmpeg/ffprobe not available on PATH' unless system('which ffmpeg ffprobe > /dev/null 2>&1')
  end

  let(:chapters) do
    [
      { start: 0, end: 4000, title: 'Opening' },
      { start: 4000, end: 8000, title: 'Ünïcode — 章' }
    ]
  end

  def chapter_file(dir)
    path = File.join(dir, 'chapters.ffmeta')
    body = chapters.map do |c|
      "[CHAPTER]\nTIMEBASE=1/1000\nSTART=#{c[:start]}\nEND=#{c[:end]}\ntitle=#{c[:title]}\n"
    end
    File.write(path, ";FFMETADATA1\n#{body.join}")
    path
  end

  # Three audio tracks; the DEFAULT one is a:1 and is deliberately quiet so the
  # normaliser has to change it. a:0 and a:2 are loud and must be left alone.
  def build_fixture(path, dir, ext)
    mp4 = ext == 'mp4'
    srt = File.join(dir, 'subs.srt')
    File.write(srt, "1\n00:00:00,000 --> 00:00:01,000\nBonjour\n")
    noise = ->(amp) { ['-f', 'lavfi', '-i', "anoisesrc=color=pink:duration=8:sample_rate=48000:amplitude=#{amp}"] }
    cmd = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
           '-f', 'lavfi', '-i', 'color=c=blue:size=64x64:duration=8:rate=10',
           *noise.call(0.5), *noise.call(0.02), *noise.call(0.5),
           '-i', srt, '-i', srt, '-f', 'ffmetadata', '-i', chapter_file(dir),
           '-map', '0:v', '-map', '1:a', '-map', '2:a', '-map', '3:a', '-map', '4:s', '-map', '5:s',
           '-map_metadata', '6', '-map_chapters', '6',
           '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', '-b:a', '128k', '-ac', '2',
           '-c:s', mp4 ? 'mov_text' : 'srt',
           '-metadata:s:v:0', 'language=eng',
           '-metadata:s:a:0', 'language=eng', '-metadata:s:a:1', 'language=jpn', '-metadata:s:a:2', 'language=fre',
           '-metadata:s:s:0', 'language=fre', '-metadata:s:s:1', 'language=spa',
           '-disposition:a:0', '0', '-disposition:a:1', 'default', '-disposition:a:2', 'comment',
           '-disposition:s:0', 'forced', '-disposition:s:1', '0']
    unless mp4 # MP4 has no portable stream title tag; MKV does
      cmd += ['-metadata:s:v:0', 'title=Video Track',
              '-metadata:s:a:0', 'title=Director Cut', '-metadata:s:a:1', 'title=日本語 Main',
              '-metadata:s:a:2', 'title=Commentary', '-metadata:s:s:0', 'title=French Forced',
              '-metadata:s:s:1', 'title=Español']
    end
    system(*cmd, path, exception: true)
  end

  def probe(path)
    out, = Open3.capture2('ffprobe', '-v', 'error', '-show_entries',
                          'stream=index,codec_type:stream_tags:stream_disposition:chapter=start_time,end_time:chapter_tags=title',
                          '-of', 'json', path)
    JSON.parse(out)
  end

  def streams_of(probed, type)
    probed['streams'].select { |s| s['codec_type'] == type }
  end

  # Only the keys we assert on, lowercased (MKV and MP4 differ in key case).
  def summarise(stream, keys)
    tags = (stream['tags'] || {}).transform_keys(&:downcase)
    { tags: tags.slice(*keys), disposition: stream['disposition'].select { |_, v| v == 1 }.keys.sort }
  end

  def mean_volume(path, audio_index)
    _, err, = Open3.capture3('ffmpeg', '-hide_banner', '-i', path, '-map', "0:a:#{audio_index}",
                             '-af', 'volumedetect', '-f', 'null', '-')
    err[/mean_volume: (-?[\d.]+) dB/, 1].to_f
  end

  %w[mkv mp4].each do |ext|
    it "keeps every stream's tags, dispositions, chapters and stamps through process --replace (#{ext})" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "Café 日本語 [2024].#{ext}")
        build_fixture(path, dir, ext)
        before = probe(path)
        before_volume = (0..2).map { |i| mean_volume(path, i) }

        Neutraliser::Processor.new(replace: true, profile: 'livingroom').process(path)

        expect(Dir.children(dir)).to include(File.basename(path))
        after = probe(path)
        tag_keys = %w[language title]

        %w[video audio subtitle].each do |type|
          expected = streams_of(before, type).map { |s| summarise(s, tag_keys) }
          actual = streams_of(after, type).map { |s| summarise(s, tag_keys) }
          # The stamp may add tags on the normalised audio stream; compare only the keys we named.
          expect(actual).to eq(expected), "#{type} streams changed:\n  before #{expected}\n  after  #{actual}"
        end
        expect(streams_of(before, 'audio').map { |s| s['disposition']['default'] }).to eq([0, 1, 0])
        expect(streams_of(after, 'audio').map { |s| s['disposition']['default'] }).to eq([0, 1, 0])

        expect(after['chapters'].map { |c| c.dig('tags', 'title') })
          .to eq(before['chapters'].map { |c| c.dig('tags', 'title') })
        expect(after['chapters'].map { |c| c['start_time'].to_f.round(1) })
          .to eq(before['chapters'].map { |c| c['start_time'].to_f.round(1) })

        stamp = Neutraliser::Source.new(path).stamp
        expect(stamp).not_to be_nil, 'NEUTRALISER_* stamp missing after process'
        expect(stamp).to have_attributes(profile: 'livingroom', mode: 'linear', source_codec: 'aac',
                                         version: Neutraliser::VERSION)
        expect(stamp.measured_i).to be_a(Float)

        # The default track (a:1) is the one that was normalised; the others are untouched.
        after_volume = (0..2).map { |i| mean_volume(path, i) }
        expect(after_volume[1] - before_volume[1]).to be > 3.0
        expect((after_volume[0] - before_volume[0]).abs).to be < 1.0
        expect((after_volume[2] - before_volume[2]).abs).to be < 1.0
      end
    end
  end

  # Audio packets only, so a bit-exact stream copy gives the same hash.
  def audio_hash(path, audio_index)
    out, = Open3.capture2('ffmpeg', '-v', 'error', '-i', path, '-map', "0:a:#{audio_index}", '-c', 'copy', '-f', 'md5', '-')
    out.strip
  end

  %w[mkv mp4].each do |ext|
    it "keeps a bit-exact, non-default, titled original beside the levelled track with --keep-original-audio (#{ext})" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "keep.#{ext}")
        build_fixture(path, dir, ext)
        before = probe(path)
        before_hashes = (0..2).map { |i| audio_hash(path, i) }

        Neutraliser::Processor.new(replace: true, profile: 'livingroom', keep_original_audio: true).process(path)

        after = probe(path)
        audio = streams_of(after, 'audio')
        tags = audio.map { |s| (s['tags'] || {}).transform_keys(&:downcase) }
        # Source a:0, a:1 (levelled, then its original), a:2
        expect(audio.length).to eq(4)
        expect(audio.map { |s| s['disposition']['default'] }).to eq([0, 1, 0, 0])
        expect(tags.map { |t| t['language'] }).to eq(%w[eng jpn jpn fre])

        # The original is the exact packets of source a:1; the others are untouched.
        expect(audio_hash(path, 2)).to eq(before_hashes[1])
        expect(audio_hash(path, 0)).to eq(before_hashes[0])
        expect(audio_hash(path, 3)).to eq(before_hashes[2])
        expect(audio_hash(path, 1)).not_to eq(before_hashes[1])

        # Titles: MKV carries them; the kept one is clearly marked.
        if ext == 'mkv'
          expect(tags[1]['title']).to eq('日本語 Main')
          expect(tags[2]['title']).to eq('日本語 Main (original, not normalised)')
        else # MP4 has no stream title; the handler name carries it
          expect(tags[2]['handler_name']).to eq('(original, not normalised)')
        end
        expect(mean_volume(path, 1) - mean_volume(path, 2)).to be > 3.0
        expect(Neutraliser::Source.new(path).stamp).to have_attributes(profile: 'livingroom')
        expect(streams_of(after, 'video').length).to eq(streams_of(before, 'video').length)

        # A re-run is skipped: no second copy.
        Neutraliser::Processor.new(replace: true, profile: 'livingroom', keep_original_audio: true).process(path)
        expect(streams_of(probe(path), 'audio').length).to eq(4)
        expect(audio_hash(path, 2)).to eq(before_hashes[1])
      end
    end
  end
end
