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
      @attempts = Attempts.new(@heartbeat.dir)
    end

    # Declares the expected fork count and starts the tick thread.
    # @return [Thread]
    def start!
      attempt, elapsed = @attempts.record!(@slot)
      @heartbeat.declare!(@processes)
      attempt > 1 ? report_respawn(attempt, elapsed) : report_first_start

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
      # Re-declared on every tick, not only at startup. This file is the probe's
      # only source for how many forks to expect, and nothing else restores it:
      # if the directory is wiped, `touch!` brings back the slot marks while
      # `expected` stays missing, and the probe reports "worker has not started"
      # for the rest of the pod's life. It also lets a respawned set of forks
      # correct the count after the supervisor was told to run fewer of them.
      @heartbeat.declare!(@processes)

      if Registry.stopping?
        shutdown_tick!
        return true
      end

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

    def report_first_start
      log(:info, "started: dir=#{@heartbeat.dir} max_age=#{@heartbeat.max_age}s tick=#{@config.tick}s " \
                 "processes=#{@processes} consumers=#{@consumers}")
    end

    # A slot that starts again without ever having become healthy is a respawn
    # loop: the supervisor brings the fork back after `start_worker_delay`,
    # which is a fraction of a second, so the process dies long before any
    # single monitor's grace period expires. Two things follow.
    #
    # The start line and the first transition are suppressed. Seeding
    # `@previous` is what does the second part: without it the first tick reads
    # a nil previous state and logs `waiting for N consumers`, which in a storm
    # means hundreds of identical INFO lines a minute and no diagnosis in any of
    # them.
    #
    # The escalation is driven off the marks directory instead of off
    # `unhealthy_ticks`, because that counter dies with the fork and can never
    # reach the threshold. Reporting once per grace window rather than once per
    # respawn is the difference between one line a minute and five a second.
    def report_respawn(attempt, elapsed)
      @previous = false

      return if elapsed < grace_seconds

      log(:error, "not healthy #{elapsed.round}s over #{attempt} starts, expected #{@consumers} consumers")
      @attempts.restart_window!(@slot)
    end

    def grace_seconds
      @config.startup_grace_ticks * interval
    end

    # Once the slot is healthy the respawn counter has done its job, and the
    # next start of this slot deserves to be treated as a fresh one.
    def clear_attempt_once!
      return if @attempt_cleared

      @attempts.clear!(@slot)
      @attempt_cleared = true
    end

    def unhealthy_ticks
      @unhealthy_ticks ||= 0
    end

    # From the moment shutdown begins the consumer count says nothing about
    # health: the workers unsubscribe one by one while the pool drains, and the
    # process is doing exactly what it was told. So the predicate is dropped and
    # the mark is kept fresh, which leaves a slow drain the whole of
    # terminationGracePeriodSeconds instead of having the probe cut it short at
    # max_age.
    def shutdown_tick!
      @heartbeat.touch!(@slot)

      return if @shutdown_reported

      log(:info, 'shutting down: consumers are no longer checked')
      @shutdown_reported = true
    end

    # Nothing inside this loop may be allowed to kill the thread. It is the only
    # thing writing the mark, and its death is close to invisible: the exception
    # surfaces as a bare backtrace on stderr, never through the gem's logger,
    # while the pod restarts on every probe budget with nothing in the
    # application log to explain it. `sleep` used to sit outside the guarded
    # block, which is exactly how a non-positive tick killed the monitor.
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

    # Events are logged, not the pulse — the pulse lives in the mark's mtime.
    # ERROR is reserved for genuine failure, because a logger usually comes up
    # with LOG_LEVEL defaulting to error.
    def report(healthy)
      if healthy != @previous
        report_transition(healthy)
        @previous = healthy
      elsif unhealthy_ticks == @config.startup_grace_ticks
        # Startup took longer than normal, which is a failure by now. Staying
        # silent would leave a pod that never comes up saying nothing about it.
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
      # Logging is diagnostic, while the heartbeat is the liveness contract. A
      # broken custom logger must not prevent a mark from being written or kill
      # the only thread that can refresh it. There is deliberately no fallback
      # log here: calling the same logger again would only repeat the failure.
      nil
    end
  end
end
