require 'open3'
require 'tmpdir'

RSpec.describe 'liveness probe' do
  let(:tmp) { Dir.mktmpdir }
  let(:dir) { File.join(tmp, 'health') }
  let(:lib) { File.expand_path('../lib', __dir__) }

  after { FileUtils.remove_entry(tmp) }

  def run_probe(require_path: 'kicks_liveness/probe', env: {})
    out, status = Open3.capture2e(
      { 'KICKS_LIVENESS_DIR' => dir }.merge(env),
      RbConfig.ruby, '-I', lib, '-e', "require '#{require_path}'"
    )
    [out.strip, status.exitstatus]
  end

  # The marks below are published through this host's own topology, because the
  # subprocess derives its generation the same way and the two have to agree. A
  # host that proves its own topology unsupported — a privileged container in
  # the host PID namespace, which some CI runners are — would publish the
  # fail-closed state instead of marks, and every example here would report that
  # verdict rather than the one it is about.
  before do
    skip 'this host is itself in a shared or host PID namespace' if KicksLiveness::Heartbeat.topology.unsafe?
  end

  def healthy_marks!
    KicksLiveness::Heartbeat.new(dir: dir, max_age: 45).tap do |heartbeat|
      heartbeat.declare!(1)
      heartbeat.touch!(0)
    end
  end

  # Both assertions are on the whole of stdout, not a substring: an exec probe's
  # output reaches a human only through the kubelet's Unhealthy event, so a
  # diagnostic appended to it would repeat on every invocation and sit beside an
  # unrelated reason. A degraded topology is reported by the worker instead, and
  # these two run under whatever this host's procfs allows.
  it 'exits zero and prints the reason when the marks are fresh' do
    healthy_marks!

    expect(run_probe).to eq(['1 process(es) healthy', 0])
  end

  it 'exits one and prints the reason when the worker has not started' do
    expect(run_probe).to eq(["no #{File.join(dir, 'expected')}: worker has not started yet", 1])
  end

  it 'pulls in no bundler and requires neither kicks nor sneakers' do
    healthy_marks!

    _message, code = run_probe(env: { 'RUBYOPT' => '--disable-gems' })

    expect(code).to eq(0)
  end

  describe 'an expired shutdown grace' do
    let(:heartbeat) { healthy_marks! }
    let(:monitor) do
      KicksLiveness::Monitor.new(slot: 0, processes: 1, consumers: 1, config: KicksLiveness.config, heartbeat: heartbeat)
    end

    it 'leaves the probe green until the last mark becomes stale, then exits one' do
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(100.0, 160.0)
      KicksLiveness::Registry.stopping!

      expect(monitor.tick!).to be(false)
      expect(run_probe).to eq(['1 process(es) healthy', 0])
      stale = Time.now - 46
      File.utime(stale, stale, File.join(dir, 'worker-0'))
      expect(monitor.tick!).to be(false)
      message, code = run_probe
      expect(code).to eq(1)
      expect(message).to match(/\Aworker-0 stale \d+s > 45s\z/)
    end
  end

  # The packaged entry point, against the production generation rather than an
  # injected one: only a process that derives its own can reject an inherited
  # heartbeat, so Darwin cannot take part and a Linux host whose procfs yields
  # no generation has nothing to reject against.
  describe 'a heartbeat inherited from a previous container' do
    before do
      skip 'procfs yields no container generation on this host' unless KicksLiveness::Heartbeat.topology.generation
    end

    it 'exits one although every mark is present and fresh' do
      previous = KicksLiveness::Heartbeat.new(dir: dir, max_age: 45, topology: verified_topology('mnt:[0]:1'))
      previous.declare!(1)
      previous.touch!(0)

      expect(run_probe).to eq(['heartbeat belongs to a previous container: worker has not started yet', 1])
    end
  end

  # Proof of an unsafe topology from either participant is enough, and the two
  # need not agree: procfs access is local to a process. Here only the worker
  # could prove it, the probe's own result is weaker, and the marks it finds are
  # fresh and carry its own generation — it must still reject.
  it 'exits one on a worker-published unsafe topology, whatever its own marks say' do
    healthy_marks!
    KicksLiveness::Heartbeat.new(dir: dir, max_age: 45, topology: unsafe_topology).reject_topology!

    expect(run_probe).to eq(
      ['unsupported PID topology: pod must not set shareProcessNamespace or hostPID', 1]
    )
  end
end
