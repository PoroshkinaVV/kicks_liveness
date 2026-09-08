require 'sneakers'
require 'kicks_liveness'

Dir[File.expand_path('support/**/*.rb', __dir__)].each { |f| require f }

RSpec.configure do |config|
  config.expect_with(:rspec) { |e| e.syntax = :expect }
  config.mock_with(:rspec) { |m| m.verify_partial_doubles = true }
  config.disable_monkey_patching!
  config.order = :random

  # The registry and the configuration are module state, and have to be reset
  # between examples. @stopping especially: leaking it would make the monitor
  # skip its health predicate and let other examples pass for the wrong reason.
  config.before do
    KicksLiveness::Registry.instance_variable_set(:@workers, [])
    KicksLiveness::Registry.instance_variable_set(:@stopping, false)
    KicksLiveness.instance_variable_set(:@config, nil)
  end
end
