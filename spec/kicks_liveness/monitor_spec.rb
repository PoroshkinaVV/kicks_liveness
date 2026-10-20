require 'tmpdir'

RSpec.describe KicksLiveness::Monitor do
  subject(:monitor) do
    described_class.new(slot: 0, processes: 1, consumers: 1, config: config, heartbeat: heartbeat)
  end

  let(:tmp) { Dir.mktmpdir }
  let(:topology) { verified_topology('mnt:[2]:200') }
  let(:heartbeat) { KicksLiveness::Heartbeat.new(dir: File.join(tmp, 'health'), max_age: 45, topology: topology) }
  let(:logger) { FakeLogger.new }

  let(:config) do
    KicksLiveness.config.tap do |c|
      c.logger = logger
      c.tick = 10
      c.startup_grace_ticks = 3
    end
  end

  after { FileUtils.remove_entry(tmp) }

  def unhealthy! = allow(KicksLiveness::Registry).to receive(:healthy?).and_return(false)
  def healthy! = allow(KicksLiveness::Registry).to receive(:healthy?).and_return(true)

  # The marks directory is the only state that survives a fork, which is what a
  # respawn storm destroys every few hundred milliseconds.
  def attempts = KicksLiveness::Attempts.new(heartbeat.dir, generation: heartbeat.topology.generation)

  def errors = logger.lines.select { |line| line.first == :error }
  def warnings = logger.lines.select { |line| line.first == :warn }

  # Every incarnation of the monitor is a fresh object, exactly as a new fork
  # would be.
  def start_incarnation!
    described_class.new(slot: 0, processes: 1, consumers: 1, config: config, heartbeat: heartbeat).start!
  end

  describe '#tick!' do
    it 'writes the mark when healthy' do
      healthy!
      heartbeat.declare!(1)

      expect(monitor.tick!).to be(true)
      expect(heartbeat.check).to eq([true, '1 process(es) healthy'])
    end

    it 'writes no mark when unhealthy' do
      unhealthy!
      heartbeat.declare!(1)

      expect(monitor.tick!).to be(false)
      expect(heartbeat.check).to eq([false, 'worker-0 missing'])
    end
  end

  describe 'logging' do
    # An ordinary deploy must not make ERROR noise, or an alert on ERROR logs
    # fires on every pod restart.
    it 'an ordinary startup produces no ERROR' do
      unhealthy!
      monitor.tick!
      healthy!
      monitor.tick!

      expect(logger.lines).to eq(
        [
          [:info, '[liveness] slot 0: waiting for 1 consumers'],
          [:info, '[liveness] slot 0: healthy']
        ]
      )
    end

    it 'stays silent while the state does not change' do
      healthy!
      3.times { monitor.tick! }

      expect(logger.lines).to eq([[:info, '[liveness] slot 0: healthy']])
    end

    it 'complains at ERROR level when health is lost' do
      healthy!
      monitor.tick!
      unhealthy!
      monitor.tick!

      expect(logger.lines.last).to eq([:error, '[liveness] slot 0: became unhealthy (expected 1 consumers)'])
    end

    # Without this a pod that never comes up would say nothing about itself.
    it 'complains when startup drags on past the ticks allowed' do
      unhealthy!
      3.times { monitor.tick! }

      expect(logger.lines).to eq(
        [
          [:info, '[liveness] slot 0: waiting for 1 consumers'],
          [:error, '[liveness] slot 0: not healthy 30s, expected 1 consumers']
        ]
      )
    end

    it 'complains about a dragging startup once, not on every tick' do
      unhealthy!
      6.times { monitor.tick! }

      expect(logger.lines.count { |level, _| level == :error }).to eq(1)
    end

    it 'keeps publishing when the logger raises' do
      broken_logger = instance_double(FakeLogger)
      allow(broken_logger).to receive(:info).and_raise(RuntimeError, 'logger failed')
      config.logger = broken_logger
      healthy!

      expect(monitor.tick!).to be(true)
      expect(heartbeat.check).to eq([true, '1 process(es) healthy'])
    end
  end

  # A graceful shutdown empties the registry as each worker unsubscribes, and
  # Sneakers::Worker#stop then blocks until the thread pool drains — as long as
  # the longest in-flight job takes. Reporting that as a fault would put an
  # ERROR in the log on every single deploy.
  describe 'during a graceful shutdown' do
    def monotonic_time(seconds)
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(seconds)
    end

    before do
      allow(Process).to receive(:clock_gettime).and_call_original
      monotonic_time(100.0)
      healthy!
      heartbeat.declare!(1)
      monitor.tick!
      KicksLiveness::Registry.stopping!
      unhealthy!
    end

    it 'stays healthy while the workers unsubscribe' do
      expect(monitor.tick!).to be(true)
    end

    # Otherwise a drain longer than max_age would have the probe cut the pod
    # down before terminationGracePeriodSeconds is up, killing in-flight jobs.
    it 'keeps the mark fresh so a slow drain is not cut short' do
      monitor.tick!

      expect(heartbeat.check).to eq([true, '1 process(es) healthy'])
    end

    it 'logs no ERROR' do
      3.times { monitor.tick! }

      expect(logger.lines.map(&:first)).to all(eq(:info))
    end

    it 'says so once, not on every tick' do
      3.times { monitor.tick! }

      expect(logger.lines.count { |_, message| message.include?('shutting down') }).to eq(1)
    end

    it 'refreshes until just before the deadline without checking consumers' do
      monotonic_time(159.9)

      expect(monitor.tick!).to be(true)
      expect(heartbeat.check).to eq([true, '1 process(es) healthy'])
      expect(errors).to be_empty
      expect(KicksLiveness::Registry).to have_received(:healthy?).once
    end

    it 'stops refreshing at the deadline even when the first shutdown tick was delayed' do
      original = File.stat(File.join(heartbeat.dir, 'worker-0')).mtime
      monotonic_time(160.0)

      expect(monitor.tick!).to be(false)
      expect(File.stat(File.join(heartbeat.dir, 'worker-0')).mtime).to eq(original)
      expect(heartbeat.check(now: original + 46)).to eq([false, 'worker-0 stale 46s > 45s'])
      expect(errors.map(&:last)).to eq(['[liveness] slot 0: shutdown grace expired: heartbeat is no longer refreshed'])
    end

    it 'does not renew the deadline or repeat logs on repeated stop callbacks' do
      monitor.tick!
      monotonic_time(150.0)
      KicksLiveness::Registry.stopping!
      monitor.tick!
      monotonic_time(160.0)

      expect(Array.new(3) { monitor.tick! }).to all(be(false))
      expect(errors.size).to eq(1)
      expect(logger.lines.count { |_, message| message.include?('shutting down') }).to eq(1)
    end

    it 'keeps declaring the fork count after expiry without recreating a missing mark' do
      monotonic_time(160.0)
      FileUtils.remove_entry(heartbeat.dir)

      expect(monitor.tick!).to be(false)
      expect(File.read(File.join(heartbeat.dir, 'expected'))).to eq('1')
      expect(heartbeat.check).to eq([false, 'worker-0 missing'])
    end

    it 'uses the configured grace and cannot resume publishing after expiry' do
      config.shutdown_grace = 5
      monotonic_time(105.0)

      expect(monitor.tick!).to be(false)
      config.shutdown_grace = 120
      healthy!
      expect(monitor.tick!).to be(false)
    end

    [-3600, 3600].each do |jump|
      it "keeps the monotonic deadline when the wall clock jumps #{jump}s" do
        wall_time = Time.now + jump
        allow(Time).to receive(:now).and_return(wall_time)
        monotonic_time(159.0)

        expect(monitor.tick!).to be(true)
        monotonic_time(160.0)
        expect(monitor.tick!).to be(false)
      end
    end
  end

  describe '#start!' do
    it 'declares the process count and logs the settings in force' do
      healthy!

      thread = monitor.start!

      expect(logger.lines.first).to eq(
        [:info, "[liveness] slot 0: started: dir=#{heartbeat.dir} max_age=45s tick=10s processes=1 consumers=1"]
      )
    ensure
      thread&.kill
    end

    # The thread is the only thing writing the mark, and its death is close to
    # invisible: the exception would surface as a bare backtrace on stderr,
    # never through the gem's logger, while the pod restarts on every probe
    # budget with nothing in the log to explain it.
    it 'survives an error raised inside the loop' do
      allow(KicksLiveness::Registry).to receive(:healthy?).and_raise(RuntimeError, 'boom')

      thread = monitor.start!
      sleep 0.2

      expect(thread).to be_alive
      expect(logger.lines).to include([:error, '[liveness] slot 0: monitor loop failed: RuntimeError: boom'])
    ensure
      thread&.kill
    end

    it 'survives when reporting a loop error raises too' do
      broken_logger = instance_double(FakeLogger)
      allow(broken_logger).to receive(:info).and_raise(RuntimeError, 'logger failed')
      allow(broken_logger).to receive(:error).and_raise(RuntimeError, 'logger failed')
      config.logger = broken_logger
      allow(KicksLiveness::Registry).to receive(:healthy?).and_raise(RuntimeError, 'tick failed')

      thread = monitor.start!
      sleep 0.2

      expect(thread).to be_alive
    ensure
      thread&.kill
    end

    # A tick that cannot be slept on used to kill the thread outright, because
    # `sleep` sat outside the rescue. Values from the environment are clamped,
    # so this is the last line of defence for one that got in another way.
    it 'falls back to the default interval when the tick is unusable' do
      healthy!
      config.instance_variable_set(:@tick, -1)

      thread = monitor.start!
      sleep 0.2

      expect(thread).to be_alive
      expect(logger.lines.map(&:first)).not_to include(:error)
    ensure
      thread&.kill
    end
  end

  # Neither the worker nor the probe owns this verdict alone: their procfs
  # access is local to each process. A worker that can prove the topology
  # unsafe publishes that proof rather than a heartbeat, so a probe that cannot
  # prove it still rejects.
  describe 'a proven unsupported PID topology' do
    let(:topology) { unsafe_topology }

    before { allow(Thread).to receive(:new) }

    it 'starts no monitor thread' do
      expect(monitor.start!).to be_nil
    end

    it 'publishes the fail-closed state and no marks, generation or counter' do
      monitor.start!

      # The report flag is the worker's own bookkeeping; what must not be here
      # is expected, generation, worker-0 or attempt-0.
      expect(Dir.children(heartbeat.dir).sort).to eq(%w[topology-report topology-unsafe])
    end

    it 'makes the probe fail with the reason an operator can act on' do
      monitor.start!

      expect(heartbeat.check).to eq([false, KicksLiveness::Heartbeat::UNSUPPORTED_TOPOLOGY])
    end

    it 'reports it at ERROR, naming both settings and the way out' do
      monitor.start!

      expect(logger.lines).to contain_exactly(
        [:error, a_string_including(KicksLiveness::Heartbeat::UNSUPPORTED_TOPOLOGY)
                   .and(a_string_including('until the pod is recreated'))]
      )
    end

    # A fork that cannot subscribe comes back every few hundred milliseconds,
    # and the topology is not something it can change. Reporting per respawn
    # would be the log storm the respawn counter exists to prevent.
    it 'reports it once, not on every fork respawn' do
      3.times { start_incarnation! }

      expect(errors.size).to eq(1)
    end
  end

  # The probe must keep printing its own success or failure and nothing else:
  # its stdout is read through an Unhealthy event, where a diagnostic repeated
  # beside an unrelated reason is worse than useless. So the worker warns.
  describe 'a topology that could not be verified' do
    let(:topology) { unverifiable_topology('mnt:[2]:200') }

    before do
      unhealthy!
      allow(Thread).to receive(:new)
    end

    it 'warns once, whatever the generation check still guarantees' do
      3.times { start_incarnation! }

      expect(warnings).to contain_exactly(
        [:warn, '[liveness] slot 0: PID topology unverified (cannot read /proc/1/ns/mnt (Errno::EACCES)): ' \
                'the container generation still scopes the heartbeat, but shareProcessNamespace and hostPID ' \
                'cannot be ruled out']
      )
    end

    it 'keeps the 0.1.2 generation check and the probe message unchanged' do
      healthy!
      monitor.tick!

      expect(heartbeat.check).to eq([true, '1 process(es) healthy'])
    end

    # A generation it cannot verify is still a generation, and still the right
    # scope for a count that belongs to one container.
    it 'scopes the respawn counter to the generation it does have' do
      KicksLiveness::Attempts.new(heartbeat.dir, generation: 'mnt:[1]:100').record!(0, now: Time.now.utc - 31)

      start_incarnation!

      expect(errors).to be_empty
    end
  end

  describe 'a generation that could not be derived on Linux' do
    let(:topology) { unavailable_topology }

    before do
      unhealthy!
      allow(Thread).to receive(:new)
    end

    # Without a generation there is no incarnation to key a warning to, so the
    # persisted error state is what keeps a respawn storm from repeating it.
    it 'warns once for the error state, not once per fork respawn' do
      3.times { start_incarnation! }

      expect(warnings).to contain_exactly(
        [:warn, '[liveness] slot 0: no container generation (cannot read /proc/1/stat (Errno::EACCES)): ' \
                'falling back to freshness only, which cannot reject a heartbeat inherited from a previous ' \
                'container']
      )
    end

    it 'keeps publishing marks under the 0.1.1 freshness-only contract' do
      healthy!
      monitor.tick!

      expect(heartbeat.check).to eq([true, '1 process(es) healthy'])
    end

    # Nothing honest to scope the counter to, so it keeps the volume-wide scope
    # rather than claiming one it cannot enforce.
    it 'keeps the generation-less respawn counter' do
      KicksLiveness::Attempts.new(heartbeat.dir).record!(0, now: Time.now.utc - 31)

      start_incarnation!

      expect(errors.map(&:last)).to contain_exactly(include('over 2 starts'))
    end
  end

  describe 'a platform without procfs' do
    let(:topology) { non_linux_topology }

    it 'says nothing: the fallback is intended, not a degradation' do
      healthy!
      allow(Thread).to receive(:new)

      start_incarnation!

      expect(warnings).to be_empty
    end
  end

  # The marks volume survives a container restart, so without scoping the
  # counter the replacement container suppresses its own `started:` line and can
  # escalate over starts it never took.
  describe 'a replacement container' do
    before do
      unhealthy!
      allow(Thread).to receive(:new)
    end

    def start_in(generation)
      described_class.new(
        slot: 0, processes: 1, consumers: 1, config: config,
        heartbeat: KicksLiveness::Heartbeat.new(
          dir: heartbeat.dir, max_age: 45, topology: verified_topology(generation)
        )
      ).start!
    end

    it 'logs its own first start rather than continuing the previous run' do
      start_in('mnt:[1]:100')
      logger.lines.clear

      start_in('mnt:[2]:200')

      expect(logger.lines.count { |_, message| message.include?('started:') }).to eq(1)
    end

    it 'never escalates over starts from the previous container' do
      KicksLiveness::Attempts.new(heartbeat.dir, generation: 'mnt:[1]:100').record!(0, now: Time.now.utc - 31)

      start_in('mnt:[2]:200')

      expect(errors).to be_empty
    end

    it 'still counts the respawns of its own container' do
      attempts.record!(0, now: Time.now.utc - 31)

      start_in('mnt:[2]:200')

      expect(errors.map(&:last)).to contain_exactly(include('over 2 starts'))
    end
  end

  # Defect: `expected` used to be written only at startup, so a wiped directory
  # left the probe reporting "worker has not started" for the rest of the pod's
  # life — while touch! kept bringing the slot marks back.
  describe 'a wiped marks directory' do
    it 'is repaired by one tick' do
      healthy!
      monitor.tick!
      FileUtils.remove_entry(heartbeat.dir)

      monitor.tick!

      expect(heartbeat.check).to eq([true, '1 process(es) healthy'])
    end
  end

  describe 'a replacement fork after a shutdown' do
    it 'does not inherit the stopped sibling deadline through the shared marks directory' do
      healthy!
      monitor.tick!
      config.shutdown_grace = 1
      stopped_pid = fork do
        allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(100.0, 101.0)
        KicksLiveness::Registry.stopping!
        exit!(monitor.tick! ? 1 : 0)
      end
      expect(Process.wait2(stopped_pid).last.exitstatus).to eq(0)

      replacement_pid = fork { exit!(monitor.tick! ? 0 : 1) }
      expect(Process.wait2(replacement_pid).last.exitstatus).to eq(0)
      expect(heartbeat.check).to eq([true, '1 process(es) healthy'])
    end
  end

  # Defect: the escalation counter lived in the monitor instance, so a fork that
  # dies after 0.2s never reached the threshold. An 82-minute outage produced
  # 1601 identical INFO lines and not one ERROR.
  describe 'a respawn storm' do
    before do
      unhealthy!
      # Stubbed rather than started and killed: a real thread may or may not
      # reach its first tick before the kill lands, and these examples are about
      # what start! itself reports.
      allow(Thread).to receive(:new)
    end

    it 'logs the start line only for the first incarnation' do
      3.times { start_incarnation! }

      expect(logger.lines.count { |_, message| message.include?('started:') }).to eq(1)
    end

    it 'says nothing at all while the grace window has not expired' do
      start_incarnation!
      before_repeats = logger.lines.size

      5.times { start_incarnation! }

      expect(logger.lines.size).to eq(before_repeats)
    end

    # config here is tick 10 x grace 3 = 30s.
    it 'escalates to ERROR once the grace window has expired' do
      attempts.record!(0, now: Time.now.utc - 31)

      start_incarnation!

      expect(errors.map(&:last)).to contain_exactly(
        match(/\A\[liveness\] slot 0: not healthy \d+s over 2 starts, expected 1 consumers\z/)
      )
    end

    # Reporting once per respawn would be five ERROR lines a second.
    it 'escalates once per window, not once per respawn' do
      attempts.record!(0, now: Time.now.utc - 31)

      5.times { start_incarnation! }

      expect(errors.size).to eq(1)
    end

    it 'treats the next start as fresh once the slot has been healthy' do
      attempts.record!(0, now: Time.now.utc - 31)
      healthy!
      monitor.tick!

      start_incarnation!

      expect(logger.lines.count { |_, message| message.include?('started:') }).to eq(1)
    end
  end
end
