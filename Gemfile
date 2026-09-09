source 'https://rubygems.org'

gemspec

# The gem declares neither `kicks` nor `sneakers` as a dependency (the reasoning
# is in docs/LIMITATIONS.md). Kicks is the fast-loop default; Appraisals owns
# the complete worker/version compatibility matrix.
gem 'kicks', '~> 3.0'

group :development, :test do
  gem 'appraisal', '~> 2.5', require: false

  # Only so that the Railtie spec exercises a real Rails::Railtie rather than a
  # stub class of our own.
  gem 'railties', '>= 6.1'
  gem 'rspec', '~> 3.13'
  gem 'rubocop', require: false
  gem 'rubocop-rspec', require: false
  gem 'yard', require: false
end
