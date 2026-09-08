require_relative 'lib/kicks_liveness/version'

Gem::Specification.new do |spec|
  spec.name = 'kicks_liveness'
  spec.version = KicksLiveness::VERSION
  spec.authors = ['PoroshkinaVV']
  spec.email = ['lera.poroshkina@mail.ru']
  spec.license = 'MIT'
  spec.summary = 'Liveness probe for Kicks and Sneakers workers. No Rails, no broker call.'
  spec.description = <<~TEXT
    A liveness probe for RabbitMQ worker pods that loads no Rails and never talks
    to the broker. The worker publishes a heartbeat to tmpfs from inside its own
    process, checking its Bunny consumers in memory; the probe only reads the
    file's mtime and runs as `bundle exec kicks-liveness`. It loads no application
    code; aside from Bundler and the interpreter it loads only the gem's small
    probe files, while the state itself comes from tmpfs. A broker hiccup cannot
    restart every replica at once.
  TEXT
  spec.homepage = 'https://github.com/PoroshkinaVV/kicks_liveness'
  spec.required_ruby_version = '>= 3.1'

  # All of docs/ is public: the working documents live in plans/, which is gitignored.
  spec.files = Dir['lib/**/*.rb', 'exe/*', 'docs/*.md', 'README.md', 'CHANGELOG.md', 'LICENSE.txt']
  spec.bindir = 'exe'
  spec.executables = ['kicks-liveness']
  spec.require_paths = ['lib']

  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'documentation_uri' => "https://rubydoc.info/gems/#{spec.name}/#{spec.version}",
    'changelog_uri' => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'bug_tracker_uri' => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }
end
