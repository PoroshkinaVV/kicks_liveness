module KicksLiveness
  # Registry of the workers that have subscribed in the current process, and the
  # health predicate computed over them.
  #
  # The predicate reads only in-process state: no network calls, no disk access.
  # @see file:docs/DESIGN.md#the-health-predicate
  # @api private
  module Registry
    # Initialised at file-load time: single-threaded, and before any fork.
    @workers = []
    @mutex = Mutex.new
    @stopping_at = nil

    class << self
      # Records a worker as subscribed.
      #
      # Duplicate objects must not inflate the expected-count check. Use identity
      # rather than == because worker classes can override equality.
      #
      # @param worker [Sneakers::Worker]
      # @return [Array] the registry
      def add(worker)
        @mutex.synchronize do
          @workers << worker unless @workers.any? { |registered| registered.equal?(worker) }
          @workers
        end
      end

      # Drops a worker from the registry, on shutdown.
      # @param worker [Sneakers::Worker]
      # @return [Sneakers::Worker, nil]
      def remove(worker)
        @mutex.synchronize { @workers.delete(worker) }
      end

      # Mark deliberate shutdown before unsubscription changes the predicate.
      #
      # @return [true]
      def stopping! # rubocop:disable Naming/PredicateMethod -- Records the stop notification.
        @mutex.synchronize { @stopping_at ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        true
      end

      # @return [Boolean] whether shutdown has begun
      def stopping?
        !stopping_at.nil?
      end

      # Captured by the first stop callback, even if the monitor's next tick is
      # delayed. Repeated callbacks cannot extend the shutdown exemption. This
      # is process-local: a sibling replacement fork has not been asked to stop.
      #
      # @return [Float, nil] monotonic time of the first stop notification
      def stopping_at
        @mutex.synchronize { @stopping_at }
      end

      # Whether this process is consuming everything it is supposed to consume.
      #
      # The registry size is compared against +expected+ rather than only
      # checking the workers that did register: four healthy workers out of five
      # look fine one object at a time.
      #
      # @param expected [Integer] how many workers must have subscribed in this process
      # @return [Boolean]
      def healthy?(expected)
        workers = @mutex.synchronize { @workers.dup }
        return false unless expected.positive? && workers.size == expected

        workers.all? { |worker| alive?(worker) }
      end

      private

      def alive?(worker)
        channel = worker.queue.channel
        # No subscription yet; the startup probe is what holds the pod.
        return false if channel.nil?

        connection = channel.connection
        return true if recovering?(connection)

        # Connection open but no consumers: the worker silently stopped
        # consuming, and a restart is the only cure.
        channel.open? && connection.open? && channel.any_consumers?
      rescue StandardError
        false
      end

      # Bunny marks this method @private, so an upgrade may remove it. The
      # guard keeps that from turning every tick into NoMethodError -> rescued
      # -> unhealthy; the cost is that the recovery exemption would then vanish
      # silently.
      def recovering?(connection)
        connection.respond_to?(:recovering_from_network_failure?) &&
          connection.recovering_from_network_failure?
      end
    end
  end
end
