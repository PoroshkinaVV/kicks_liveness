require 'tmpdir'

RSpec.describe KicksLiveness::TopologyReport do
  let(:tmp) { Dir.mktmpdir }
  let(:dir) { File.join(tmp, 'health') }

  after { FileUtils.remove_entry(tmp) }

  def claim(topology) = described_class.new(dir, topology).claim!
  def message(topology) = claim(topology)&.last
  def level(topology) = claim(topology)&.first

  # The pipe choreography is kept together so that every child is demonstrably
  # waiting before any of them enters the claim. Splitting each descriptor
  # operation into helpers would hide the concurrency contract this test pins.
  # rubocop:disable Metrics/AbcSize
  def concurrent_claims(count)
    ready, start, result = Array.new(3) { IO.pipe }
    pids = count.times.map { spawn_claim(ready, start, result) }
    close_ios(ready[1], start[0], result[1])
    ready[0].read(count)
    start[1].write('.' * count)
    start[1].close
    claims = result[0].read(count)
    statuses = pids.map { |pid| Process.wait2(pid).last }
    [claims, statuses]
  ensure
    close_ios(*[ready, start, result].compact.flatten)
  end

  def spawn_claim(ready, start, result)
    report_class = described_class
    shared_dir = dir
    fork do
      begin
        close_ios(ready[0], start[1], result[0])
        ready[1].write('.')
        ready[1].close
        start[0].read(1)

        topology = KicksLiveness::ContainerGeneration::Result.unavailable('test')
        result[1].write(report_class.new(shared_dir, topology).claim! ? '1' : '0')
      ensure
        # Closing here is what gives the parent an EOF if this child raised,
        # instead of a read that never returns.
        close_ios(start[0], result[1])
      end
      # The child inherited the parent's at_exit handlers, RSpec's reporter
      # among them, and must not run any of them: they belong to a suite this
      # process is not running. The pipe is already closed, so nothing is left
      # in a buffer for the ordinary exit path to flush.
      exit!(0)
    end
  end
  # rubocop:enable Metrics/AbcSize

  def close_ios(*ios) = ios.each { |io| io.close unless io.closed? }

  it 'reports an unverifiable topology once, however often a fork respawns' do
    expect(message(unverifiable_topology)).to include('PID topology unverified')
    expect(claim(unverifiable_topology)).to be_nil
  end

  it 'grants one report when all worker forks start together' do
    skip 'fork is unavailable on this platform' unless Process.respond_to?(:fork)

    claims, statuses = concurrent_claims(8)

    expect(statuses).to all(be_success)
    expect(claims.count('1')).to eq(1)
    expect(Dir.children(dir)).to eq(['topology-report'])
  end

  it 'says what the generation still guarantees and what it does not' do
    expect(claim(unverifiable_topology)).to eq(
      [:warn,
       'PID topology unverified (cannot read /proc/1/ns/mnt (Errno::EACCES)): the container generation still ' \
       'scopes the heartbeat, but shareProcessNamespace and hostPID cannot be ruled out']
    )
  end

  it 'reports again for the next container incarnation' do
    claim(unverifiable_topology('mnt:[2]:200'))

    expect(claim(unverifiable_topology('mnt:[3]:300'))).not_to be_nil
  end

  # Without a generation there is no incarnation boundary to key the promise to,
  # so the error state itself is what the flag holds.
  it 'reports an uninterrupted generation-unavailable state once' do
    expect(claim(unavailable_topology)).to eq(
      [:warn,
       'no container generation (cannot read /proc/1/stat (Errno::EACCES)): falling back to freshness only, ' \
       'which cannot reject a heartbeat inherited from a previous container']
    )
    expect(claim(unavailable_topology)).to be_nil
  end

  # The verdict, not a degradation: the probe fails on it and the pod cannot
  # recover without being recreated, so it is the one state reported at ERROR.
  # It has no honest incarnation boundary either — that is the finding itself —
  # so it is claimed once for as long as the state lasts, exactly like the
  # generation-unavailable one.
  it 'reports a proven unsupported topology once, at ERROR' do
    expect(level(unsafe_topology)).to eq(:error)
    expect(claim(unsafe_topology)).to be_nil
  end

  it 'names both settings and the way out' do
    expect(message(unsafe_topology)).to eq(
      'unsupported PID topology: pod must not set shareProcessNamespace or hostPID ' \
      '(PID 1 is in mnt:[4026531840], this process in mnt:[4026532686]); ' \
      'liveness probes fail until the pod is recreated without those settings'
    )
  end

  it 'reports again once a verified generation has cleared the state' do
    claim(unavailable_topology)
    claim(verified_topology)

    expect(claim(unavailable_topology)).not_to be_nil
  end

  it 'stays quiet off Linux, where the fallback is intended rather than degraded' do
    expect(claim(non_linux_topology)).to be_nil
    expect(Dir).not_to exist(dir)
  end

  it 'stays quiet for a verified topology, and creates no flag to clear later' do
    expect(claim(verified_topology)).to be_nil
  end

  # The flag shares the marks directory with the protocol, so it has to be
  # something the probe ignores.
  it 'leaves the probe contract alone' do
    claim(unavailable_topology)
    heartbeat = KicksLiveness::Heartbeat.new(dir: dir, max_age: 45, topology: unavailable_topology)
    heartbeat.declare!(1)
    heartbeat.touch!(0)

    expect(heartbeat.check).to eq([true, '1 process(es) healthy'])
  end
end
