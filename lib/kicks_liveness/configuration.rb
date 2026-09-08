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

    # @return [Integer] seconds between checks
    attr_reader :tick
    # @return [Integer] unhealthy ticks tolerated at startup before one ERROR
    attr_accessor :startup_grace_ticks
    # @return [Logger, nil] explicit logger; defaults to +Sneakers.logger+
    attr_accessor :logger
    # @param value [Boolean] set false to start no monitor thread, e.g. in tests
    attr_writer :enabled

    def initialize
      @tick = Heartbeat.env_int(:tick, DEFAULT_TICK)
      @startup_grace_ticks = DEFAULT_STARTUP_GRACE_TICKS
      @enabled = true
      @logger = nil
    end

    # @return [Boolean]
    def enabled?
      @enabled
    end

    # A tick is what the monitor thread sleeps on, so a non-positive value is
    # not a setting but a broken monitor. The environment gets a silent fallback
    # instead (see {Heartbeat.env_int}) because a ConfigMap typo must not bring
    # a worker down; an initializer is code, and code should say so at boot,
    # where the developer is looking.
    #
    # @param seconds [Integer]
    # @raise [ArgumentError] if not a positive number
    # @return [Integer]
    def tick=(seconds)
      raise ArgumentError, "tick must be a positive number, got #{seconds.inspect}" unless positive_number?(seconds)

      @tick = seconds
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

    def positive_number?(value)
      value.is_a?(Numeric) && value.positive?
    end
  end
end
