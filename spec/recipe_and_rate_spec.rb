# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'digest'
require 'fileutils'

# Recipe versions, left-alone records, the remote-free rate and the sampling
# harness, end to end with real ffmpeg: generated clips, a real `process`, real
# tags and a real sidecar, then `report` and `rate-sample` over the result.
RSpec.describe 'Recipe versions, left-alone records and the remote-free rate', :real_ffmpeg do
  before do
    skip 'ffmpeg/ffprobe not available on PATH' unless system('which ffmpeg ffprobe > /dev/null 2>&1')
  end

  let(:dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(dir) }

  # A quiet sine (about -37 LUFS): lots of room to be turned up.
  let(:quiet) { '0.02*sin(2*PI*300*t)' }
  # The same quiet sine with a loud click every half second: quiet to the ear,
  # but the true peak sits near 0 dBFS, so the peak ceiling leaves no gain to give.
  let(:peaky) { "#{quiet}+if(lt(mod(t,0.5),0.0005),0.9,0)" }
  # Loud already: about -20 LUFS, inside the tolerance.
  let(:on_target) { '0.14*sin(2*PI*300*t)' }

  def make_clip(path, expr, ext: 'mkv', seconds: 6)
    FileUtils.mkdir_p(File.dirname(path))
    system('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
           '-f', 'lavfi', '-i', "color=c=blue:size=64x64:duration=#{seconds}:rate=10",
           '-f', 'lavfi', '-i', "aevalsrc='#{expr}':s=48000:d=#{seconds}",
           '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', '-b:a', '128k', '-ac', '1', "#{path}.#{ext}",
           exception: true)
    File.rename("#{path}.#{ext}", path)
  end

  def snapshot(root)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: root).sort.to_h do |relative|
      path = File.join(root, relative)
      [relative, File.file?(path) ? Digest::SHA256.file(path).hexdigest : :dir]
    end
  end

  # What a file looked like before recipes were stamped: the same tags, minus the recipe.
  def strip_recipe(path)
    stripped = "#{path}.stripped.mkv"
    system('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', path, '-map', '0', '-c', 'copy',
           '-metadata:s:a:0', 'NEUTRALISER_RECIPE=', '-metadata', 'NEUTRALISER_RECIPE=', stripped, exception: true)
    File.rename(stripped, path)
  end

  def run_quietly
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end

  def process(path, **options)
    run_quietly { Neutraliser::Processor.new(replace: true, **options).process(path) }
  end

  describe 'a stamp carries the recipe' do
    it 'writes the current recipe, and report counts it' do
      make_clip(File.join(dir, 'quiet.mkv'), quiet)
      process(dir)

      stamp = Neutraliser::FFmpegWrapper.read_stamp(File.join(dir, 'quiet.mkv'))
      expect(stamp).to have_attributes(profile: 'livingroom', recipe: Neutraliser::Recipe::CURRENT, mode: 'linear')
      expect(Neutraliser::Report.new(dir).summary).to include("Recipes: #{Neutraliser::Recipe::CURRENT}=1")
    end

    it 'keeps an unversioned file valid and identifiable, and only re-looks at it when asked to' do
      path = File.join(dir, 'quiet.mkv')
      make_clip(path, quiet)
      process(dir)
      strip_recipe(path)
      expect(Neutraliser::FFmpegWrapper.read_stamp(path)).to have_attributes(profile: 'livingroom', recipe: nil)
      before = Digest::SHA256.file(path).hexdigest
      File.delete(File.join(dir, '.neutraliser'))

      expect(Neutraliser::Report.new(dir).summary).to include('Recipes: unversioned=1')

      plain = process(dir)
      expect(plain[:results].map { |r| r[:reason] }).to eq([:already_processed])

      redo_run = process(dir, redo_recipes: [Neutraliser::Recipe::UNVERSIONED])
      # Looked at again (measured), found already at target, so not re-encoded for nothing.
      expect(redo_run[:results].map { |r| r[:reason] }).to eq([:within_tolerance])
      expect(Digest::SHA256.file(path).hexdigest).to eq(before)
    end

    it 'refuses to redo the current recipe' do
      expect { Neutraliser::Processor.new(redo_recipes: [Neutraliser::Recipe::CURRENT]) }
        .to raise_error(ArgumentError, /current one/)
    end
  end

  describe 'a file left alone is recorded' do
    it 'notes a peak-limited file with its measured levels, never as done, and report shows it' do
      peaky_path = File.join(dir, 'peaky.mkv')
      make_clip(peaky_path, peaky)
      before = Digest::SHA256.file(peaky_path).hexdigest

      first = process(dir)
      expect(first[:results].map { |r| r[:reason] }).to eq([:peak_limited])
      expect(Digest::SHA256.file(peaky_path).hexdigest).to eq(before)

      record = Neutraliser::SkipDecider.left_record_for(peaky_path)
      expect(record).to have_attributes(reason: 'peak_limited', profile: 'livingroom', recipe: Neutraliser::Recipe::CURRENT)
      expect(record.measured_i).to be_between(-45.0, -30.0)
      expect(record.measured_tp).to be > -3.0

      report = Neutraliser::Report.new(dir)
      expect(report.rows.first).to have_attributes(state: 'untouched')
      expect(report.rows.first.left).to eq(record)
      expect(report.summary).to include('left alone: peak_limited=1')
      expect(report.to_tsv).to match(/peaky\.mkv\tuntouched\t.*\tpeak_limited\tpeak ceiling allows/)

      # Not "done": the next run decides again (a flag may change the answer).
      second = process(dir)
      expect(second[:results].map { |r| r[:reason] }).to eq([:peak_limited])
    end

    it 'replaces the record once a looser recipe normalises the file' do
      make_clip(File.join(dir, 'peaky.mkv'), peaky)
      process(dir)
      looser = process(dir, allow_dynamic: true)

      expect(looser[:results].map { |r| r[:reason] }).to eq([:normalized])
      row = Neutraliser::Report.new(dir).rows.first
      expect(row.left).to be_nil
      expect(row.state).to eq('dynamic')
    end

    it 'does not record a dry run' do
      make_clip(File.join(dir, 'peaky.mkv'), peaky)
      process(dir, dry_run: true)

      expect(File.exist?(File.join(dir, '.neutraliser'))).to be false
    end

    it 'does not follow a file that changed' do
      peaky_path = File.join(dir, 'peaky.mkv')
      make_clip(peaky_path, peaky)
      process(dir)
      File.write(peaky_path, 'changed', mode: 'a')

      expect(Neutraliser::SkipDecider.left_record_for(peaky_path)).to be_nil
    end
  end

  describe 'the loudness range limit' do
    # Ten seconds loud, ten quiet: the level can be put right, the range cannot.
    it 'keeps a wide-range file out of the rate even when it is on target' do
      make_clip(File.join(dir, 'wide.mkv'), 'if(lt(t,10),0.2,0.03)*sin(2*PI*300*t)', seconds: 20)
      process(dir)

      tight = Neutraliser::Report.new(dir, measure: true)
      loose = Neutraliser::Report.new(dir, measure: true, lra_limit: 60.0)

      expect(tight.final_levels_for(tight.rows.first).lra).to be > 12.0
      expect(tight.rate.to_h).to include(remote_free: 0, wide_range: 1)
      expect(loose.rate.to_h).to include(wide_range: 0)
    end
  end

  describe 'the remote-free rate' do
    before do
      make_clip(File.join(dir, 'quiet.mkv'), quiet)
      make_clip(File.join(dir, 'peaky.mkv'), peaky)
      make_clip(File.join(dir, 'ontarget.mkv'), on_target)
      process(dir)
    end

    it 'is computed from the records: the levelled file is in, the untouched peaky one is out' do
      report = Neutraliser::Report.new(dir)
      levels = report.rows.to_h { |row| [File.basename(row.file), report.final_levels_for(row)] }

      expect(levels['quiet.mkv']).to have_attributes(basis: :computed, target: -20.0)
      expect(levels['quiet.mkv'].integrated).to be_within(0.8).of(-20.0)
      expect(levels['peaky.mkv'].integrated).to be < -30.0
      expect(levels['ontarget.mkv'].integrated).to be_within(1.0).of(-20.0)
      expect(report.rate.to_h).to include(judged: 3, remote_free: 2, not_judged: 0, off_level: 1)
      expect(report.summary).to match(/Remote-free rate: 66.7% \(2 of 3 judged files.*computed from records\)/)
    end

    it 'agrees with what the files really measure when asked to measure' do
      computed = Neutraliser::Report.new(dir)
      measured = Neutraliser::Report.new(dir, measure: true)

      expect(measured.rate.to_h).to include(judged: 3, measured: 3, remote_free: 2, off_level: 1)
      quiet = measured.rows.find { |row| File.basename(row.file) == 'quiet.mkv' }
      computed_quiet = computed.rows.find { |row| File.basename(row.file) == 'quiet.mkv' }
      expect(measured.final_levels_for(quiet).integrated)
        .to be_within(1.0).of(computed.final_levels_for(computed_quiet).integrated)
      expect(measured.summary).to include('Remote-free rate: 66.7%', 'measured')
    end

    it 'does not guess the levels of a limiter-made file, and measures them when asked' do
      skip '--limit-db needs ffmpeg 5.1+' unless Neutraliser::FFmpegWrapper.wide_filter_options?

      process(dir, limit_db: 20.0)
      computed = Neutraliser::Report.new(dir)
      measured = Neutraliser::Report.new(dir, measure: true)

      expect(computed.rate.to_h).to include(judged: 2, not_judged: 1)
      # The limiter lands it well short of -20 LUFS, which only the measurement can show.
      expect(measured.rate.to_h).to include(judged: 3, off_level: 1)
      expect(measured.rows.find { |row| row.state == 'limited' }).not_to be_nil
    end

    it 'prints through the CLI, and as JSON' do
      expect { Neutraliser::CLI.start(['report', dir]) }.to output(/Remote-free rate: 66.7%/).to_stdout
      json = JSON.parse(capture_stdout { Neutraliser::CLI.start(['report', dir, '--format', 'json', '--measure']) })
      expect(json.dig('summary', 'remote_free_rate')).to include('judged' => 3, 'remote_free' => 2)
      peaky_row = json['files'].find { |f| f['file'].end_with?('peaky.mkv') }
      expect(peaky_row).to include('left' => include('reason' => 'peak_limited'),
                                   'output' => include('basis' => 'measured', 'remote_free' => false))
    end
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  describe 'rate-sample (the harness)' do
    let(:tv) { File.join(dir, 'library', 'tv') }
    let(:movies) { File.join(dir, 'library', 'movies') }
    let(:work) { File.join(dir, 'scratch') }

    before do
      4.times { |i| make_clip(File.join(tv, "Show S01E0#{i}.mkv"), i.even? ? quiet : on_target, seconds: 4) }
      2.times { |i| make_clip(File.join(movies, "Film #{i} (2020)", "Film #{i}.mkv"), i.zero? ? peaky : quiet, seconds: 4) }
      FileUtils.mkdir_p(work)
    end

    def run_quietly_harness(harness) = run_quietly { harness.run }

    def harness(**options)
      Neutraliser::RateHarness.new(roots: [tv, movies], size: 4, seed: 7, work_dir: work, **options)
    end

    it 'samples across both roots, runs the recipe on copies and leaves the library untouched' do
      library = File.join(dir, 'library')
      before = snapshot(library)

      result = run_quietly_harness(harness)

      expect(snapshot(library)).to eq(before)
      expect(result.copies.size).to eq(4)
      expect(result.copies.values.map { |pick| File.basename(pick.root) }.tally).to eq('tv' => 2, 'movies' => 2)
      expect(result.rate.to_h).to include(judged: 4, measured: 4)
      expect(result.rate.rate).to be_between(0.0, 1.0)
      expect(result.summary).to include(found: 4)
      expect(Dir.children(work)).to be_empty
    end

    it 'shows what a recipe change does to the rate' do
      strict = run_quietly_harness(Neutraliser::RateHarness.new(roots: [movies], size: 2, seed: 1, work_dir: work))
      dynamic = run_quietly_harness(Neutraliser::RateHarness.new(roots: [movies], size: 2, seed: 1, work_dir: work,
                                                                 processor_options: { allow_dynamic: true }))

      # The strict recipe leaves the peaky film alone, so it stays off target;
      # letting loudnorm compress it brings it in.
      expect(strict.rate.rate).to eq(0.5)
      expect(dynamic.rate.rate).to eq(1.0)
    end

    it 'repeats a sample for the same seed, and varies it across seeds' do
      files = ->(seed) { Neutraliser::RateHarness.new(roots: [tv, movies], size: 3, seed: seed, work_dir: work).plan.map(&:file) }

      expect(files.call(7)).to eq(files.call(7))
      expect((1..6).map { |seed| files.call(seed) }.uniq.size).to be > 1
    end

    it 'keeps the copies on request, outside the library' do
      result = run_quietly_harness(harness(keep: true))

      expect(File.realpath(result.work_dir)).to start_with(File.realpath(work))
      expect(Dir.glob('**/*.mkv', base: result.work_dir).size).to eq(4)
    end

    it 'refuses a work folder inside the library' do
      expect { Neutraliser::RateHarness.new(roots: [tv], size: 2, work_dir: File.join(tv, 'scratch')) }
        .to raise_error(Neutraliser::RateHarness::Error, /inside/)
    end

    it 'runs through the CLI: plan copies nothing, a run reports the rate' do
      library = File.join(dir, 'library')
      before = snapshot(library)

      planned = capture_stdout do
        Neutraliser::CLI.start(['rate-sample', tv, movies, '--sample', '4', '--seed', '7', '--plan', '--work-dir', work])
      end
      expect(planned).to match(/Seed: 7.*Would copy 4 file\(s\).*Nothing copied/m)
      expect(Dir.children(work)).to be_empty

      output = capture_stdout do
        Neutraliser::CLI.start(['rate-sample', tv, movies, '--sample', '4', '--seed', '7', '--work-dir', work])
      end
      expect(output).to match(/Seed: 7 .*\n.*Remote-free rate: \d+(\.\d+)?% \(\d of 4 judged files/m)
      expect(output).to match(%r{^(tv|movies)/})
      expect(snapshot(library)).to eq(before)
    end
  end
end
