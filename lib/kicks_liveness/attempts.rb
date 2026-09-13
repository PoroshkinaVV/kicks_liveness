require 'fileutils'

module KicksLiveness
  # Counts starts of a supervisor slot that have not reached healthy yet.
  #
  # Deliberately separate from {Heartbeat}. Heartbeat is the contract shared
  # with the probe and is loaded by it alone, so nothing the probe does not need
  # belongs there — including the +fileutils+ this class requires freely.
  #
  # The count lives in the marks directory rather than in memory because a
  # respawn storm destroys process state every few hundred milliseconds: the
  # supervisor brings a failing fork back after +start_worker_delay+, and every
  # incarnation of the monitor believes it is the first. That is how an outage
  # can produce thousands of identical INFO lines and not one ERROR. The
  # directory is the only state that survives the fork.
  #
  # That directory outlives the container too, which is one restart too many:
  # the count is about a fork that keeps failing, not about a volume. So each
  # file carries the container generation, and a file from another generation
  # counts as no previous start at all. Where there is no generation to write —
  # off Linux, or where procfs did not yield one — the counter keeps its
  # generation-less behaviour rather than pretending to a scope it cannot
  # enforce.
  #
  # @see file:docs/DESIGN.md#logging-events-not-the-pulse
  # @api private
  class Attempts
    # @param dir [String] marks directory
    # @param generation [String, nil] container incarnation the count belongs to
    def initialize(dir, generation: nil)
      @dir = dir
      @generation = generation
    end

    # Records a start of this slot.
    #
    # @param slot [Integer] supervisor slot of this fork
    # @param now [Time] injected in specs
    # @return [Array(Integer, Float)] this start's number, and seconds since the
    #   first start of the current unhealthy run
    def record!(slot, now: Time.now.utc)
      count, first = read(slot)
      first ||= now
      write(slot, count + 1, first)
      [count + 1, now - first]
    end

    # Resets the elapsed-time window while keeping the count, so a respawn loop
    # reports once per window instead of once per respawn.
    #
    # @param slot [Integer]
    # @param now [Time]
    # @return [void]
    def restart_window!(slot, now: Time.now.utc)
      count, = read(slot)
      write(slot, count, now)
    end

    # Called once the slot is healthy: the next start of it is a fresh one.
    #
    # @param slot [Integer]
    # @return [void]
    def clear!(slot)
      File.unlink(path(slot))
    rescue StandardError
      nil
    end

    private

    def path(slot)
      File.join(@dir, "attempt-#{slot}")
    end

    # A missing or unreadable counter means "no previous start", never an
    # exception: this is instrumentation, and it may not break a worker. A
    # counter from another container means the same thing, so a replacement
    # container reports its own first start rather than continuing a run it did
    # not take part in.
    def read(slot)
      count, epoch, generation = File.read(path(slot)).split
      return [0, nil] unless same_generation?(generation)

      [Integer(count), Time.at(Integer(epoch)).utc]
    rescue StandardError
      [0, nil]
    end

    def same_generation?(declared)
      return true unless @generation

      declared == "generation=#{@generation}"
    end

    # Failing to write degrades the reporting back to one line per respawn,
    # which is noisy but harmless — so a read-only directory is swallowed here
    # rather than escalated.
    def write(slot, count, first)
      FileUtils.mkdir_p(@dir)
      contents = "#{count} #{first.to_i}"
      contents = "#{contents} generation=#{@generation}" if @generation
      tmp = "#{path(slot)}.#{Process.pid}"
      File.write(tmp, "#{contents}\n")
      File.rename(tmp, path(slot))
    rescue StandardError
      nil
    end
  end
end
