Gem::Specification.new do |spec|
  spec.name          = 'neutraliser'
  spec.version       = '0.1.0'
  spec.authors       = ['Will Hardwick-Smith']
  spec.email         = ['whardwicksmith@gmail.com']

  spec.summary       = 'Video audio volume normalisation CLI tool'
  spec.description   = 'A Ruby CLI tool for consistent audio volume normalisation across your video library'
  spec.homepage      = 'https://github.com/willhs/neutraliser'
  spec.license       = 'MIT'
  # Current patched releases of sqlite3 and nokogiri require Ruby 3.2.
  # Keeping Ruby 2.7 compatibility would force known-vulnerable runtime gems.
  spec.required_ruby_version = '>= 3.2.0'

  spec.files = Dir['lib/**/*', 'bin/*', 'README.md', 'LICENSE']
  spec.bindir        = 'bin'
  spec.executables   = ['neutraliser']
  spec.require_paths = ['lib']

  spec.add_dependency 'thor', '~> 1.2'
  spec.add_dependency 'streamio-ffmpeg', '~> 3.0'
  spec.add_dependency 'plex-ruby', '~> 1.5'
  spec.add_dependency 'sqlite3', '>= 2.9.5', '< 3.0'
  spec.add_dependency 'terminal-table', '~> 3.0'
  spec.add_dependency 'dotenv', '~> 2.8'
  spec.add_dependency 'json', '>= 2.19.9', '< 3.0'
  spec.add_dependency 'nokogiri', '>= 1.19.4', '< 2.0'

  spec.add_development_dependency 'rspec', '~> 3.12'
  spec.add_development_dependency 'rubocop', '~> 1.50'
  spec.add_development_dependency 'pry', '~> 0.14'
end
