require 'tmpdir'

RSpec.describe KicksLiveness::TopologyWarning do
  let(:tmp) { Dir.mktmpdir }
  let(:dir) { File.join(tmp, 'health') }

  after { FileUtils.remove_entry(tmp) }

  def claim(topology) = described_class.new(dir, topology).claim!

  it 'reports an unverifiable topology once, however often a fork respawns' do
    expect(claim(unverifiable_topology)).to include('PID topology unverified')
    expect(claim(unverifiable_topology)).to be_nil
  end

  it 'says what the generation still guarantees and what it does not' do
    expect(claim(unverifiable_topology)).to eq(
      'PID topology unverified (cannot read /proc/1/ns/mnt (Errno::EACCES)): the container generation still ' \
      'scopes the heartbeat, but shareProcessNamespace and hostPID cannot be ruled out'
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
      'no container generation (cannot read /proc/1/stat (Errno::EACCES)): falling back to freshness only, ' \
      'which cannot reject a heartbeat inherited from a previous container'
    )
    expect(claim(unavailable_topology)).to be_nil
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
