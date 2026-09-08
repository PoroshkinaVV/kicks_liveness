RSpec.describe KicksLiveness::Registry do
  # Verified doubles against the real Bunny classes on purpose: if an upgrade
  # removes any_consumers? or recovering_from_network_failure?, the spec is what
  # breaks, not the probe in production.
  let(:connection) { instance_double(Bunny::Session, open?: true, recovering_from_network_failure?: false) }
  let(:channel)    { instance_double(Bunny::Channel, open?: true, any_consumers?: true, connection: connection) }
  let(:worker)     { double('worker', queue: instance_double(Sneakers::Queue, channel: channel)) } # rubocop:disable RSpec/VerifiedDoubles

  # The verified doubles above already fail if Bunny drops one of these, but
  # they fail eight times over and blame the double. Assert the contract once,
  # so an upgrade says what actually broke. recovering_from_network_failure? is
  # the fragile one: Bunny marks it @private, and losing it costs the probe its
  # "healthy while reconnecting" exemption.
  describe 'the Bunny API the predicate reads' do
    it 'is present on the bunny in use' do
      expect(Bunny::Session.instance_methods).to include(:open?, :recovering_from_network_failure?)
      expect(Bunny::Channel.instance_methods).to include(:open?, :any_consumers?, :connection)
    end
  end

  describe '.healthy?' do
    it 'is unhealthy until a worker has subscribed' do
      expect(described_class.healthy?(1)).to be(false)
    end

    it 'is healthy when the channel is open and the consumers are in place' do
      described_class.add(worker)

      expect(described_class.healthy?(1)).to be(true)
    end

    # The hole that comparing against the count closes: a worker silently
    # dropped out of the set while the rest are alive — without the comparison
    # that would go unnoticed.
    it 'is unhealthy when not the whole set subscribed' do
      described_class.add(worker)

      expect(described_class.healthy?(2)).to be(false)
    end

    it 'is unhealthy when the expected count is meaningless' do
      expect(described_class.healthy?(0)).to be(false)
    end

    it 'is unhealthy until subscribing has set queue.channel' do
      allow(worker.queue).to receive(:channel).and_return(nil)
      described_class.add(worker)

      expect(described_class.healthy?(1)).to be(false)
    end

    # The main case the probe exists to catch: the connection is alive but
    # there are no consumers — the worker silently stopped consuming.
    it 'is unhealthy when the connection is open but there are no consumers' do
      allow(channel).to receive(:any_consumers?).and_return(false)
      described_class.add(worker)

      expect(described_class.healthy?(1)).to be(false)
    end

    # The opposite case: the broker is down. Killing pods is wrong — Bunny
    # reconnects by itself, and restarting every worker at once only adds a
    # storm for the broker to deal with.
    it 'is healthy while Bunny is recovering the connection' do
      allow(channel).to receive_messages(open?: false, any_consumers?: false)
      allow(connection).to receive_messages(open?: false, recovering_from_network_failure?: true)
      described_class.add(worker)

      expect(described_class.healthy?(1)).to be(true)
    end

    it 'is unhealthy when the channel is closed outside of recovery' do
      allow(channel).to receive(:open?).and_return(false)
      described_class.add(worker)

      expect(described_class.healthy?(1)).to be(false)
    end

    it 'is unhealthy when any one of several workers is sick' do
      sick_channel = instance_double(Bunny::Channel, open?: true, any_consumers?: false, connection: connection)
      sick = double('sick worker', queue: instance_double(Sneakers::Queue, channel: sick_channel)) # rubocop:disable RSpec/VerifiedDoubles

      described_class.add(worker)
      described_class.add(sick)

      expect(described_class.healthy?(2)).to be(false)
    end

    it 'does not raise when the worker object is broken' do
      described_class.add(Object.new)

      expect(described_class.healthy?(1)).to be(false)
    end
  end

  describe '.add' do
    # A duplicate breaks the size comparison in .healthy? and would leave the
    # process permanently unhealthy.
    it 'does not register the same worker twice' do
      described_class.add(worker)
      described_class.add(worker)

      expect(described_class.size).to eq(1)
    end

    it 'keeps the predicate truthful after a duplicate' do
      described_class.add(worker)
      described_class.add(worker)

      expect(described_class.healthy?(1)).to be(true)
    end
  end

  describe '.remove' do
    it 'drops the worker from the registry' do
      described_class.add(worker)
      described_class.remove(worker)

      expect(described_class.size).to eq(0)
    end
  end
end
