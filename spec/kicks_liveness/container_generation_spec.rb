RSpec.describe KicksLiveness::ContainerGeneration do
  # Darwin has no procfs, so every Linux branch is driven through stubs. The
  # Linux behaviour itself is acceptance-tested against real namespaces by
  # spec/integration/verify.sh; these examples pin the decision table.
  def stub_procfs(self_namespace: 'mnt:[4026533000]', pid1_namespace: 'mnt:[4026533000]', stat: pid1_stat)
    allow(File).to receive(:readlink).and_call_original
    allow(File).to receive(:read).and_call_original
    stub_entry(:readlink, '/proc/self/ns/mnt', self_namespace)
    stub_entry(:readlink, '/proc/1/ns/mnt', pid1_namespace)
    stub_entry(:read, '/proc/1/stat', stat)
  end

  def stub_entry(method, path, value)
    expectation = allow(File).to receive(method).with(path)
    value.is_a?(Class) ? expectation.and_raise(value) : expectation.and_return(value)
  end

  def pid1_stat(started_at = '987654')
    # Field 22 is the start time, and the command in parentheses is field 2, so
    # the tail after it begins at field 3.
    "1 (worker main) #{['S', *Array.new(18, '0'), started_at].join(' ')}"
  end

  def current = described_class.current(linux: true)

  describe 'a container-private PID namespace' do
    it 'is verified, and identifies the incarnation by mount namespace and PID 1 start time' do
      stub_procfs

      expect(current).to have_attributes(state: :verified, generation: 'mnt:[4026533000]:987654', detail: nil)
    end
  end

  # shareProcessNamespace: true puts PID 1 in the pod sandbox, hostPID: true in
  # the node's init process. Both outlive a restart of the worker container, so
  # the 0.1.2 identifier repeats and an inherited heartbeat passes.
  describe 'a shared or host PID namespace' do
    it 'is proven unsafe when PID 1 lives in another mount namespace' do
      stub_procfs(pid1_namespace: 'mnt:[4026531840]')

      expect(current).to have_attributes(
        state: :unsafe,
        generation: nil,
        detail: 'PID 1 is in mnt:[4026531840], this process in mnt:[4026533000]'
      )
    end

    # The comparison alone decides it: a start time read from a PID 1 that is
    # not this container's would only invent an identifier nobody can trust.
    it 'is unsafe even when PID 1 start time cannot be read at all' do
      stub_procfs(pid1_namespace: 'mnt:[4026531840]', stat: Errno::EACCES)

      expect(current).to be_unsafe
    end
  end

  describe 'an unreadable PID 1 mount namespace' do
    it 'keeps the generation and reports the topology as unverified, not as unsafe' do
      stub_procfs(pid1_namespace: Errno::EACCES)

      expect(current).to have_attributes(
        state: :unverifiable,
        generation: 'mnt:[4026533000]:987654',
        detail: 'cannot read /proc/1/ns/mnt (Errno::EACCES)'
      )
    end
  end

  # Distinct from the two above: there is nothing to compare and nothing to
  # scope the marks with, so only the 0.1.1 freshness check remains.
  describe 'a generation that cannot be derived on Linux' do
    it 'reports the mount namespace it could not read' do
      stub_procfs(self_namespace: Errno::ENOENT)

      expect(current).to have_attributes(
        state: :unavailable,
        generation: nil,
        detail: 'cannot read /proc/self/ns/mnt (Errno::ENOENT)'
      )
    end

    it 'reports an unreadable PID 1 start time' do
      stub_procfs(stat: Errno::EACCES)

      expect(current).to have_attributes(state: :unavailable, detail: 'cannot read /proc/1/stat (Errno::EACCES)')
    end

    it 'reports a stat line it cannot parse' do
      stub_procfs(stat: 'not a stat line')

      expect(current).to have_attributes(state: :unavailable, detail: 'cannot parse /proc/1/stat')
    end

    it 'reports a start time that is not a positive number' do
      stub_procfs(stat: pid1_stat('0'))

      expect(current).to have_attributes(state: :unavailable, detail: 'cannot parse /proc/1/stat')
    end
  end

  # An expected compatibility mode rather than a degradation: nothing to warn
  # about, and no procfs to guess at.
  describe 'a platform that is not Linux' do
    it 'reports the intentional fallback without touching procfs' do
      allow(File).to receive(:readlink).and_call_original

      expect(described_class.current(linux: false)).to have_attributes(state: :non_linux, generation: nil)
      expect(File).not_to have_received(:readlink).with(%r{\A/proc/})
    end
  end

  # RUBY_PLATFORM names the host on CRuby but is "java" on JRuby wherever it
  # runs (https://bugs.ruby-lang.org/issues/8090), so the platform string alone
  # would take the guard away from a JRuby worker in a Linux container, and take
  # it away silently. Measured on jruby 9.4: RUBY_PLATFORM "java",
  # RbConfig::CONFIG['host_os'] "linux".
  describe 'deciding whether this is Linux at all' do
    def on_java(host_os)
      stub_const('RUBY_PLATFORM', 'java')
      stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => host_os))
    end

    it 'trusts the platform string on CRuby' do
      stub_const('RUBY_PLATFORM', 'aarch64-linux')
      stub_procfs

      expect(described_class.current).to be_verified
    end

    it 'asks the host operating system when the platform string cannot answer' do
      on_java('linux')
      stub_procfs

      expect(described_class.current).to be_verified
    end

    # The whole reason the two questions are kept apart: a missing procfs may
    # answer "no generation", and must never answer "not Linux". Silence is
    # for a platform that was never going to have one.
    it 'reports a Linux host whose procfs is absent as unavailable, not as another platform' do
      on_java('linux')
      stub_procfs(self_namespace: Errno::ENOENT, pid1_namespace: Errno::ENOENT, stat: Errno::ENOENT)

      expect(described_class.current).to have_attributes(
        state: :unavailable,
        detail: 'cannot read /proc/self/ns/mnt (Errno::ENOENT)'
      )
    end

    it 'keeps the quiet fallback for the same runtime off Linux' do
      on_java('darwin21')
      allow(File).to receive(:readlink).and_call_original

      expect(described_class.current).to be_non_linux
      expect(File).not_to have_received(:readlink).with(%r{\A/proc/})
    end
  end
end
