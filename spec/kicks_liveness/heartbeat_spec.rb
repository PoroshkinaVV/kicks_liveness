require 'tmpdir'

RSpec.describe KicksLiveness::Heartbeat do
  subject(:heartbeat) { described_class.new(dir: dir, max_age: 45) }

  let(:tmp) { Dir.mktmpdir }
  let(:dir) { File.join(tmp, 'health') }

  after { FileUtils.remove_entry(tmp) }

  describe '#check' do
    it 'fails until the worker has declared its slot count' do
      ok, message = heartbeat.check

      expect(ok).to be(false)
      expect(message).to include('worker has not started yet')
    end

    it 'fails until every slot has marked itself' do
      heartbeat.declare!(2)
      heartbeat.touch!(0)

      expect(heartbeat.check).to eq([false, 'worker-1 missing'])
    end

    it 'passes when every slot is fresh' do
      heartbeat.declare!(2)
      heartbeat.touch!(0)
      heartbeat.touch!(1)

      expect(heartbeat.check).to eq([true, '2 process(es) healthy'])
    end

    it 'fails when a mark has gone stale' do
      heartbeat.declare!(1)
      heartbeat.touch!(0)

      ok, message = heartbeat.check(now: Time.now.utc + 60)

      expect(ok).to be(false)
      expect(message).to include('worker-0 stale')
    end

    # Forks are numbered by supervisor slot, so shrinking `workers` would leave
    # the files above the new count lying around forever.
    it 'ignores slots beyond the declared count' do
      heartbeat.declare!(1)
      heartbeat.touch!(0)
      heartbeat.touch!(7)

      expect(heartbeat.check).to eq([true, '1 process(es) healthy'])
    end
  end

  describe '#touch!' do
    it 'writes the time and the pid into the file, for kubectl exec' do
      heartbeat.declare!(1)
      heartbeat.touch!(0)

      expect(File.read(File.join(dir, 'worker-0'))).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ pid=\d+ slot=0\n\z/)
    end
  end

  describe 'self-repair' do
    it 'recreates the directory if it was removed' do
      heartbeat.declare!(1)
      FileUtils.remove_entry(dir)

      heartbeat.touch!(0)

      expect(File).to exist(File.join(dir, 'worker-0'))
    end

    # touch! alone is not enough: it brings back the slot marks while `expected`
    # stays missing, and the probe then reports "worker has not started" for the
    # rest of the pod's life. Restoring it is the monitor's job, on every tick.
    it 'still fails the check until expected is declared again' do
      heartbeat.declare!(1)
      FileUtils.remove_entry(dir)
      heartbeat.touch!(0)

      expect(heartbeat.check).to eq([false, "no #{File.join(dir, 'expected')}: worker has not started yet"])
    end

    it 'passes once expected is declared again' do
      heartbeat.declare!(1)
      FileUtils.remove_entry(dir)

      heartbeat.declare!(1)
      heartbeat.touch!(0)

      expect(heartbeat.check).to eq([true, '1 process(es) healthy'])
    end
  end

  # Dir.mkdir creates a single level and raises ENOENT when the parent is
  # missing, which any nested KICKS_LIVENESS_DIR hits.
  describe 'a nested marks directory' do
    subject(:nested) { described_class.new(dir: File.join(tmp, 'a', 'b', 'health'), max_age: 45) }

    it 'creates the whole chain of directories' do
      nested.declare!(1)
      nested.touch!(0)

      expect(nested.check).to eq([true, '1 process(es) healthy'])
    end
  end

  describe 'defaults' do
    # Exactly the trap I walked into: env_int is a class method, while default
    # argument values are evaluated in the context of the instance.
    it 'can be built with no arguments' do
      instance = described_class.new

      expect(instance.dir).to eq(described_class::DEFAULT_DIR)
      expect(instance.max_age).to eq(described_class::DEFAULT_MAX_AGE)
    end

    it 'takes the directory and the threshold from the environment' do
      ENV['KICKS_LIVENESS_DIR'] = '/custom/health'
      ENV['KICKS_LIVENESS_MAX_AGE'] = '90'

      instance = described_class.new

      expect(instance.dir).to eq('/custom/health')
      expect(instance.max_age).to eq(90)
    ensure
      ENV.delete('KICKS_LIVENESS_DIR')
      ENV.delete('KICKS_LIVENESS_MAX_AGE')
    end

    # The value comes from a ConfigMap, and a typo there is no reason to bring a
    # worker down.
    it 'falls back to the default when the value is not a number' do
      ENV['KICKS_LIVENESS_MAX_AGE'] = 'abc'

      expect(described_class.new.max_age).to eq(described_class::DEFAULT_MAX_AGE)
    ensure
      ENV.delete('KICKS_LIVENESS_MAX_AGE')
    end

    # In a ConfigMap a key that is declared but left blank yields an empty
    # string. That means "unset", not "a directory with an empty name".
    it 'treats an empty value as unset' do
      ENV['KICKS_LIVENESS_DIR'] = ''

      expect(described_class.new.dir).to eq(described_class::DEFAULT_DIR)
    ensure
      ENV.delete('KICKS_LIVENESS_DIR')
    end

    # Both settings are durations. Zero and negative values parse perfectly
    # well, which makes them the more dangerous half of a ConfigMap typo: a
    # negative max_age makes every mark stale on arrival, so the probe can
    # never pass again.
    ['0', '-1'].each do |value|
      it "falls back to the default when max_age is #{value}" do
        ENV['KICKS_LIVENESS_MAX_AGE'] = value

        expect(described_class.new.max_age).to eq(described_class::DEFAULT_MAX_AGE)
      ensure
        ENV.delete('KICKS_LIVENESS_MAX_AGE')
      end

      it "falls back to the default when tick is #{value}" do
        ENV['KICKS_LIVENESS_TICK'] = value

        expect(described_class.env_int(:tick, 10)).to eq(10)
      ensure
        ENV.delete('KICKS_LIVENESS_TICK')
      end
    end
  end

  describe '#declare!' do
    # A plain File.write truncates first, and a probe reading in that window
    # finds the file empty and reports that the worker has not started. Every
    # fork writes this file at startup, and a fork respawned after SIGKILL
    # writes it again while the liveness probe is already running.
    it 'leaves no temporary file behind, having written through a rename' do
      heartbeat.declare!(2)

      expect(Dir.children(dir)).to eq(['expected'])
      expect(File.read(File.join(dir, 'expected'))).to eq('2')
    end

    it 'overwrites a previous declaration' do
      heartbeat.declare!(4)
      heartbeat.declare!(2)

      expect(File.read(File.join(dir, 'expected'))).to eq('2')
      expect(Dir.children(dir)).to eq(['expected'])
    end
  end
end
