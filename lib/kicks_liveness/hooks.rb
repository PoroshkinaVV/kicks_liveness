module KicksLiveness
  # The two modules prepended into the worker gem. Installed together by
  # {KicksLiveness.install!}.
  #
  # @see file:docs/DESIGN.md#where-the-hooks-attach
  # @api private
  module Hooks
    # Prepended to +Sneakers::Worker+. The worker is registered only after a
    # successful subscribe: if +subscribe+ raised, it never reaches the registry
    # and the probe honestly fails.
    # @api private
    module Worker
      # @return [void]
      def run
        super
        Registry.add(self)
      end

      # @return [void]
      def stop
        Registry.remove(self)
        super
      end
    end

    # Prepended to +Sneakers::WorkerGroup+.
    #
    # ServerEngine extends each worker instance with WorkerGroup. A prepend to
    # the module still intercepts that singleton-class chain; worker_id and
    # config come from ServerEngine::Worker.
    #
    # @see file:docs/DESIGN.md#where-the-hooks-attach
    # @api private
    module WorkerGroup
      # Run after the application's after_fork restores inherited connections.
      # Resolving callable worker_classes earlier could run application code before
      # those connections are ready. Rescue startup errors so instrumentation
      # cannot prevent the worker itself from starting.
      #
      # @return [void]
      def after_fork
        super

        begin
          KicksLiveness.start!(
            slot: worker_id,
            processes: config[:workers] || 1,
            consumers: kicks_liveness_expected_consumers
          )
        rescue StandardError => e
          report_start_failure(e)
        end
      end

      # Set the flag before any worker unsubscribes or starts draining, so the
      # monitor does not treat deliberate removal as a consumer failure.
      #
      # @return [void]
      def stop
        Registry.stopping!
        super
      end

      private

      def report_start_failure(error)
        KicksLiveness.config.resolved_logger&.error(
          "[liveness] failed to start: #{error.class}: #{error.message}"
        )
      rescue StandardError
        # This is already the failure path. Neither resolving the configuration
        # again nor a broken logger may let liveness instrumentation stop the
        # worker process it is meant to observe.
        nil
      end

      # Use the worker gem's own set: an array for sneakers:run, a callable registry
      # for sneakers:active_job. This must run after the application's after_fork.
      def kicks_liveness_expected_consumers
        classes = config[:worker_classes]
        classes = classes.call if classes.respond_to?(:call)
        classes.size
      end
    end
  end
end
