# frozen_string_literal: true

require 'open3'
require_relative 'lra_fixture'

# Clips for the levelling-ladder specs (spec/ladder_real_spec.rb), one per rung, made with ffmpeg's own
# generators so their levels are known and repeatable. Like LraFixture they check the arithmetic (which
# rung, what lands where, what is stamped), not how anything sounds.
#
#   narrow    stereo AAC, steady noise well under target with headroom to spare: rung 1, gain alone
#   peaky     stereo AAC, quiet noise with a loud click every half second: the clicks block the gain, rung 2
#   wide      LraFixture's 5.1 film-shaped mix, LRA about 15: rung 3
#   dts       5.1 DTS, steady noise: the codec can't be kept, rung 4 (+convert) under --allow-codec-change
#   dialogue  5.1 AC-3, steady "dialogue" noise in the centre at a known level under louder effects elsewhere
module LadderFixture
  SECONDS = 12
  RATE = 48_000

  module_function

  def build(kind, path)
    dir = File.dirname(path)
    return LraFixture.build(path, dir) if kind == :wide

    audio, codec = AUDIO.fetch(kind)
    LraFixture.run!('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                    '-f', 'lavfi', '-i', "color=c=blue:size=64x64:duration=#{SECONDS}:rate=10",
                    *audio, '-map', '0:v', '-map', '[a]', '-c:v', 'libx264', '-preset', 'ultrafast', *codec,
                    '-metadata:s:a:0', 'language=eng', path)
    path
  end

  # uniform noise of peak `amplitude` on both channels, plus (for peaky) a 3 ms 1 kHz click at 0.9
  def stereo_noise(amplitude, clicks: false)
    click = clicks ? '+0.9*lt(mod(t\,0.5)\,0.003)*sin(2*PI*1000*t)' : ''
    channel = ->(seed) { "#{amplitude}*(2*random(#{seed})-1)#{click}" }
    ['-f', 'lavfi', '-i', "aevalsrc=#{channel.call(0)}|#{channel.call(1)}:d=#{SECONDS}:s=#{RATE}",
     '-filter_complex', '[1:a]anull[a]']
  end

  def pink(amplitude, seed) = "anoisesrc=color=pink:duration=#{SECONDS}:sample_rate=#{RATE}:amplitude=#{amplitude}:seed=#{seed}"

  AUDIO = {
    narrow: [stereo_noise(0.05), ['-c:a', 'aac', '-b:a', '128k']],
    peaky: [stereo_noise(0.02, clicks: true), ['-c:a', 'aac', '-b:a', '128k']],
    dts: [['-f', 'lavfi', '-i', pink(0.08, 1), '-filter_complex', '[1:a]pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0[a]'],
          ['-c:a', 'dca', '-strict', '-2']],
    dialogue: [['-f', 'lavfi', '-i', pink(0.03, 1), '-f', 'lavfi', '-i', pink(0.06, 2), '-filter_complex',
                '[2:a]asplit=5[l][r][lfe][ls][rs];[l][r][1:a][lfe][ls][rs]join=inputs=6:channel_layout=5.1[a]'],
               ['-c:a', 'ac3', '-b:a', '448k']]
  }.freeze

  # Integrated loudness of the centre channel alone (ebur128): where the dialogue sits.
  def centre_loudness(path)
    out, = Open3.capture2e('ffmpeg', '-hide_banner', '-nostats', '-i', path, '-map', '0:a:0',
                           '-af', 'pan=mono|c0=c2,ebur128', '-f', 'null', '-')
    summary = out[/Summary:.*\z/m] or raise "no ebur128 summary for #{path}\n#{out}"
    summary[/^\s+I:\s+(-?[\d.]+) LUFS/, 1].to_f
  end
end
