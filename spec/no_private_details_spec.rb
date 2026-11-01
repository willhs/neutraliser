require 'spec_helper'
require 'open3'

# The repo is public. August's cleanup of private network details was undone by
# a later commit, so keep them out of every tracked file mechanically. Each pattern is assembled from fragments, so this file doesn't match itself.
PRIVATE_PATTERNS = {
  'private LAN address' => Regexp.new(['192', '168', '69', ''].join('\.')),
  'home hostname' => Regexp.new([%w[will dows].join, %w[nas \. local].join].join('|'), Regexp::IGNORECASE),
  'ssh login on the NAS' => Regexp.new(%w[\b admin @].join),
  'NAS volume path' => Regexp.new("#{['', 'vol'].join('/')}ume[0-9]/"),
  'external drive name' => Regexp.new(['', 'Volumes', 'F-'].join('/')),
  'home server name' => Regexp.new(['\b', 'bud', 'gie', '\b'].join, Regexp::IGNORECASE),
  'NAS model' => Regexp.new(%w[asus tor].join, Regexp::IGNORECASE)
}.freeze

RSpec.describe 'tracked files' do
  def tracked_files
    root = File.expand_path('..', __dir__)
    out, status = Open3.capture2('git', '-C', root, 'ls-files', '-z')
    skip 'not a git checkout' unless status.success?

    out.split("\0").map { |path| File.join(root, path) }.select { |path| File.file?(path) }
  end

  it 'name no private host, address or path' do
    hits = tracked_files.flat_map do |path|
      text = File.binread(path)
      next [] if text.include?("\0")

      text.force_encoding(Encoding::UTF_8).scrub.each_line.with_index(1).flat_map do |line, number|
        PRIVATE_PATTERNS.filter_map do |label, pattern|
          "#{path.delete_prefix("#{File.expand_path('..', __dir__)}/")}:#{number} (#{label})" if line.match?(pattern)
        end
      end
    end

    expect(hits).to be_empty
  end
end
