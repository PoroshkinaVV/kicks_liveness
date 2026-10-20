require 'fileutils'

module KicksLiveness
  # Claims worker topology reports across fork respawns. Kept outside
  # {Heartbeat} because the probe does not report these diagnostics.
  #
  # @see file:docs/LIMITATIONS.md#container-generations-need-linux-procfs-and-a-private-pid-namespace
  # @api private
  class TopologyReport
    # @param dir [String] marks directory
    # @param topology [ContainerGeneration::Result] what this worker proved
    def initialize(dir, topology)
      @dir = dir
      @topology = topology
    end

    # Claims the right to report this state, once.
    #
    # Unverifiable results use a generation key; unavailable and unsafe results
    # have no trustworthy generation and use only their state. Verification
    # clears the flag so a later degradation can be reported again.
    #
    # @return [Array(Symbol, String), nil] the level and the line to log, or nil
    #   when there is nothing new to say
    def claim!
      key = key_for(@topology)

      unless key
        forget! if @topology.verified?
        return nil
      end

      return nil unless claim(key)

      report_for(@topology)
    end

    private

    def path
      File.join(@dir, 'topology-report')
    end

    def key_for(topology)
      case topology.state
      when :unsafe then 'unsafe'
      when :unverifiable then "unverifiable #{topology.generation}"
      when :unavailable then 'unavailable'
      end
    end

    # Only unsafe changes the probe verdict and is reported at ERROR.
    def report_for(topology)
      case topology.state
      when :unsafe
        [:error, "#{Heartbeat::UNSUPPORTED_TOPOLOGY} (#{topology.detail}); " \
                 'liveness probes fail until the pod is recreated without those settings']
      when :unverifiable
        [:warn, "PID topology unverified (#{topology.detail}): the container generation still scopes the heartbeat, " \
                'but shareProcessNamespace and hostPID cannot be ruled out']
      else
        [:warn, "no container generation (#{topology.detail}): falling back to freshness only, " \
                'which cannot reject a heartbeat inherited from a previous container']
      end
    end

    # The runner starts all of its forks together, so the read and write have
    # to be one inter-process operation: an atomic rename protects readers from
    # a partial file, but does not stop every fork reading the old key and each
    # claiming the same report. The state file is also the lock file, so no
    # second path is added to the marks contract. Once it has existed it is
    # cleared by truncation rather than unlink: every process must keep locking
    # the same inode.
    def claim(key)
      synchronize(create: true) do |state|
        state.rewind
        next false if state.read.chomp == key

        state.rewind
        state.truncate(0)
        state.write("#{key}\n")
        state.flush
        true
      end
    rescue StandardError
      # A report that cannot be remembered must still be made. The cost is
      # repetition on the next start, not silence about a lost guarantee.
      true
    end

    def forget!
      return unless File.exist?(path)

      synchronize(create: false) { |state| state.truncate(0) }
    rescue StandardError
      nil
    end

    def synchronize(create:)
      FileUtils.mkdir_p(@dir)
      flags = File::RDWR
      flags |= File::CREAT if create
      File.open(path, flags, 0o644) do |state|
        raise IOError, "cannot lock #{path}" unless state.flock(File::LOCK_EX)

        yield state
      end
    end
  end
end
