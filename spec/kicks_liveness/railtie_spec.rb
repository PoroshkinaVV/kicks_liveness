# This exercises the real Rails::Railtie from railties rather than a stub: the
# point of the spec is that our initializer really does slot into the Rails
# machinery.
require 'rails'
require 'kicks_liveness/railtie'

RSpec.describe KicksLiveness::Railtie do
  subject(:initializer) do
    described_class.initializers.find { |i| i.name == 'kicks_liveness.install' }
  end

  # An application whose config.to_prepare only records the block: there is no
  # reason to boot Rails for real over a single line.
  let(:app) do
    prepared = []
    config = Object.new
    config.define_singleton_method(:to_prepare) { |&block| prepared << block }
    app = Object.new
    app.define_singleton_method(:config) { config }
    app.define_singleton_method(:prepared) { prepared }
    app
  end

  it 'registers the initializer' do
    expect(initializer).not_to be_nil
  end

  # to_prepare rather than an initializer: an application's lib is normally
  # managed by Zeitwerk and reloadable, and such constants must not be referenced
  # while the application is initialising.
  it 'defers installing the hooks to to_prepare instead of doing it at once' do
    initializer.run(app)

    expect(app.prepared.size).to eq(1)
  end

  it 'installs the hooks once Rails reaches the prepare step' do
    allow(KicksLiveness).to receive(:install!)
    initializer.run(app)

    app.prepared.each(&:call)

    expect(KicksLiveness).to have_received(:install!)
  end
end
