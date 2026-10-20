require 'spec_helper'
require 'tmpdir'
require 'json'

RSpec.describe Neutraliser::ManifestImport do
  let(:root) { Dir.mktmpdir }
  let(:profile) { Neutraliser::Profiles::LIVING_ROOM }
  let(:manifest) { File.join(root, 'manifest.jsonl') }

  after { FileUtils.remove_entry(root) }

  def media(rel, content = 'abc')
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def entry(rel, status, path: File.join(root, rel), **extra)
    stat = File.exist?(path) ? { size: File.size(path), mtime: File.mtime(path).to_i } : {}
    { file: rel, status: status, **stat, **extra }
  end

  def write_manifest(*entries) = File.write(manifest, entries.map { |e| JSON.generate(e) }.join("\n") << "\n")

  def import(**opts) = described_class.new(manifest, root: root, profile: profile, **opts).run

  def processed?(rel)
    Neutraliser::SkipDecider.new(File.dirname(File.join(root, rel)), fast_verification: false)
                            .send(:sidecar_hit?, File.join(root, rel), profile)
  end

  it 'marks done, within-tolerance and peak-capped files processed, in the sidecar beside each file' do
    %w[tv/A/s1/a.mkv tv/A/s1/b.mkv movies/M/m.mkv].each { |rel| media(rel) }
    write_manifest(entry('tv/A/s1/a.mkv', 'done'), entry('tv/A/s1/b.mkv', 'skip_tol'), entry('movies/M/m.mkv', 'skip_tp_capped'))

    expect(import).to have_attributes(imported: 3, changed: 0)
    expect(%w[tv/A/s1/a.mkv tv/A/s1/b.mkv movies/M/m.mkv].map { |rel| processed?(rel) }).to all(be(true))
  end

  it 'lets the last entry for a file win' do
    media('m.mkv')
    write_manifest(entry('m.mkv', 'done'), entry('m.mkv', 'fail_encode'))

    expect(import).to have_attributes(imported: 0, ignored: 1)
    expect(processed?('m.mkv')).to be(false)
  end

  it 'leaves out entries the CLI should decide afresh' do
    %w[a b c d e].each { |n| media("#{n}.mkv") }
    write_manifest(*%w[skip_object_audio skip_codec fail_measure skip_diskguard rollback].zip(%w[a b c d e]).map { |s, n| entry("#{n}.mkv", s) })

    expect(import).to have_attributes(imported: 0, ignored: 5)
  end

  it 'does not trust an entry whose file changed since (replaced under the same name)' do
    path = media('m.mkv')
    write_manifest(entry('m.mkv', 'done'))
    File.write(path, 'a different, longer file')

    expect(import).to have_attributes(imported: 0, changed: 1)
    expect(processed?('m.mkv')).to be(false)
  end

  it 'counts files that are gone' do
    write_manifest({ file: 'gone.mkv', status: 'done', size: 3, mtime: 1 })

    expect(import).to have_attributes(imported: 0, missing: 1)
  end

  it 'holds back old entries without size/mtime unless told to trust them' do
    media('old.mkv')
    write_manifest({ file: 'old.mkv', status: 'done' })

    expect(import).to have_attributes(imported: 0, legacy: 1)
    expect(import(trust_legacy: true)).to have_attributes(imported: 1)
    expect(processed?('old.mkv')).to be(true)
  end

  it 'writes nothing in a dry run' do
    media('m.mkv')
    write_manifest(entry('m.mkv', 'done'))

    expect(import(dry_run: true)).to have_attributes(imported: 1)
    expect(File.exist?(File.join(root, '.neutraliser'))).to be(false)
  end

  it 'skips garbled lines' do
    media('m.mkv')
    File.write(manifest, "not json\n#{JSON.generate(entry('m.mkv', 'done'))}\n")

    expect(import).to have_attributes(imported: 1)
  end
end
