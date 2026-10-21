require 'tmpdir'

RSpec.describe KicksLiveness::Heartbeat do
  subject(:heartbeat) { described_class.new(dir: dir, max_age: 45, topology: non_linux_topology) }

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

  describe 'container generations' do
    let(:old) { described_class.new(dir: dir, max_age: 45, topology: verified_topology('mnt:[1]:100')) }
    let(:current) { described_class.new(dir: dir, max_age: 45, topology: verified_topology('mnt:[2]:200')) }

    before do
      old.declare!(1)
      old.touch!(0)
    end

    it 'rejects a complete, fresh heartbeat inherited from a previous container' do
      expect(current.check).to eq(
        [false, 'heartbeat belongs to a previous container: worker has not started yet']
      )
    end

    it 'rejects fresh generation-less heartbeat files inherited from 0.1.1' do
      File.delete(File.join(dir, 'generation'))
      File.write(File.join(dir, 'worker-0'), "2026-09-11T00:00:00Z pid=1 slot=0\n")

      expect(current.check).to eq(
        [false, 'heartbeat belongs to a previous container: worker has not started yet']
      )

      current.declare!(1)

      expect(current.check).to eq([false, 'worker-0 belongs to a previous container'])
    end

    it 'rejects the previous slot after the current container declares its count' do
      current.declare!(1)

      expect(current.check).to eq([false, 'worker-0 belongs to a previous container'])
    end

    it 'passes once the current container writes its own slot mark' do
      current.declare!(1)
      current.touch!(0)

      expect(current.check).to eq([true, '1 process(es) healthy'])
    end

    it 'writes slot marks atomically with their generation' do
      current.declare!(1)
      current.touch!(0)

      expect(File.read(File.join(dir, 'worker-0'))).to include('generation=mnt:[2]:200')
      expect(Dir.children(dir).sort).to eq(%w[expected generation worker-0])
    end

    it 'leaves a warm application cache elsewhere in the emptyDir untouched' do
      cache = File.join(tmp, 'bootsnap-cache')
      File.write(cache, 'compiled')

      current.declare!(1)
      current.touch!(0)

      expect(File.read(cache)).to eq('compiled')
    end
  end

  # shareProcessNamespace: true and hostPID: true both leave PID 1 alive across a
  # restart of the worker container, so the 0.1.2 identifier repeats and an
  # inherited heartbeat can satisfy a one-shot startupProbe. Neither setting can
  # be changed on a live pod, so this state is terminal for the volume.
  describe 'a proven unsupported PID topology' do
    subject(:unsafe) { described_class.new(dir: dir, max_age: 45, topology: unsafe_topology) }

    let(:previous_container) { described_class.new(dir: dir, max_age: 45, topology: verified_topology('mnt:[1]:100')) }

    it 'rejects ahead of a complete, fresh, inherited heartbeat' do
      previous_container.declare!(1)
      previous_container.touch!(0)

      expect(unsafe.check).to eq([false, described_class::UNSUPPORTED_TOPOLOGY])
    end

    it 'publishes the fail-closed state instead of any generation, mark or count' do
      unsafe.declare!(1)
      unsafe.touch!(0)

      expect(Dir.children(dir)).to eq(['topology-unsafe'])
    end

    it 'writes the reason where a human reading the volume will find it' do
      unsafe.declare!(1)

      expect(File.read(File.join(dir, 'topology-unsafe'))).to eq(
        "#{described_class::UNSUPPORTED_TOPOLOGY}\nPID 1 is in mnt:[4026531840], this process in mnt:[4026532686]\n"
      )
    end
  end

  # Procfs access is local to a process and the worker's credentials need not
  # match the probe's, so the two can prove different things about the same pod.
  # Proof of an unsafe topology from either side dominates every weaker result.
  describe 'when the worker and the probe prove different things' do
    def heartbeat_with(topology) = described_class.new(dir: dir, max_age: 45, topology: topology)

    it 'rejects when only the worker could prove the topology unsafe' do
      heartbeat_with(unsafe_topology).reject_topology!

      expect(heartbeat_with(unverifiable_topology).check).to eq([false, described_class::UNSUPPORTED_TOPOLOGY])
    end

    it 'rejects when only the probe could prove the topology unsafe' do
      worker = heartbeat_with(unverifiable_topology)
      worker.declare!(1)
      worker.touch!(0)

      expect(heartbeat_with(unsafe_topology).check).to eq([false, described_class::UNSUPPORTED_TOPOLOGY])
    end

    it 'rejects published unsafe state even with no generation of its own' do
      heartbeat_with(unsafe_topology).reject_topology!

      [unavailable_topology, non_linux_topology].each do |topology|
        expect(heartbeat_with(topology).check).to eq([false, described_class::UNSUPPORTED_TOPOLOGY])
      end
    end

    # A fork that could not prove the topology is not evidence that it is safe,
    # and normal marks published afterwards are not evidence either.
    it 'is not cleared by a weaker result, whatever it publishes afterwards' do
      heartbeat_with(unsafe_topology).reject_topology!

      later = heartbeat_with(verified_topology('mnt:[2]:200'))
      later.declare!(1)
      later.touch!(0)

      expect(later.check).to eq([false, described_class::UNSUPPORTED_TOPOLOGY])
      expect(File).to exist(File.join(dir, 'topology-unsafe'))
    end
  end

  describe '#touch!' do
    it 'writes the time and the pid into the file, for kubectl exec' do
      heartbeat.declare!(1)
      heartbeat.touch!(0)

      expect(File.read(File.join(dir, 'worker-0'))).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ pid=\d+ slot=0\n\z/)
    end

    it 'returns the number of bytes written' do
      heartbeat.declare!(1)

      bytes = heartbeat.touch!(0)

      expect(bytes).to eq(File.size(File.join(dir, 'worker-0')))
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
    subject(:nested) do
      described_class.new(dir: File.join(tmp, 'a', 'b', 'health'), max_age: 45, topology: non_linux_topology)
    end

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

    it 'returns the number of bytes written, as touch! does' do
      bytes = heartbeat.declare!(2)

      expect(bytes).to eq(File.size(File.join(dir, 'expected')))
    end
  end
end
