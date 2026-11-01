# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'

RSpec.describe 'Dialogue figures' do
  def dialogue(programme:, level:, dialnorm: nil)
    estimate = level ? Neutraliser::DialogueEstimate.centre_channel(level) : Neutraliser::DialogueEstimate.unavailable('stereo, no centre channel')
    Neutraliser::Dialogue.new(programme: programme, estimate: estimate, dialnorm: dialnorm)
  end

  describe Neutraliser::Dialogue do
    it 'is the programme minus the dialogue, and nothing when there is no estimate' do
      expect(dialogue(programme: -22.0, level: -27.5).ldr).to eq(5.5)
      expect(dialogue(programme: -22.0, level: nil).ldr).to be_nil
      expect(dialogue(programme: -22.0, level: nil)).not_to be_judged
    end
  end

  describe Neutraliser::DialogueEstimate do
    it 'says its method, and has no speech share without a voice detector' do
      estimate = described_class.centre_channel(-27.0)

      expect(estimate).to have_attributes(method: :centre_channel, confidence: :medium, speech_share: nil, reason: nil)
      expect(estimate.method_text).to include('centre channel', 'EBU R 128')
    end

    it 'gives a reason instead of a level when it cannot estimate' do
      expect(described_class.unavailable('mono, no centre channel')).to have_attributes(level: nil, method: nil, available?: false)
    end
  end

  describe Neutraliser::DialogueRate do
    let(:files) do
      {
        'on.mkv' => dialogue(programme: -23.0, level: -27.0),       # on the anchor, 4 LU above
        'loud.mkv' => dialogue(programme: -17.0, level: -27.5),     # dialogue on target, programme 10.5 above
        'quiet.mkv' => dialogue(programme: -30.0, level: -33.0),    # 6 LU off the dialogue target
        'stereo.mkv' => dialogue(programme: -20.0, level: nil),
        'broken.mkv' => nil
      }
    end

    subject(:rate) { described_class.new(files) }

    it 'needs dialogue within the tolerance of the target and the programme within the limit above it' do
      expect(rate.to_h).to include(rate: 0.3333, remote_free: 1, judged: 3, not_judged: 2, off_level: 1, over_ldr: 1,
                                   dialogue_target: -27.0, ldr_limit: 5.0, methods: { 'centre_channel' => 3 })
      expect(rate.remote_free?(files['on.mkv'])).to be(true)
      expect(rate.remote_free?(files['loud.mkv'])).to be(false)
      expect(rate.remote_free?(files['stereo.mkv'])).to be(false)
      expect(rate.verdict(files['on.mkv'])).to be(true)
      expect(rate.verdict(files['stereo.mkv'])).to be_nil
      expect(rate.verdict(files['broken.mkv'])).to be_nil
    end

    it 'moves with the anchor and the tolerance it is given' do
      anchor = Neutraliser::DialogueAnchor.new(target: -33.0, ldr_limit: 12.0)

      expect(described_class.new(files, anchor: anchor, within_lu: 1.0).remote_free).to eq(1)
      expect(described_class.new(files, anchor: anchor, within_lu: 1.0).to_h).to include(dialogue_target: -33.0, within_lu: 1.0)
    end

    it 'says what it rests on: method, loudness above dialogue, and why files were not judged' do
      text = rate.summary_lines.join("\n")

      expect(text).to include('Dialogue-anchored remote-free rate: 33.3% (1 of 3 judged files', 'within 2.0 LU of -27.0 LUFS',
                              'at most 5.0 LU above it', 'method: centre channel through the EBU R 128 gate',
                              '2 not judged: stereo, no centre channel (1), could not be measured (1)',
                              'Loudness above dialogue: median 4.0 LU, 1 of 3 over 5.0 LU')
    end

    it 'lists the dialnorms the files carry' do
      files['on.mkv'] = dialogue(programme: -23.0, level: -27.0, dialnorm: -27)
      files['loud.mkv'] = dialogue(programme: -17.0, level: -27.5, dialnorm: -27)

      expect(rate.summary_lines).to include('Dialnorm in the files (dB): -27=2')
    end

    it 'has no rate when nothing could be estimated, and no lines when nothing was read' do
      none = described_class.new({ 'a.mkv' => dialogue(programme: -20.0, level: nil) })

      expect(none.rate).to be_nil
      expect(none.summary_lines.first).to include('n/a (no file\'s dialogue could be estimated; 1 not judged: stereo')
      expect(described_class.new({}).summary_lines).to be_empty
    end
  end

  describe Neutraliser::DialogueMeter do
    let(:surround) { { index: 1, channels: 6, channel_layout: '5.1(side)', codec: 'ac3' } }
    let(:measurement) do
      Neutraliser::Measurement.new(input_i: -28.1, input_tp: -3.0, input_lra: 4.0, input_thresh: -38.0, target_offset: 0.0)
    end

    it 'measures the centre channel of the track by itself, and says so' do
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_return(measurement)

      estimate = described_class.estimate('f.mkv', surround)

      expect(estimate).to have_attributes(level: -28.1, method: :centre_channel, confidence: :medium)
      expect(Neutraliser::FFmpegWrapper).to have_received(:measure_loudness)
        .with('f.mkv', audio_index: 1, pre_filter: 'pan=mono|c0=c2')
    end

    it 'reads a surround track whose layout has no name' do
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_return(measurement)

      expect(described_class.estimate('f.mkv', surround.merge(channel_layout: nil))).to be_available
    end

    {
      'mono' => [{ channels: 1, channel_layout: 'mono' }, 'mono, no centre channel'],
      'stereo' => [{ channels: 2, channel_layout: 'stereo' }, 'stereo, no centre channel'],
      'quad' => [{ channels: 4, channel_layout: 'quad' }, 'no centre channel in quad'],
      '2.1' => [{ channels: 3, channel_layout: '2.1' }, 'no centre channel in 2.1'],
      '6.0(front)' => [{ channels: 6, channel_layout: '6.0(front)' }, 'no centre channel in 6.0(front)'],
      '6.1(front)' => [{ channels: 7, channel_layout: '6.1(front)' }, 'no centre channel in 6.1(front)']
    }.each do |name, (track, reason)|
      it "gives no figure for #{name}, and does not read the file" do
        allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness)

        expect(described_class.estimate('f.mkv', { index: 0, codec: 'aac' }.merge(track)))
          .to have_attributes(level: nil, reason: reason)
        expect(Neutraliser::FFmpegWrapper).not_to have_received(:measure_loudness)
      end
    end

    it 'says so when the centre channel is silent' do
      silent = Neutraliser::Measurement.new(input_i: 0.0, input_tp: -70.0, input_lra: 0.0, input_thresh: -70.0,
                                            target_offset: 0.0, silent: true)
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_return(silent)

      expect(described_class.estimate('f.mkv', surround)).to have_attributes(level: nil, reason: 'silent centre channel')
    end

    describe '.dialnorm' do
      let(:stamp) do
        Neutraliser::Stamp.now(profile: 'livingroom', mode: 'linear', gain_db: 1.0, source_codec: 'ac3', source_bitrate: nil,
                               measured_i: -24.0, measured_tp: -3.0, measured_lra: 6.0, source_dialnorm: -27)
      end

      before { allow(Neutraliser::FFmpegWrapper).to receive(:read_dialnorm).and_return(-24) }

      it 'takes a stamped file\'s from the stamp, including having none' do
        expect(described_class.dialnorm('f.mkv', surround, stamp)).to eq(-27)
        expect(described_class.dialnorm('f.mkv', surround, stamp.with(source_dialnorm: nil))).to be_nil
        expect(Neutraliser::FFmpegWrapper).not_to have_received(:read_dialnorm)
      end

      it 'reads it from an unstamped Dolby track, and has none for any other codec' do
        expect(described_class.dialnorm('f.mkv', surround, nil)).to eq(-24)
        expect(described_class.dialnorm('f.mkv', surround.merge(codec: 'aac'), nil)).to be_nil
      end

      it 'has none when the frames cannot be read' do
        allow(Neutraliser::FFmpegWrapper).to receive(:read_dialnorm).and_raise(Neutraliser::FFmpegError, 'no dialnorm')

        expect(described_class.dialnorm('f.mkv', surround, nil)).to be_nil
      end
    end
  end

  describe Neutraliser::Report do
    let(:dir) { Dir.mktmpdir }
    let(:files) do
      { 'film.mkv' => { audio: [ProbeFixture.audio(codec: 'ac3', channels: 6, layout: '5.1')] },
        'show.mkv' => { audio: [ProbeFixture.audio(codec: 'aac', channels: 2, layout: 'stereo')] } }
    end

    before do
      files.each_key { |name| File.write(File.join(dir, name), 'x') }
      stub_probes(files)
      allow(Neutraliser::FFmpegWrapper).to receive(:read_dialnorm).and_return(-27)
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness) do |_path, pre_filter: nil, **|
        level = pre_filter ? -27.0 : -21.0
        Neutraliser::Measurement.new(input_i: level, input_tp: -3.0, input_lra: 8.0, input_thresh: -40.0, target_offset: 0.0)
      end
    end

    after { FileUtils.remove_entry(dir) }

    def film(report) = report.rows.find { |row| row.file.end_with?('film.mkv') }
    def show(report) = report.rows.find { |row| row.file.end_with?('show.mkv') }

    it 'adds dialogue figures and a second rate under --measure, beside the first' do
      report = described_class.new(dir, measure: true)

      expect(report.rate.to_h).to include(judged: 2)
      expect(report.dialogue_rate.to_h).to include(judged: 1, not_judged: 1, remote_free: 0, over_ldr: 1)
      expect(report.dialogue_for(film(report))).to have_attributes(programme: -21.0, dialnorm: -27, ldr: 6.0)
      expect(report.dialogue_for(show(report)).estimate.reason).to eq('stereo, no centre channel')
      expect(report.summary).to include('Remote-free rate:', 'Dialogue-anchored remote-free rate:', 'Dialnorm in the files (dB): -27=1')
    end

    it 'says which method and confidence produced each file\'s figure' do
      report = described_class.new(dir, measure: true)

      expect(report.dialogue_text(film(report))).to eq('dialogue -27.0 LUFS (centre channel, medium confidence), programme 6.0 LU above it, dialnorm -27')
      expect(report.dialogue_text(show(report))).to eq('dialogue: n/a (stereo, no centre channel)')
      expect(report.dialogue_verdict_text(film(report))).to eq('off the dialogue anchor')
      expect(report.dialogue_verdict_text(show(report))).to eq('dialogue not judged')
    end

    it 'flags the encoder\'s default dialnorm as likely unset' do
      allow(Neutraliser::FFmpegWrapper).to receive(:read_dialnorm).and_return(-31)

      report = described_class.new(dir, measure: true)

      expect(report.dialogue_text(film(report))).to include('dialnorm -31 (the encoder default, likely unset)')
    end

    it 'puts the figures in the JSON and TSV' do
      report = described_class.new(dir, measure: true)
      json = JSON.parse(report.to_json)
      film_json = json['files'].find { |file| file['file'].end_with?('film.mkv') }

      expect(json.dig('summary', 'dialogue_remote_free_rate')).to include('judged' => 1, 'methods' => { 'centre_channel' => 1 })
      expect(film_json['dialogue']).to include('dialogue_i' => -27.0, 'method' => 'centre_channel', 'confidence' => 'medium',
                                               'loudness_above_dialogue' => 6.0, 'dialnorm' => -27, 'remote_free' => false)
      rows = report.to_tsv.lines.map { |line| line.chomp.split("\t", -1) }
      header = rows.first
      film_row = rows.find { |row| row.first.end_with?('film.mkv') }
      expect(film_row[header.index('dialogue_method')]).to eq('centre_channel')
      expect(film_row[header.index('ldr')]).to eq('6.0')
      expect(rows.map(&:size).uniq).to eq([header.size])
    end

    it 'reads nothing for dialogue without --measure, or with the anchor switched off' do
      computed = described_class.new(dir)
      off = described_class.new(dir, measure: true, dialogue_anchor: nil)

      expect(computed.dialogue_rate).to be_nil
      expect(off.dialogue_rate).to be_nil
      expect(off.summary).not_to include('Dialogue')
      expect(JSON.parse(off.to_json)['files'].first).not_to have_key('dialogue')
      expect(Neutraliser::FFmpegWrapper).to have_received(:measure_loudness).exactly(2).times # the two programme reads only
    end

    it 'counts a file it cannot measure as not judged on both rates' do
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_raise(Neutraliser::FFmpegError, 'boom')

      report = described_class.new(dir, measure: true)

      expect(report.rate.to_h).to include(judged: 0, not_judged: 2)
      expect(report.dialogue_rate.to_h).to include(judged: 0, not_judged: 2)
      expect(report.dialogue_text(film(report))).to eq('dialogue: not measured')
    end

    it 'keeps the programme figure when only the dialogue read fails' do
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness) do |_path, pre_filter: nil, **|
        raise Neutraliser::FFmpegError, 'boom' if pre_filter

        Neutraliser::Measurement.new(input_i: -21.0, input_tp: -3.0, input_lra: 8.0, input_thresh: -40.0, target_offset: 0.0)
      end

      report = described_class.new(dir, measure: true)

      expect(report.rate.to_h).to include(judged: 2)
      expect(report.dialogue_rate.to_h).to include(judged: 0, not_judged: 2)
    end
  end
end
