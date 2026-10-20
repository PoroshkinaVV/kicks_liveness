module KicksLiveness
  # Identifies the container generation and PID topology from Linux procfs,
  # independently in the worker and each exec probe.
  #
  # @see file:docs/LIMITATIONS.md#container-generations-need-linux-procfs-and-a-private-pid-namespace
  # @api private
  module ContainerGeneration
    # @return [String] this process's mount namespace link
    SELF_NAMESPACE = '/proc/self/ns/mnt'.freeze
    # @return [String] PID 1's mount namespace link
    PID1_NAMESPACE = '/proc/1/ns/mnt'.freeze
    # @return [String] PID 1's status line, which carries its start time
    PID1_STAT = '/proc/1/stat'.freeze

    # One procfs inspection, as a value.
    #
    # +:verified+:: matching mount namespaces, with a generation.
    # +:unsafe+:: different mount namespaces; no trustworthy generation.
    # +:unverifiable+:: a generation, but PID 1's namespace could not be read.
    # +:unavailable+:: Linux procfs yielded no generation.
    # +:non_linux+:: another operating system.
    #
    # @api private
    class Result
      class << self
        # @param generation [String]
        # @return [Result]
        def verified(generation) = new(:verified, generation: generation)

        # @param detail [String] which namespaces differ
        # @return [Result]
        def unsafe(detail) = new(:unsafe, detail: detail)

        # @param generation [String]
        # @param detail [String] what could not be read
        # @return [Result]
        def unverifiable(generation, detail) = new(:unverifiable, generation: generation, detail: detail)

        # @param detail [String] what could not be read
        # @return [Result]
        def unavailable(detail) = new(:unavailable, detail: detail)

        # @return [Result]
        def non_linux = new(:non_linux)
      end

      # @return [Symbol] +:verified+, +:unsafe+, +:unverifiable+, +:unavailable+ or +:non_linux+
      attr_reader :state
      # @return [String, nil] the container incarnation, in the two states that have one
      attr_reader :generation
      # @return [String, nil] what could not be read, or which namespaces differ
      attr_reader :detail

      # @param state [Symbol]
      # @param generation [String, nil]
      # @param detail [String, nil]
      def initialize(state, generation: nil, detail: nil)
        @state = state
        @generation = generation
        @detail = detail
        freeze
      end

      # @return [Boolean]
      def verified? = @state == :verified

      # @return [Boolean]
      def unsafe? = @state == :unsafe
    end

    class << self
      # Reads the three procfs entries the protocol needs, in the one order that
      # cannot be talked out of a rejection: an unsafe topology is decided before
      # anything is derived from PID 1, because in that topology PID 1 belongs to
      # the pod sandbox or the node and its start time means nothing here.
      #
      # @param linux [Boolean] injected in specs, where procfs is stubbed
      # @return [Result]
      def current(linux: linux?)
        return Result.non_linux unless linux

        mine, mine_error = read_link(SELF_NAMESPACE)
        pid1, pid1_error = read_link(PID1_NAMESPACE)
        return Result.unsafe("PID 1 is in #{pid1}, this process in #{mine}") if another_namespace?(mine, pid1)

        started_at, stat_error = pid1_started_at
        return Result.unavailable(mine_error || stat_error) unless mine && started_at

        generation = "#{mine}:#{started_at}"
        pid1 ? Result.verified(generation) : Result.unverifiable(generation, pid1_error)
      end

      private

      # Missing procfs does not identify the OS. JRuby reports "java", so use
      # its predefined RbConfig to identify the host. CRuby on Linux answers
      # first, including under --disable-gems where RbConfig may be undefined.
      # https://bugs.ruby-lang.org/issues/8090
      def linux?
        return true if RUBY_PLATFORM.include?('linux')
        return false unless defined?(RbConfig)

        RbConfig::CONFIG['host_os'].to_s.include?('linux')
      end

      # Only a comparison both sides of which were read can prove anything.
      # @param mine [String, nil] this process's mount namespace
      # @param pid1 [String, nil] PID 1's mount namespace
      # @return [Boolean]
      def another_namespace?(mine, pid1)
        !mine.nil? && !pid1.nil? && mine != pid1
      end

      # @param path [String] a procfs namespace link
      # @return [Array(String, nil), Array(nil, String)] the link target, or why it could not be read
      def read_link(path)
        [File.readlink(path), nil]
      rescue StandardError => e
        [nil, "cannot read #{path} (#{e.class})"]
      end

      # @return [Array(String, nil), Array(nil, String)] PID 1's start time, or why it is missing
      def pid1_started_at
        started_at = start_time_field(File.read(PID1_STAT))
        return [started_at.to_s, nil] if started_at&.positive?
        return [nil, 'PID 1 start time is zero; possible hostPID or virtualized procfs'] if started_at&.zero?

        [nil, "cannot parse #{PID1_STAT}"]
      rescue StandardError => e
        [nil, "cannot read #{PID1_STAT} (#{e.class})"]
      end

      # @param stat [String] the contents of /proc/1/stat
      # @return [Integer, nil]
      def start_time_field(stat)
        closing_parenthesis = stat.rindex(') ')
        return unless closing_parenthesis

        # After the command in parentheses, field 3 (`state`) is index 0. Process
        # start time is field 22, therefore index 19 in this tail.
        started_at = stat[(closing_parenthesis + 2)..].split[19]
        Integer(started_at) if started_at
      rescue ArgumentError, TypeError
        nil
      end
    end
  end

  # Filesystem contract shared by the worker and probe. The marks directory
  # must be on tmpfs (an emptyDir with medium: Memory in Kubernetes).
  #
  # The probe loads this file alone, including under --disable-gems. Keep its
  # read path free of requires and references to other gem code; fileutils is
  # loaded lazily only when the worker needs to create parent directories.
  #
  # @see file:docs/DESIGN.md#why-the-heartbeat-file-has-no-require-of-its-own
  class Heartbeat
    # @return [String] marks directory used when the environment says nothing
    DEFAULT_DIR = '/opt/app/tmp/health'.freeze
    # @return [Integer] seconds after which a mark is stale, by default
    DEFAULT_MAX_AGE = 45

    # Shared verdict for unsafe topology evidence from either participant.
    # @return [String]
    UNSUPPORTED_TOPOLOGY = 'unsupported PID topology: pod must not set shareProcessNamespace or hostPID'.freeze

    # @return [Hash{Symbol => String}] setting name to environment variable
    ENV_NAMES = {
      dir: 'KICKS_LIVENESS_DIR',
      max_age: 'KICKS_LIVENESS_MAX_AGE',
      tick: 'KICKS_LIVENESS_TICK',
      shutdown_grace: 'KICKS_LIVENESS_SHUTDOWN_GRACE'
    }.freeze

    # Inspects this process's container generation and PID topology.
    # @return [ContainerGeneration::Result] what this process can prove about
    #   its own incarnation
    # @api private
    def self.topology
      ContainerGeneration.current
    end

    # An empty string counts as unset: in a ConfigMap that is what you get by
    # declaring a key and leaving it blank.
    #
    # @param key [Symbol] one of the keys of {ENV_NAMES}
    # @return [String, nil]
    def self.env_raw(key)
      value = ENV.fetch(ENV_NAMES.fetch(key), nil)
      value unless value.nil? || value.empty?
    end

    # Environment durations require positive integers. Invalid input falls
    # back to the default; accepting zero or negatives can stop the monitor
    # or make healthy marks stale immediately.
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
    # @param topology [ContainerGeneration::Result] what this process proved
    #   about its incarnation; injected in specs
    def initialize(
      dir: Heartbeat.env_dir,
      max_age: Heartbeat.env_max_age,
      topology: Heartbeat.topology
    )
      @dir = dir
      @max_age = max_age
      @topology = topology
      @generation = topology.generation
    end

    # @return [String] marks directory
    attr_reader :dir
    # @return [Integer] seconds after which a mark is considered stale
    attr_reader :max_age
    # @return [ContainerGeneration::Result] what this process proved about its
    #   incarnation, and the incarnation itself where there is one
    attr_reader :topology

    # Declares how many fork marks the probe requires. Atomic publication
    # prevents a concurrent probe from reading a truncated count or generation.
    #
    # @param processes [Integer]
    # @return [Integer] bytes written
    def declare!(processes)
      return reject_topology! if @topology.unsafe?

      make_dir
      atomic_write(generation_path, @generation) if @generation
      atomic_write(expected_path, processes)
    end

    # Refreshes the supervisor slot, so a respawn replaces the old mark instead
    # of leaving a stale PID-named file. The probe checks generation and mtime;
    # the remaining contents are diagnostic.
    #
    # @param slot [Integer] supervisor slot of this fork
    # @return [Integer] bytes written
    def touch!(slot)
      return reject_topology! if @topology.unsafe?

      make_dir
      contents = "#{Time.now.utc.strftime('%FT%TZ')} pid=#{Process.pid} slot=#{slot}"
      contents = "#{contents} generation=#{@generation}" if @generation
      atomic_write(slot_path(slot), "#{contents}\n")
    end

    # Publishes the terminal fail-closed state for a proven unsafe topology,
    # instead of any mark.
    #
    # Explicit evidence is needed because inherited generation and slot marks
    # may still be fresh. It precedes normal writes and is never removed during
    # the marks volume's lifetime.
    #
    # @return [Integer, nil] bytes written, or nil when this process has not
    #   proven the topology unsafe and so has nothing to publish
    # @api private
    def reject_topology!
      return unless @topology.unsafe?

      make_dir
      atomic_write(topology_path, "#{[UNSUPPORTED_TOPOLOGY, @topology.detail].compact.join("\n")}\n")
    end

    # The probe side: is every declared fork's mark present and fresh?
    #
    # Published or local unsafe evidence takes precedence over every generation
    # and freshness check, including when this probe cannot verify the topology.
    #
    # @param now [Time] injected in specs
    # @return [Array(Boolean, String)] health, and the reason to print on stdout
    def check(now: Time.now.utc)
      return [false, UNSUPPORTED_TOPOLOGY] if unsupported_topology?

      processes = expected
      return [false, "no #{expected_path}: worker has not started yet"] unless processes&.positive?
      return [false, 'heartbeat belongs to a previous container: worker has not started yet'] unless current_generation?

      problems = (0...processes).filter_map { |slot| problem_for(slot, now) }

      problems.empty? ? [true, "#{processes} process(es) healthy"] : [false, problems.join('; ')]
    end

    private

    # Try one mkdir first; competing forks may already have created it.
    # Only missing parent directories need fileutils, loaded on the worker path.
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

    def generation_path
      File.join(@dir, 'generation')
    end

    def topology_path
      File.join(@dir, 'topology-unsafe')
    end

    # The worker's published proof first, then this process's own: either is
    # enough, and no weaker result from the other side can take it back.
    #
    # Existence is the whole signal, so this guard cannot be defeated by a
    # partial read and holds even where the file itself is not readable. Its
    # contents are there for a human running `cat`.
    def unsupported_topology?
      File.exist?(topology_path) || @topology.unsafe?
    end

    def expected
      Integer(File.read(expected_path))
    rescue StandardError
      nil
    end

    def declared_generation
      File.read(generation_path)
    rescue StandardError
      nil
    end

    def current_generation?
      !@generation || declared_generation == @generation
    end

    def previous_generation?(path)
      @generation && File.read(path)[/\bgeneration=(\S+)/, 1] != @generation
    end

    def problem_for(slot, now)
      path = slot_path(slot)
      age = age_of(path, now)
      return "worker-#{slot} missing" if age.nil?
      return "worker-#{slot} belongs to a previous container" if previous_generation?(path)

      "worker-#{slot} stale #{age.round}s > #{@max_age}s" if age > @max_age
    rescue StandardError
      "worker-#{slot} unreadable"
    end

    def atomic_write(path, contents)
      # The pid keeps concurrent forks from sharing the temporary file.
      tmp = "#{path}.#{Process.pid}"
      bytes = File.write(tmp, contents)
      File.rename(tmp, path)
      bytes
    end

    def age_of(path, now)
      now - File.mtime(path)
    rescue StandardError
      nil
    end
  end
end
