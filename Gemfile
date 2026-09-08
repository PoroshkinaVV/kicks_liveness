source 'https://rubygems.org'

gemspec

# The gem declares neither `kicks` nor `sneakers` as a dependency (the reasoning
# is in the CHANGELOG), so running the suite means picking one of them here.
# CI runs a matrix over AMQP_WORKER_GEM; see CONTRIBUTING.md.
worker_gem_version = ENV.fetch('AMQP_WORKER_GEM_VERSION', nil)
worker_gem_version = nil if worker_gem_version.nil? || worker_gem_version.empty?

case ENV.fetch('AMQP_WORKER_GEM', 'kicks')
when 'kicks' then gem 'kicks', worker_gem_version || '~> 3.0'
when 'sneakers' then gem 'sneakers', worker_gem_version || '~> 2.11'
else raise "AMQP_WORKER_GEM: expected kicks or sneakers, got #{ENV['AMQP_WORKER_GEM'].inspect}"
end

group :development, :test do
  gem 'rspec', '~> 3.13'
  gem 'rubocop', require: false
  gem 'rubocop-rspec', require: false
  gem 'yard', require: false

  # Only so that the Railtie spec exercises a real Rails::Railtie rather than a
  # stub class of our own.
  gem 'railties', '>= 6.1'
end
