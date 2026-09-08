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
    # +ServerEngine::Server#create_worker+ calls +w.extend(worker_module)+, so
    # +WorkerGroup+ lands in the singleton class of the instance rather than
    # being included in a class. A prepend to the module still sits ahead of it
    # in that lookup chain; +worker_id+ and +config+ come from
    # +ServerEngine::Worker+.
    #
    # @see file:docs/DESIGN.md#where-the-hooks-attach
    # @api private
    module WorkerGroup
      # Starts the monitor from +after_fork+ rather than from +run+.
      #
      # +Sneakers::WorkerGroup#run+ calls +after_fork+ as its very first
      # statement and only afterwards resolves +worker_classes+, so this is the
      # earliest point in the fork at which the application's own +after_fork+
      # hook has already run. That ordering matters because resolving the
      # expected consumer count may run application code: under
      # sneakers:active_job the set is a callable registry, and the standard use
      # of +after_fork+ is to re-establish the connections a fork inherited.
      # Resolving it first would run that code against a fork that is not ready.
      #
      # Wrapped in a rescue: instrumentation has no right to prevent a worker
      # from starting, so the worst outcome is a missing mark and a pod restart
      # rather than a pod that stays up with silent queues.
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
          KicksLiveness.config.resolved_logger&.error("[liveness] failed to start: #{e.class}: #{e.message}")
        end
      end

      # Marks the shutdown as deliberate before the workers unsubscribe.
      #
      # +Sneakers::WorkerGroup#stop+ calls +stop+ on each worker, and
      # +Sneakers::Worker#stop+ waits for the thread pool to drain, which takes
      # as long as the longest in-flight job. The registry empties at the start
      # of that, so without this flag the monitor would report a fault on every
      # ordinary deploy.
      #
      # @return [void]
      def stop
        Registry.stopping!
        super
      end

      private

      # The same set the worker gem itself builds its workers from, so the
      # queue list is never duplicated and cannot drift. An array of classes
      # under sneakers:run, a callable registry under sneakers:active_job.
      def kicks_liveness_expected_consumers
        classes = config[:worker_classes]
        classes = classes.call if classes.respond_to?(:call)
        classes.size
      end
    end
  end
end
