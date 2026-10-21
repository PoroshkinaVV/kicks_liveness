require 'fileutils'

module KicksLiveness
  # Counts starts of a supervisor slot that have not reached healthy yet.
  #
  # Persistent state survives fork respawns; its generation separates container
  # incarnations when available. Kept outside {Heartbeat} because the probe does
  # not read these counters.
  #
  # @see file:docs/LIMITATIONS.md#a-respawn-loop-is-reported-once-per-grace-window-not-once-per-respawn
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

    # Missing, unreadable, or foreign-generation counts start a new run.
    # Counter failures must not prevent worker startup.
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
