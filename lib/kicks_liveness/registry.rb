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
    @stopping = false

    class << self
      # Records a worker as subscribed.
      #
      # Registering the same object twice would break the size comparison in
      # {healthy?} and leave the process permanently unhealthy, so identity is
      # checked first. +equal?+ rather than +==+ on purpose: this is a registry
      # of objects, and a worker class is free to define equality however it
      # likes.
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

      # @return [Integer] how many workers are currently registered
      def size
        @mutex.synchronize { @workers.size }
      end

      # Records that this process is shutting down on purpose.
      #
      # Without it a graceful shutdown is indistinguishable from a failure: the
      # registry empties as each worker unsubscribes, so the monitor would see
      # an incomplete set and report a genuine fault on every deploy.
      #
      # @return [true]
      def stopping!
        @stopping = true
      end

      # @return [Boolean] whether shutdown has begun
      def stopping?
        @stopping
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
