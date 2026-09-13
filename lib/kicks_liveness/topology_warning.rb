module KicksLiveness
  # The worker's one-time report of a container generation it could not fully
  # establish, and the flag that keeps it to a single line.
  #
  # Deliberately outside {Heartbeat}, for the reason {Attempts} is: the probe
  # loads that one file and nothing the probe does not need belongs in it. And
  # deliberately not on the probe's stdout either — an exec probe's output
  # reaches a human only through the kubelet's Unhealthy event, so a diagnostic
  # appended there would repeat on every invocation and sit beside reasons it
  # has nothing to do with. The worker's log is where a degradation belongs.
  #
  # The flag lives in the marks directory because that is the only state a fork
  # respawn cannot destroy, and one lost guarantee must not become thousands of
  # identical lines.
  #
  # @api private
  class TopologyWarning
    # @param dir [String] marks directory
    # @param topology [ContainerGeneration::Result] what this worker proved
    def initialize(dir, topology)
      @dir = dir
      @topology = topology
    end

    # Claims the right to report this state, once.
    #
    # The key carries the generation where there is one, so each container
    # incarnation reports once. Without a generation there is no honest
    # incarnation boundary to key that promise to, so the key is the error state
    # itself and holds for as long as it lasts. A verified generation clears the
    # flag, so the next degradation is reported rather than swallowed by a stale
    # one.
    #
    # @return [String, nil] the line to log, or nil when there is nothing new to say
    def claim!
      key = key_for(@topology)

      unless key
        forget! if @topology.verified?
        return nil
      end

      return nil if remembered == key

      remember(key)
      message_for(@topology)
    end

    private

    def path
      File.join(@dir, 'topology-warning')
    end

    def key_for(topology)
      case topology.state
      when :unverifiable then "unverifiable #{topology.generation}"
      when :unavailable then 'unavailable'
      end
    end

    def message_for(topology)
      if topology.unverifiable?
        "PID topology unverified (#{topology.detail}): the container generation still scopes the heartbeat, " \
          'but shareProcessNamespace and hostPID cannot be ruled out'
      else
        "no container generation (#{topology.detail}): falling back to freshness only, " \
          'which cannot reject a heartbeat inherited from a previous container'
      end
    end

    def remembered
      File.read(path).chomp
    rescue StandardError
      nil
    end

    # Best effort in both directions. A directory that cannot be written to
    # costs a repeated warning, which is noise; staying silent because the flag
    # could not be stored would hide a guarantee the operator has lost.
    def remember(key)
      require 'fileutils'
      FileUtils.mkdir_p(@dir)
      tmp = "#{path}.#{Process.pid}"
      File.write(tmp, "#{key}\n")
      File.rename(tmp, path)
    rescue StandardError
      nil
    end

    def forget!
      File.unlink(path)
    rescue StandardError
      nil
    end
  end
end
