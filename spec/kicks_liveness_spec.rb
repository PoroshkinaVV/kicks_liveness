require 'open3'

RSpec.describe KicksLiveness do
  let(:lib) { File.expand_path('../lib', __dir__) }

  describe '.configure' do
    it 'yields the configuration and keeps the changes' do
      described_class.configure { |c| c.tick = 3 }

      expect(described_class.config.tick).to eq(3)
    end

    it 'does not let the application configure the directory or the threshold' do
      expect(described_class.config).not_to respond_to(:dir=)
      expect(described_class.config).not_to respond_to(:max_age=)
    end

    # A tick is what the monitor thread sleeps on, so a non-positive value is
    # not a setting but a broken monitor. The environment gets a silent
    # fallback because a ConfigMap typo must not bring a worker down; an
    # initializer is code, and should say so at boot.
    [0, -1, 'ten', nil].each do |value|
      it "refuses a tick of #{value.inspect}" do
        expect { described_class.configure { |c| c.tick = value } }
          .to raise_error(ArgumentError, /tick must be a positive number/)
      end
    end

    it 'refuses a tick that cannot keep the mark younger than max_age' do
      expect { described_class.configure { |c| c.tick = 45 } }
        .to raise_error(ArgumentError, /tick must be less than max_age \(45s\)/)
    end

    it 'falls back with a warning for incompatible timing from the environment' do
      ENV['KICKS_LIVENESS_TICK'] = '60'
      configured = nil

      expect do
        configured = described_class.config
        configured.tick
      end
        .to output(/effective tick=60s \(KICKS_LIVENESS_TICK=60\).*using 10s/).to_stderr
      expect(configured.tick).to eq(10)
    ensure
      ENV.delete('KICKS_LIVENESS_TICK')
    end

    it 'derives a safe fallback when the default tick is not below max_age' do
      ENV['KICKS_LIVENESS_MAX_AGE'] = '5'
      configured = nil

      expect do
        configured = described_class.config
        configured.tick
      end
        .to output(/effective tick=10s \(default\).*KICKS_LIVENESS_MAX_AGE=5s.*using 2.5s/).to_stderr
      expect(configured.tick).to eq(2.5)
    ensure
      ENV.delete('KICKS_LIVENESS_MAX_AGE')
    end

    it 'identifies an invalid environment tick when the fallback is still incompatible' do
      ENV['KICKS_LIVENESS_TICK'] = 'oops'
      ENV['KICKS_LIVENESS_MAX_AGE'] = '5'

      expect { described_class.config.tick }
        .to output(/default after invalid KICKS_LIVENESS_TICK="oops".*using 2.5s/).to_stderr
    ensure
      ENV.delete('KICKS_LIVENESS_TICK')
      ENV.delete('KICKS_LIVENESS_MAX_AGE')
    end

    [0, -1, 1.5, '3', nil].each do |value|
      it "refuses startup_grace_ticks of #{value.inspect}" do
        expect { described_class.configure { |c| c.startup_grace_ticks = value } }
          .to raise_error(ArgumentError, /startup_grace_ticks must be a positive integer/)
      end
    end

    it 'accepts a positive integer startup grace' do
      described_class.configure { |c| c.startup_grace_ticks = 3 }

      expect(described_class.config.startup_grace_ticks).to eq(3)
    end

    it 'does not warn about an environment tick replaced by the initializer' do
      ENV['KICKS_LIVENESS_TICK'] = '60'

      expect { described_class.configure { |c| c.tick = 5 } }.not_to output.to_stderr
      expect(described_class.config.tick).to eq(5)
    ensure
      ENV.delete('KICKS_LIVENESS_TICK')
    end

    it 'does not warn about an unused environment tick when the monitor is disabled' do
      ENV['KICKS_LIVENESS_MAX_AGE'] = '5'

      expect do
        described_class.configure { |c| c.enabled = false }
        described_class.start!(slot: 0, processes: 1, consumers: 1)
      end.not_to output.to_stderr
    ensure
      ENV.delete('KICKS_LIVENESS_MAX_AGE')
    end
  end

  describe '.start!' do
    it 'starts nothing when disabled' do
      described_class.configure { |c| c.enabled = false }

      expect(described_class.start!(slot: 0, processes: 1, consumers: 1)).to be_nil
    end
  end

  describe '.install!' do
    it 'is idempotent' do
      described_class.install!
      before = Sneakers::Worker.ancestors.count { |m| m == KicksLiveness::Hooks::Worker }
      described_class.install!

      expect(Sneakers::Worker.ancestors.count { |m| m == KicksLiveness::Hooks::Worker }).to eq(before)
    end

    it 'loads both namespaces it needs by itself' do
      out, status = Open3.capture2e(
        RbConfig.ruby, '-I', lib, '-e',
        "require 'kicks_liveness'; KicksLiveness.install!; " \
        'print Sneakers::Worker.ancestors.include?(KicksLiveness::Hooks::Worker)'
      )

      expect([out, status.exitstatus]).to eq(['true', 0])
    end

    it 'refuses to choose between kicks and sneakers when both are activated' do
      loaded_specs = Gem.loaded_specs.merge('kicks' => Object.new, 'sneakers' => Object.new)
      allow(Gem).to receive(:loaded_specs).and_return(loaded_specs)

      expect { described_class.install! }
        .to raise_error(LoadError, /both kicks and sneakers activated; install exactly one/)
    end

    # The gem has to work outside Rails: Sinatra, Hanami, a runner of one's
    # own. In a separate process, because within the suite Rails is already
    # loaded by the Railtie spec.
    it 'installs the hooks without Rails and pulls in none of its code' do
      script = <<~RUBY
        raise 'Rails leaked' if defined?(Rails)
        require 'kicks_liveness'
        KicksLiveness.install!
        print [
          $LOADED_FEATURES.none? { |f| f.include?('kicks_liveness/railtie') },
          Sneakers::Worker.ancestors.include?(KicksLiveness::Hooks::Worker),
          Sneakers::WorkerGroup.ancestors.include?(KicksLiveness::Hooks::WorkerGroup),
          $LOADED_FEATURES.grep(%r{/(rails|railties|actionpack)[-/]}).empty?
        ].inspect
      RUBY

      out, status = Open3.capture2e(RbConfig.ruby, '-I', lib, '-e', script)

      expect([out, status.exitstatus]).to eq(['[true, true, true, true]', 0])
    end

    it 'names both gems when neither is installed' do
      out, status = Open3.capture2e(
        { 'RUBYOPT' => '--disable-gems' },
        RbConfig.ruby, '-I', lib, '-e', "require 'kicks_liveness'; KicksLiveness.install!"
      )

      expect(status.exitstatus).to eq(1)
      expect(out).to include('requires the kicks (>= 3.0) or sneakers (>= 2.11) gem')
    end

    # The same rescue fires when the worker gem is installed but something
    # inside it fails to load. Reporting that as "the gem is missing" sends the
    # reader off to check a Gemfile.lock that is perfectly fine, so the
    # original message has to survive.
    it 'keeps the underlying load error in the message' do
      out, status = Open3.capture2e(
        { 'RUBYOPT' => '--disable-gems' },
        RbConfig.ruby, '-I', lib, '-e', "require 'kicks_liveness'; KicksLiveness.install!"
      )

      expect(status.exitstatus).to eq(1)
      expect(out).to include('cannot load such file')
    end
  end
end
