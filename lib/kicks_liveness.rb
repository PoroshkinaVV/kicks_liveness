require_relative 'kicks_liveness/version'
require_relative 'kicks_liveness/heartbeat'
require_relative 'kicks_liveness/attempts'
require_relative 'kicks_liveness/configuration'
require_relative 'kicks_liveness/registry'
require_relative 'kicks_liveness/monitor'
require_relative 'kicks_liveness/hooks'

# Liveness probe for Kicks and Sneakers workers, backed by a tmpfs heartbeat.
#
# The worker publishes a mark from inside its own process, checking its Bunny
# consumers in memory; the probe reads only the container generation and mark
# mtimes. No Rails, no call to the broker.
#
# @see file:docs/SETUP.md
# @see file:docs/DESIGN.md
module KicksLiveness
  class << self
    # @return [Configuration] the process-wide configuration
    def config
      @config ||= Configuration.new
    end

    # Yields the configuration for the application to adjust.
    #
    # @example
    #   KicksLiveness.configure do |config|
    #     config.enabled = !Rails.env.local?
    #   end
    #
    # @yieldparam config [Configuration]
    # @return [Configuration]
    def configure
      yield(config)
      config
    end

    # Installs the two hooks the gem works through. Must run before the runner
    # starts; in Rails a Railtie does it. Idempotent — prepending the same
    # module twice is a no-op.
    #
    # Two requires, not one: +Sneakers::Worker+ is defined by lib/sneakers.rb,
    # while +Sneakers::WorkerGroup+ comes only with sneakers/workergroup, which
    # ships with the runner and is absent in web processes. Relying on the
    # application having required sneakers itself is not safe: with
    # <tt>gem 'kicks', require: false</tt> the to_prepare hook runs earlier and
    # would fail on NameError.
    #
    # @raise [LoadError] if neither worker gem is available, or if both +kicks+
    #   and +sneakers+ are activated
    # @return [Module]
    # @see file:docs/SETUP.md#installing-the-hooks
    def install!
      reject_ambiguous_worker_gems!

      begin
        require 'sneakers'
        require 'sneakers/workergroup'
      rescue LoadError => e
        # The original message is kept: this rescue fires just as readily when
        # the worker gem is installed but something inside it fails to load — a
        # bunny or serverengine version that cannot be required, an extension
        # not built for the image. Reporting that as "the gem is missing" sends
        # the reader to check a Gemfile.lock that is perfectly fine.
        raise LoadError, 'kicks_liveness requires the kicks (>= 3.0) or sneakers (>= 2.11) gem ' \
                         "(#{e.message})"
      end

      ::Sneakers::Worker.prepend(Hooks::Worker)
      ::Sneakers::WorkerGroup.prepend(Hooks::WorkerGroup)
    end

    # Starts the monitor thread. Called from the WorkerGroup hook, already
    # inside the fork.
    #
    # @param slot [Integer] supervisor slot of this fork
    # @param processes [Integer] how many forks the probe must wait for
    # @param consumers [Integer] how many workers must subscribe here
    # @return [Thread, nil] nil when disabled by configuration
    # @api private
    def start!(slot:, processes:, consumers:)
      return unless config.enabled?

      Monitor.new(slot: slot, processes: processes, consumers: consumers, config: config).start!
    end

    private

    def reject_ambiguous_worker_gems!
      return unless defined?(Gem.loaded_specs)
      return unless Gem.loaded_specs.key?('kicks') && Gem.loaded_specs.key?('sneakers')

      raise LoadError, 'kicks_liveness cannot run with both kicks and sneakers activated; install exactly one'
    end
  end
end

require_relative 'kicks_liveness/railtie' if defined?(Rails::Railtie)
