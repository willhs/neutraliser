require 'rspec'
require 'tmpdir'
require_relative '../lib/neutraliser'
require_relative 'support/probe_fixture'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = 'spec/examples.txt'
  config.disable_monkey_patching!
  config.warnings = true

  config.default_formatter = 'doc' if config.files_to_run.one?

  config.profile_examples = 10
  config.order = :random
  Kernel.srand config.seed

  # Every run asks for the ffmpeg version first. The suite has to run on a machine
  # without ffmpeg, and most examples stub the rest of it anyway. Examples that run
  # the real ffmpeg (:real_ffmpeg) see its real version, because what they exercise
  # depends on it: filter options differ between releases.
  config.before do |example|
    allow(Neutraliser::FFmpegWrapper).to receive(:version).and_return([7, 1]) unless example.metadata[:real_ffmpeg]
  end

  # Examples that make a folder unwritable with chmod (:needs_permissions) can't run as root,
  # which writes through any mode bits; CI containers often run as root.
  config.before(:example, :needs_permissions) do
    skip 'running as root, which ignores folder permissions' if Process.uid.zero?
  end
end
