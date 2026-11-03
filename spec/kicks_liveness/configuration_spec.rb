RSpec.describe KicksLiveness::Configuration do
  subject(:config) { described_class.new }

  describe 'shutdown_grace' do
    around do |example|
      previous = ENV.delete('KICKS_LIVENESS_SHUTDOWN_GRACE')
      example.run
    ensure
      ENV['KICKS_LIVENESS_SHUTDOWN_GRACE'] = previous
    end

    it 'defaults to sixty seconds' do
      expect(config.shutdown_grace).to eq(60)
    end

    it 'reads a positive integer from the environment' do
      ENV['KICKS_LIVENESS_SHUTDOWN_GRACE'] = '120'

      expect(config.shutdown_grace).to eq(120)
    end

    ['', '0', '-1', 'oops', '1.5', 'Infinity'].each do |value|
      it "silently falls back for environment value #{value.inspect}" do
        ENV['KICKS_LIVENESS_SHUTDOWN_GRACE'] = value

        expect { config.shutdown_grace }.not_to output.to_stderr
        expect(config.shutdown_grace).to eq(60)
      end
    end

    it 'lets an initializer override the environment with a fractional duration' do
      ENV['KICKS_LIVENESS_SHUTDOWN_GRACE'] = '120'
      config.shutdown_grace = 0.5

      expect(config.shutdown_grace).to eq(0.5)
    end

    [0, -1, '60', nil, Float::INFINITY, Float::NAN, Complex(1, 1)].each do |value|
      it "rejects initializer value #{value.inspect}" do
        expect { config.shutdown_grace = value }
          .to raise_error(ArgumentError, /shutdown_grace must be a positive finite number/)
      end
    end
  end
end
