module KicksLiveness
  # The liveness mark on the filesystem: written by the worker, read by the
  # probe.
  #
  # The directory must live on tmpfs — in Kubernetes, an emptyDir with
  # <tt>medium: Memory</tt>. Put it on a real disk and the probe starts
  # depending on the disk again, and a stalling disk is one of the most common
  # causes of false restarts.
  #
  # This file deliberately runs no +require+ on the probe's path and refers to
  # nothing else in the gem: the probe can load it alone, with no application
  # code and no Rails behind it. That keeps the optional direct form at ~43 ms
  # and lets it run on a bare interpreter with +--disable-gems+ when the image
  # allows it -- whether Bundler is in the picture depends on where the image
  # put its gems, not on this file. The one +require+ it does contain is lazy,
  # in a branch only the worker reaches.
  #
  # @see file:docs/DESIGN.md#why-the-heartbeat-file-has-no-require-of-its-own
  class Heartbeat
    # @return [String] marks directory used when the environment says nothing
    DEFAULT_DIR = '/opt/app/tmp/health'.freeze
    # @return [Integer] seconds after which a mark is stale, by default
    DEFAULT_MAX_AGE = 45

    # @return [Hash{Symbol => String}] setting name to environment variable
    ENV_NAMES = {
      dir: 'KICKS_LIVENESS_DIR',
      max_age: 'KICKS_LIVENESS_MAX_AGE',
      tick: 'KICKS_LIVENESS_TICK'
    }.freeze

    # An empty string counts as unset: in a ConfigMap that is what you get by
    # declaring a key and leaving it blank.
    #
    # @param key [Symbol] one of the keys of {ENV_NAMES}
    # @return [String, nil]
    def self.env_raw(key)
      value = ENV.fetch(ENV_NAMES.fetch(key), nil)
      value unless value.nil? || value.empty?
    end

    # Values arrive from a ConfigMap, and a typo there is no reason to bring a
    # worker down — garbage falls back to the default.
    #
    # Both settings are durations, so a value has to be parseable *and*
    # positive. Zero and negative numbers parse perfectly well and are the more
    # dangerous half: a tick of zero turns the monitor into a hot loop, a
    # negative one used to kill the monitor thread on its first sleep, and a
    # negative max_age makes every mark stale on arrival, so the probe can never
    # pass again.
    #
    # @param key [Symbol] one of the keys of {ENV_NAMES}
    # @param default [Integer]
    # @return [Integer] the value from the environment when it is a positive
    #   integer, the default otherwise
    def self.env_int(key, default)
      value = Integer(env_raw(key) || default)
      value.positive? ? value : default
    rescue ArgumentError, TypeError
      default
    end

    # @return [String] marks directory
    def self.env_dir
      env_raw(:dir) || DEFAULT_DIR
    end

    # @return [Integer] seconds after which a mark is considered stale
    def self.env_max_age
      env_int(:max_age, DEFAULT_MAX_AGE)
    end

    # @param dir [String] marks directory
    # @param max_age [Integer] seconds after which a mark is considered stale
    def initialize(dir: Heartbeat.env_dir, max_age: Heartbeat.env_max_age)
      @dir = dir
      @max_age = max_age
    end

    attr_reader :dir, :max_age

    # Records how many forks the probe must wait for. Every fork writes the same
    # value. Without it the probe would pass as soon as any single mark was
    # fresh, while half the workers had not subscribed yet.
    #
    # Written through a rename, because a plain write truncates first: a probe
    # reading in that window finds the file empty and reports that the worker
    # has not started. The window is real and recurring — every fork rewrites
    # this file on every tick, while the liveness probe reads it on a schedule
    # of its own. Rename is atomic on tmpfs.
    #
    # @param processes [Integer]
    # @return [void]
    def declare!(processes)
      make_dir
      # The pid keeps concurrent forks from sharing the temporary file.
      tmp = "#{expected_path}.#{Process.pid}"
      File.write(tmp, processes)
      File.rename(tmp, expected_path)
    end

    # Refreshes this fork's mark.
    #
    # The file is named by supervisor slot, not by PID: a fork killed with
    # SIGKILL is respawned into the same slot and overwrites its own file. With a
    # PID in the name that file would stay stale forever and the probe would fail
    # permanently.
    #
    # The contents exist only for a human running <tt>kubectl exec ... cat</tt>;
    # the probe decides on mtime alone.
    #
    # @param slot [Integer] supervisor slot of this fork
    # @return [Integer] bytes written
    def touch!(slot)
      make_dir
      File.write(slot_path(slot), "#{Time.now.utc.strftime('%FT%TZ')} pid=#{Process.pid} slot=#{slot}\n")
    end

    # The probe side: is every declared fork's mark present and fresh?
    #
    # The returned message names slots the way the files are named, so that a
    # human reading the Unhealthy event knows which file to look at.
    #
    # @param now [Time] injected in specs
    # @return [Array(Boolean, String)] health, and the reason to print on stdout
    def check(now: Time.now.utc)
      processes = expected
      return [false, "no #{expected_path}: worker has not started yet"] unless processes&.positive?

      problems = (0...processes).filter_map do |slot|
        age = age_of(slot_path(slot), now)
        next "worker-#{slot} missing" if age.nil?

        "worker-#{slot} stale #{age.round}s > #{@max_age}s" if age > @max_age
      end

      problems.empty? ? [true, "#{processes} process(es) healthy"] : [false, problems.join('; ')]
    end

    private

    # One syscall on the happy path, and whichever fork gets there first wins.
    #
    # +Dir.mkdir+ creates a single level and raises ENOENT when the parent is
    # missing, which any nested KICKS_LIVENESS_DIR hits. FileUtils is required
    # here rather than at the top of the file: only the worker ever creates the
    # directory, and the probe's path through {#check} must stay free of
    # requires.
    def make_dir
      Dir.mkdir(@dir)
    rescue Errno::EEXIST
      nil
    rescue Errno::ENOENT
      require 'fileutils'
      FileUtils.mkdir_p(@dir)
    end

    def expected_path
      File.join(@dir, 'expected')
    end

    def slot_path(slot)
      File.join(@dir, "worker-#{slot}")
    end

    def expected
      Integer(File.read(expected_path))
    rescue StandardError
      nil
    end

    def age_of(path, now)
      now - File.mtime(path)
    rescue StandardError
      nil
    end
  end
end
