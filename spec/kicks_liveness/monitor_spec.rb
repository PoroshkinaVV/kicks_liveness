require 'tmpdir'

RSpec.describe KicksLiveness::Monitor do
  subject(:monitor) do
    described_class.new(slot: 0, processes: 1, consumers: 1, config: config, heartbeat: heartbeat)
  end

  let(:tmp) { Dir.mktmpdir }
  let(:heartbeat) { KicksLiveness::Heartbeat.new(dir: File.join(tmp, 'health'), max_age: 45) }
  let(:logger) { FakeLogger.new }

  let(:config) do
    KicksLiveness.config.tap do |c|
      c.logger = logger
      c.tick = 10
      c.startup_grace_ticks = 3
    end
  end
  # The marks directory is the only state that survives a fork, which is what a
  # respawn storm destroys every few hundred milliseconds.
  let(:attempts) { KicksLiveness::Attempts.new(heartbeat.dir) }

  after { FileUtils.remove_entry(tmp) }

  def unhealthy! = allow(KicksLiveness::Registry).to receive(:healthy?).and_return(false)
  def healthy! = allow(KicksLiveness::Registry).to receive(:healthy?).and_return(true)

  def errors = logger.lines.select { |line| line.first == :error }

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
  end

  # A graceful shutdown empties the registry as each worker unsubscribes, and
  # Sneakers::Worker#stop then blocks until the thread pool drains — as long as
  # the longest in-flight job takes. Reporting that as a fault would put an
  # ERROR in the log on every single deploy.
  describe 'during a graceful shutdown' do
    before do
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

  # Defect: the escalation counter lived in the monitor instance, so a fork that
  # dies after 0.2s never reached the threshold. An 82-minute outage produced
  # 1601 identical INFO lines and not one ERROR.
  describe 'a respawn storm' do
    # Every incarnation of the monitor is a fresh object, exactly as a new fork
    # would be.
    def start_incarnation!
      described_class.new(slot: 0, processes: 1, consumers: 1, config: config, heartbeat: heartbeat).start!
    end

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
