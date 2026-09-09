require_relative 'heartbeat'

module KicksLiveness
  # What the application may configure, and what comes from the environment only.
  #
  # +dir+ and +max_age+ are deliberately read-only here: the probe runs as a
  # separate process launched by the container runtime and cannot read the
  # application's initializer. Were they settable in both places, a mismatch
  # between what the worker writes and what the probe expects would pass
  # unnoticed.
  #
  # @see file:docs/SETUP.md#configuration
  # @see file:docs/DESIGN.md#what-is-configurable-and-where
  class Configuration
    # @return [Integer] default seconds between checks
    DEFAULT_TICK = 10
    # @return [Integer] unhealthy ticks tolerated at startup before one ERROR
    DEFAULT_STARTUP_GRACE_TICKS = 6

    # Seconds between checks. An incompatibility warning for an environment
    # fallback is delayed until this value is actually used, so an initializer
    # can override it or disable the monitor without a misleading warning.
    # @return [Numeric]
    def tick
      warn_incompatible_environment_tick_once
      @tick
    end
    # @return [Integer] unhealthy ticks tolerated at startup before one ERROR
    attr_reader :startup_grace_ticks
    # @return [Logger, nil] explicit logger; defaults to +Sneakers.logger+
    attr_accessor :logger
    # @param value [Boolean] set false to start no monitor thread, e.g. in tests
    attr_writer :enabled

    def initialize
      @startup_grace_ticks = DEFAULT_STARTUP_GRACE_TICKS
      @enabled = true
      @logger = nil
      @tick = environment_tick
    end

    # @return [Boolean]
    def enabled?
      @enabled
    end

    # A tick is what the monitor thread sleeps on, so a non-positive value is
    # not a setting but a broken monitor. An initializer is code, and code
    # should fail loudly at boot, where the developer is looking. Environment
    # input is resolved separately by {#environment_tick}, with a safe fallback.
    #
    # @param seconds [Numeric]
    # @raise [ArgumentError] if not a positive number
    # @return [Numeric]
    def tick=(seconds)
      raise ArgumentError, "tick must be a positive number, got #{seconds.inspect}" unless positive_number?(seconds)
      raise ArgumentError, "tick must be less than max_age (#{max_age}s), got #{seconds.inspect}" if seconds >= max_age

      @incompatible_environment_tick = nil
      @tick = seconds
    end

    # The monitor compares an integer tick counter with this value. Accepting
    # zero, a float, or a string would silently prevent the startup escalation
    # from ever firing.
    #
    # @param ticks [Integer]
    # @raise [ArgumentError] unless +ticks+ is a positive integer
    # @return [Integer]
    def startup_grace_ticks=(ticks)
      unless ticks.is_a?(Integer) && ticks.positive?
        raise ArgumentError, "startup_grace_ticks must be a positive integer, got #{ticks.inspect}"
      end

      @startup_grace_ticks = ticks
    end

    # Read-only, sourced from the environment so that it matches what the probe
    # sees.
    # @return [String] marks directory
    def dir
      Heartbeat.env_dir
    end

    # Read-only, sourced from the environment so that it matches what the probe
    # sees.
    # @return [Integer] seconds after which a mark is considered stale
    def max_age
      Heartbeat.env_max_age
    end

    # Resolved lazily: at the time this object is built, +Sneakers.logger+ may
    # not be configured yet.
    # @return [Logger, false, nil]
    def resolved_logger
      @logger || (defined?(::Sneakers) && ::Sneakers.logger)
    end

    private

    def environment_tick
      raw = Heartbeat.env_raw(:tick)
      seconds = Heartbeat.env_int(:tick, DEFAULT_TICK)
      threshold = max_age
      return seconds if seconds < threshold

      fallback = [DEFAULT_TICK, threshold / 2.0].min
      @incompatible_environment_tick = [seconds, threshold, fallback, raw]
      fallback
    end

    def warn_incompatible_environment_tick_once
      warning = @incompatible_environment_tick
      return unless warning

      @incompatible_environment_tick = nil
      warn_incompatible_environment_tick(*warning)
    end

    def warn_incompatible_environment_tick(seconds, threshold, fallback, raw)
      Kernel.warn(
        "WARN [liveness] effective tick=#{seconds}s (#{environment_tick_source(raw)}) must be less than " \
        "KICKS_LIVENESS_MAX_AGE=#{threshold}s; using #{fallback}s"
      )
    rescue StandardError
      # Configuration recovery must not become a worker boot failure merely
      # because stderr is unavailable or warning output has been overridden.
      nil
    end

    def environment_tick_source(raw)
      return 'default' if raw.nil?

      value = Integer(raw)
      return "KICKS_LIVENESS_TICK=#{raw}" if value.positive?

      "default after invalid KICKS_LIVENESS_TICK=#{raw.inspect}"
    rescue ArgumentError, TypeError
      "default after invalid KICKS_LIVENESS_TICK=#{raw.inspect}"
    end

    def positive_number?(value)
      value.is_a?(Numeric) && value.positive?
    end
  end
end
