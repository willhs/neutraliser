Gem::Specification.new do |spec|
  spec.name          = 'neutraliser'
  spec.version       = '0.1.0'
  spec.authors       = ['Your Name']
  spec.email         = ['your.email@example.com']

  spec.summary       = 'Video audio volume normalisation CLI tool'
  spec.description   = 'A Ruby CLI tool for consistent audio volume normalisation across your video library'
  spec.homepage      = 'https://github.com/your-username/neutraliser'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 2.7.0'

  spec.files = Dir['lib/**/*', 'bin/*', 'README.md', 'LICENSE']
  spec.bindir        = 'bin'
  spec.executables   = ['neutraliser']
  spec.require_paths = ['lib']

  spec.add_dependency 'thor', '~> 1.2'
  spec.add_dependency 'streamio-ffmpeg', '~> 3.0'

  spec.add_development_dependency 'rspec', '~> 3.12'
  spec.add_development_dependency 'rubocop', '~> 1.50'
  spec.add_development_dependency 'pry', '~> 0.14'
end