#!/usr/bin/env ruby
# Shim: real ffprobe, but a flac audio stream is reported as FAKE_CODEC (default eac3) with FAKE_LAYOUT ("none" drops it)
# and FAKE_BITRATE. Lets a lossy-7.1 source be driven through process when ffmpeg cannot build a real E-AC-3 7.1.
require 'json'
require 'open3'
real = '/opt/homebrew/bin/ffprobe'
real = `which -a ffprobe`.split("\n").reject { |p| p.include?('/tmp/l71') }.first unless File.exist?(real)
out, st = Open3.capture2(real, *ARGV)
if ARGV.include?('json') && ENV['FAKE_CODEC'] != 'off'
  j = JSON.parse(out)
  (j['streams'] || []).each do |s|
    next unless s['codec_type'] == 'audio' && s['codec_name'] == (ENV['FAKE_FROM'] || 'flac')

    s['codec_name'] = ENV['FAKE_CODEC'] || 'eac3'
    s['codec_long_name'] = 'faked'
    s['profile'] = ENV['FAKE_PROFILE'] if ENV['FAKE_PROFILE']
    if ENV['FAKE_LAYOUT'] == 'none' then s.delete('channel_layout')
    elsif ENV['FAKE_LAYOUT'] then s['channel_layout'] = ENV['FAKE_LAYOUT']
    end
    s['bit_rate'] = ENV['FAKE_BITRATE'] if ENV['FAKE_BITRATE']
  end
  out = JSON.generate(j)
end
print out
exit st.exitstatus
