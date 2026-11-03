module KicksLiveness
  # The thread that publishes the liveness mark. Created inside the fork,
  # because threads do not survive +fork+.
  #
  # @see file:docs/DESIGN.md#logging-events-not-the-pulse
  # @api private
  class Monitor
    # @param slot [Integer] supervisor slot of this fork; names the mark file
    # @param processes [Integer] how many forks the probe must wait for
    # @param consumers [Integer] how many workers must subscribe in this process
    # @param config [Configuration]
    # @param heartbeat [Heartbeat, nil] injected in specs; {Attempts} follows its
    #   directory, so injecting it separately is not needed
    def initialize(slot:, processes:, consumers:, config:, heartbeat: nil)
      @slot = slot
      @processes = processes
      @consumers = consumers
      @config = config
      @heartbeat = heartbeat || Heartbeat.new
      @attempts = Attempts.new(@heartbeat.dir, generation: @heartbeat.topology.generation)
    end

    # Declares the expected fork count and starts the tick thread.
    # @return [Thread, nil] nil when the PID topology is proven unsupported
    def start!
      return reject_topology! if @heartbeat.topology.unsafe?

      attempt, elapsed = @attempts.record!(@slot)
      @heartbeat.declare!(@processes)
      attempt > 1 ? report_respawn(attempt, elapsed) : report_first_start
      report_topology

      Thread.new do
        Thread.current.name = 'kicks-liveness'
        run_loop
      end
    end

    # A single step: check, mark if healthy, log any transition. Public so that
    # specs do not have to drive the thread.
    #
    # @return [Boolean] whether the process is healthy at this moment
    def tick!
      # Restore expected after directory removal; refreshing a slot alone
      # cannot recover a probe whose expected count is missing.
      @heartbeat.declare!(@processes)

      return shutdown_tick! if Registry.stopping?

      healthy = Registry.healthy?(@consumers)
      if healthy
        @heartbeat.touch!(@slot)
        clear_attempt_once!
      end
      @unhealthy_ticks = healthy ? 0 : unhealthy_ticks + 1
      report(healthy)
      healthy
    end

    private

    # Publish unsafe evidence without recording a start or launching the loop.
    def reject_topology!
      # Reported before the state is published: a marks directory that cannot be
      # written to is exactly the case where the log line is all the operator
      # will get.
      report_topology
      @heartbeat.reject_topology!
      nil
    end

    # Claim before logging so simultaneous forks cannot report the same state.
    def report_topology
      level, message = TopologyReport.new(@heartbeat.dir, @heartbeat.topology).claim!

      log(level, message) if level
    end

    def report_first_start
      log(:info, "started: dir=#{@heartbeat.dir} max_age=#{@heartbeat.max_age}s tick=#{@config.tick}s " \
                 "processes=#{@processes} consumers=#{@consumers}")
    end

    # Seed @previous to suppress repeated waiting messages. Escalation uses the
    # persistent attempt window because unhealthy_ticks dies with each fork.
    def report_respawn(attempt, elapsed)
      @previous = false

      return if elapsed < grace_seconds

      log(:error, "not healthy #{elapsed.round}s over #{attempt} starts, expected #{@consumers} consumers")
      @attempts.restart_window!(@slot)
    end

    def grace_seconds
      @config.startup_grace_ticks * interval
    end

    # Clear once after recovery so a later failure starts a new unhealthy run.
    def clear_attempt_once!
      return if @attempt_cleared

      @attempts.clear!(@slot)
      @attempt_cleared = true
    end

    def unhealthy_ticks
      @unhealthy_ticks ||= 0
    end

    # The first stop callback, not a delayed tick, starts the monotonic deadline.
    # Expiry stops refreshes; ordinary mark staleness then fails the probe.
    # @see file:docs/LIMITATIONS.md#graceful-shutdown-has-a-finite-heartbeat-exemption
    def shutdown_tick! # rubocop:disable Naming/PredicateMethod -- Publishes the heartbeat and records transitions.
      @shutdown_deadline ||= Registry.stopping_at + @config.shutdown_grace
      report_shutdown_once

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @shutdown_deadline
        log(:error, 'shutdown grace expired: heartbeat is no longer refreshed') unless @shutdown_expired
        @shutdown_expired = true
        return false
      end

      @heartbeat.touch!(@slot)
      true
    end

    def report_shutdown_once
      return if @shutdown_reported

      log(:info, 'shutting down: consumers are no longer checked')
      @shutdown_reported = true
    end

    # Guard tick and sleep together so an exception cannot kill the only
    # heartbeat writer. Recovery uses the default interval.
    def run_loop
      loop do
        tick!
        sleep interval
      rescue StandardError => e
        log(:error, "monitor loop failed: #{e.class}: #{e.message}")
        sleep Configuration::DEFAULT_TICK
      end
    end

    # Values coming from the environment are already clamped by
    # {Heartbeat.env_int}; this covers a tick set programmatically.
    def interval
      tick = @config.tick
      tick.is_a?(Numeric) && tick.positive? ? tick : Configuration::DEFAULT_TICK
    end

    # Log transitions and startup escalation; the periodic pulse is the mtime.
    def report(healthy)
      if healthy != @previous
        report_transition(healthy)
        @previous = healthy
      elsif unhealthy_ticks == @config.startup_grace_ticks
        # Report once when a surviving monitor exhausts startup grace.
        log(:error, "not healthy #{unhealthy_ticks * @config.tick}s, expected #{@consumers} consumers")
      end
    end

    def report_transition(healthy)
      if healthy
        log(:info, 'healthy')
      elsif @previous.nil?
        log(:info, "waiting for #{@consumers} consumers")
      else
        log(:error, "became unhealthy (expected #{@consumers} consumers)")
      end
    end

    def log(level, message)
      @config.resolved_logger&.public_send(level, "[liveness] slot #{@slot}: #{message}")
    rescue StandardError
      # Logger failures must not stop the heartbeat writer. Do not retry the
      # same logger from its failure path.
      nil
    end
  end
end
