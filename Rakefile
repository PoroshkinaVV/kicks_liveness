require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'rubocop/rake_task'

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new

task default: %i[spec rubocop]

desc 'Run the complete non-integration CI gate across worker gems and documentation'
task :ci do
  Rake::Task[:rubocop].invoke
  sh Gem.ruby, '-S', 'bundle', 'exec', 'yard', 'doc', '--fail-on-warning'
  sh Gem.ruby, '-S', 'bundle', 'exec', 'appraisal', 'generate'
  sh 'git', 'diff', '--exit-code', '--', 'gemfiles'
  untracked = `git ls-files --others --exclude-standard -- gemfiles`
  abort "gemfiles/ has files Appraisals generated but git does not track:\n#{untracked}" unless untracked.empty?
  sh Gem.ruby, '-S', 'bundle', 'exec', 'appraisal', 'install'
  sh Gem.ruby, '-S', 'bundle', 'exec', 'appraisal', 'rspec'
end
