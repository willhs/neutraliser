require 'spec_helper'
require_relative 'support/probe_fixture'

# The levelling ladder (--ladder): option defaults, the per-file aim, the recipe it writes and the rung
# report reads back. The rungs themselves run for real in spec/ladder_real_spec.rb.
RSpec.describe Neutraliser::Ladder do
  def measurement(input_i:, input_tp: -12.0, lra: 8.0)
    Neutraliser::Measurement.new(input_i: input_i, input_tp: input_tp, input_lra: lra, input_thresh: -32.0, target_offset: 0.0)
  end

  let(:dialogue_profile) { Neutraliser::Profiles.dialogue_profile(-27) }

  describe '.aim' do
    it 'aims every file at the profile under the programme anchor' do
      profile = Neutraliser::Profiles.default_profile
      expect(described_class.aim(profile, -30.0, Neutraliser::DialogueEstimate.centre_channel(-36.0))).to equal(profile)
    end

    it 'puts the dialogue on target: the programme goes to the target plus its loudness above dialogue' do
      aim = described_class.aim(dialogue_profile, -22.0, Neutraliser::DialogueEstimate.centre_channel(-29.5))
      expect(aim).to include(name: 'dialogue-27', lufs: -19.5, dialogue_i: -29.5)
    end

    it 'falls back to 3 LU above the dialogue target when there is no estimate' do
      aim = described_class.aim(dialogue_profile, -22.0, Neutraliser::DialogueEstimate.unavailable('stereo, no centre channel'))
      expect(aim).to include(lufs: -24.0, dialogue_i: nil)
    end

    it 'never aims the programme under the dialogue target, whatever the centre reads' do
      aim = described_class.aim(dialogue_profile, -22.0, Neutraliser::DialogueEstimate.centre_channel(-20.0))
      expect(aim[:lufs]).to eq(-27.0)
    end
  end

  describe 'dialogue profiles' do
    it 'are named for their target and rebuilt from the name a stamp carries' do
      expect(dialogue_profile).to include(name: 'dialogue-27', lufs: -24.0, anchor: :dialogue, dialogue_target: -27.0)
      expect(Neutraliser::Profiles.find('dialogue-24')).to include(dialogue_target: -24.0, lufs: -21.0)
      expect(Neutraliser::Profiles.find('custom-24')).not_to include(:anchor)
    end
  end

  describe Neutraliser::Ladder::Rung do
    def stamp(mode, source_codec: 'ac3', source_profile: nil, compression: nil)
      Neutraliser::Stamp.now(profile: 'livingroom', mode: mode, gain_db: 1.0, source_codec: source_codec, source_bitrate: nil,
                             measured_i: -22.0, measured_tp: -3.0, measured_lra: 9.0, compression: compression,
                             source_profile: source_profile)
    end

    it 'names the rung from the mode' do
      track = { codec: 'ac3' }
      expect(%w[linear limited compressed dynamic].map { |mode| described_class.of(stamp(mode), track).label })
        .to eq(%w[1-gain 2-limiter 3-compress dynamic])
      expect(described_class.of(stamp('compressed', compression: 'gentle+limiter'), track).label).to eq('3-compress')
    end

    it 'adds +convert when the codec changed or object audio was flattened' do
      expect(described_class.of(stamp('linear', source_codec: 'dts'), { codec: 'flac' }).label).to eq('1-gain+convert')
      expect(described_class.of(stamp('limited', source_codec: 'eac3', source_profile: 'Dolby Digital Plus + Dolby Atmos'),
                                { codec: 'eac3' }).label).to eq('2-limiter+convert')
    end

    it 'is nil for a file with no stamp' do
      expect(described_class.of(nil, { codec: 'ac3' })).to be_nil
    end
  end

  describe 'Processor options' do
    before { allow(Neutraliser::FFmpegWrapper).to receive(:wide_filter_options?).and_return(true) }

    def ivars(processor, *names) = names.to_h { |name| [name, processor.instance_variable_get(:"@#{name}")] }

    it 'is off by default: constant gain, recipe 2, no limiter, no compression' do
      expect(ivars(Neutraliser::Processor.new, :ladder, :recipe, :limit_db, :lra_target))
        .to eq(ladder: false, recipe: 2, limit_db: 0.0, lra_target: nil)
    end

    it 'turns on the limiter and compression rungs and writes recipe 3' do
      expect(ivars(Neutraliser::Processor.new(ladder: true), :recipe, :limit_db, :lra_target))
        .to eq(recipe: Neutraliser::Recipe::LADDER, limit_db: 6.0, lra_target: 13.0)
    end

    it 'lets the existing flags set each rung' do
      expect(ivars(Neutraliser::Processor.new(ladder: true, limit_db: 0, lra_target: 11), :limit_db, :lra_target))
        .to eq(limit_db: 0.0, lra_target: 11.0)
    end

    it 'keeps the profile name for a programme anchor, so a library already levelled is not redone by itself' do
      expect(Neutraliser::Processor.new(ladder: true).profile[:name]).to eq('livingroom')
      expect(Neutraliser::Processor.new(ladder: true, target_level: -24).profile[:name]).to eq('custom-24')
    end

    it 'aims at the dialogue with --anchor dialogue, -27 unless told otherwise' do
      expect(Neutraliser::Processor.new(ladder: true, anchor: 'dialogue').profile).to include(name: 'dialogue-27')
      expect(Neutraliser::Processor.new(ladder: true, anchor: 'dialogue', target_level: -24).profile)
        .to include(name: 'dialogue-24', dialogue_target: -24.0)
    end

    it 'may redo recipe 2, which is older than the one it writes' do
      expect { Neutraliser::Processor.new(ladder: true, redo_recipes: [2]) }.not_to raise_error
      expect { Neutraliser::Processor.new(ladder: true, redo_recipes: [3]) }.to raise_error(ArgumentError, /this run writes \(3\)/)
    end

    it 'steps aside for a run that picks loudnorm, and says so' do
      [{ allow_dynamic: true }, { profile: 'night' }, { fast: true, allow_dynamic: true }].each do |dynamic|
        processor = Neutraliser::Processor.new(ladder: true, **dynamic)
        expect(ivars(processor, :ladder, :recipe, :lra_target)).to eq(ladder: false, recipe: 2, lra_target: nil)
        expect(processor.instance_variable_get(:@notes).join).to include('levelling ladder is constant gain')
      end
    end

    it 'leaves out the compression rung under --fast-verify, and the limiter on ffmpeg before 5.1' do
      expect(ivars(Neutraliser::Processor.new(ladder: true, fast_verify: true), :lra_target, :recipe))
        .to eq(lra_target: nil, recipe: 3)
      allow(Neutraliser::FFmpegWrapper).to receive(:wide_filter_options?).and_return(false)
      processor = Neutraliser::Processor.new(ladder: true)
      expect(ivars(processor, :limit_db, :lra_target)).to eq(limit_db: 0.0, lra_target: 13.0)
      expect(processor.instance_variable_get(:@notes).join).to include('without its limiter rung')
    end

    it 'refuses a dialogue anchor without the ladder, or with a method that cannot see the dialogue' do
      [{}, { ladder: true, allow_dynamic: true }, { ladder: true, fast_verify: true }, { ladder: true, profile: 'night' }]
        .each do |options|
          expect { Neutraliser::Processor.new(anchor: 'dialogue', **options) }
            .to raise_error(ArgumentError, /--anchor dialogue is part of the levelling ladder/), "expected #{options} to be refused"
        end
      expect { Neutraliser::Processor.new(ladder: true, anchor: 'speech') }.to raise_error(ArgumentError, /Unknown anchor/)
    end

    it 'is on by default once the default recipe is the ladder: the flip is one line' do
      stub_const('Neutraliser::Recipe::CURRENT', Neutraliser::Recipe::LADDER)
      expect(ivars(Neutraliser::Processor.new, :ladder, :recipe, :limit_db, :lra_target))
        .to eq(ladder: true, recipe: 3, limit_db: 6.0, lra_target: 13.0)
      expect(ivars(Neutraliser::Processor.new(ladder: false), :ladder, :recipe)).to eq(ladder: false, recipe: 2)
    end
  end

  describe 'a dialogue-anchored file (mocked ffmpeg)' do
    let(:film) { ProbeFixture.source('/m/film.mkv', audio: [ProbeFixture.audio(codec: 'ac3', channels: 6, layout: '5.1')]) }
    let(:processor) { Neutraliser::Processor.new(ladder: true, anchor: 'dialogue', lra_target: 30) }

    before do
      allow(Neutraliser::FFmpegWrapper).to receive(:wide_filter_options?).and_return(true)
      allow(Neutraliser.logger).to receive(:log)
    end

    it 'levels the programme so the dialogue lands on target, and passes the recipe to the encode' do
      allow(processor).to receive(:analyze_loudness_for_path).and_return(measurement(input_i: -24.0))
      allow(Neutraliser::DialogueMeter).to receive(:estimate).and_return(Neutraliser::DialogueEstimate.centre_channel(-31.0))
      seen = nil
      allow(processor).to receive(:normalize_file_with_paths) do |_path, _working, _measured, aim|
        seen = aim
        { mode: Neutraliser::Mode::LINEAR }
      end

      result = processor.send(:process_file_two_pass, '/m/film.mkv', film)

      expect(result).to have_attributes(status: :done, reason: :normalized)
      expect(seen).to include(name: 'dialogue-27', lufs: -20.0, dialogue_i: -31.0)
    end

    it 'leaves a file whose dialogue is already on target, and records the target it was judged on' do
      allow(processor).to receive(:analyze_loudness_for_path).and_return(measurement(input_i: -20.4))
      allow(Neutraliser::DialogueMeter).to receive(:estimate).and_return(Neutraliser::DialogueEstimate.centre_channel(-27.0))

      result = processor.send(:process_file_two_pass, '/m/film.mkv', film)

      expect(result).to have_attributes(status: :skipped, reason: :within_tolerance)
      expect(result.left).to have_attributes(profile: 'dialogue-27', recipe: 3, target_i: -20.4)
      expect(Neutraliser::FinalLevels.computed(stamp: nil, left: result.left)).to have_attributes(target: -20.4)
    end
  end

  describe 'what the stamp records' do
    it 'writes the recipe, and for a dialogue aim the programme target and the dialogue estimate' do
      aim = dialogue_profile.merge(lufs: -19.5, dialogue_i: -29.5)
      stamp = Neutraliser::FFmpegWrapper.send(:build_stamp, aim, Neutraliser::Mode::LINEAR, { source_codec: 'ac3' },
                                              gain: 2.5, measured: measurement(input_i: -22.0), recipe: 3)
      read_back = Neutraliser::Stamp.from_tags(stamp.to_tags)
      expect(read_back).to have_attributes(recipe: 3, profile: 'dialogue-27', target_i: -19.5, dialogue_i: -29.5)
      expect(Neutraliser::FinalLevels.computed(stamp: read_back, left: nil)).to have_attributes(integrated: -19.5, target: -19.5)
    end

    it 'leaves them empty for a programme aim' do
      stamp = Neutraliser::FFmpegWrapper.send(:build_stamp, Neutraliser::Profiles.default_profile, Neutraliser::Mode::LINEAR,
                                              { source_codec: 'ac3' }, gain: 2.0, measured: measurement(input_i: -22.0))
      expect(stamp).to have_attributes(recipe: 2, target_i: nil, dialogue_i: nil)
    end
  end

  describe 'CLI' do
    it 'passes --ladder and --anchor to Processor, off and programme by default' do
      seen = []
      allow(Neutraliser::Processor).to receive(:new) do |**kwargs|
        seen << kwargs
        instance_double(Neutraliser::Processor, process: nil)
      end

      Neutraliser::CLI.start(['process', '/tmp/library'])
      Neutraliser::CLI.start(['process', '--ladder', '--anchor', 'dialogue', '--target-level', '-24', '/tmp/library'])

      expect(seen.first).to include(ladder: false, anchor: 'programme', limit_db: nil)
      expect(seen.last).to include(ladder: true, anchor: 'dialogue', target_level: -24)
    end
  end
end
