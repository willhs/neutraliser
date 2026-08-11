require_relative 'lib/neutraliser/version'

Gem::Specification.new do |spec|
  spec.name          = 'neutraliser'
  spec.version       = Neutraliser::VERSION
  spec.authors       = ['Will Hardwick-Smith']
  spec.email         = ['whardwicksmith@gmail.com']

  spec.summary       = 'Video audio volume normalisation CLI tool'
  spec.description   = 'A Ruby CLI tool that levels audio loudness across a video library ' \
                       'using FFmpeg EBU R128 loudnorm, preserving source codecs, ' \
                       'stream metadata, subtitles and chapters.'
  spec.homepage      = 'https://github.com/willhs/neutraliser'
  spec.license       = 'MIT'

  spec.metadata = {
    'homepage_uri' => spec.homepage,
    'source_code_uri' => spec.homepage,
    'bug_tracker_uri' => "#{spec.homepage}/issues",
    'changelog_uri' => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'rubygems_mfa_required' => 'true'
  }
  # Current patched releases of sqlite3 and nokogiri require Ruby 3.2.
  # Keeping Ruby 2.7 compatibility would force known-vulnerable runtime gems.
  spec.required_ruby_version = '>= 3.2.0'

  spec.files = Dir['lib/**/*', 'bin/*', 'README.md', 'CHANGELOG.md', 'LICENSE']
  spec.bindir        = 'bin'
  spec.executables   = ['neutraliser']
  spec.require_paths = ['lib']

  spec.add_dependency 'dotenv', '~> 2.8'
  spec.add_dependency 'json', '>= 2.19.9', '< 3.0'
  spec.add_dependency 'nokogiri', '>= 1.19.4', '< 2.0'
  spec.add_dependency 'plex-ruby', '~> 1.5'
  spec.add_dependency 'sqlite3', '>= 2.9.5', '< 3.0'
  spec.add_dependency 'streamio-ffmpeg', '~> 3.0'
  spec.add_dependency 'terminal-table', '~> 3.0'
  spec.add_dependency 'thor', '~> 1.2'

  spec.add_development_dependency 'pry', '~> 0.14'
  spec.add_development_dependency 'rspec', '~> 3.12'
  spec.add_development_dependency 'rubocop', '~> 1.50'
end
