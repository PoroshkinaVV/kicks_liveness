module KicksLiveness
  # What a process can prove, from Linux procfs, about the container incarnation
  # it runs in — and about the PID topology that identification depends on.
  #
  # The worker and its exec probes each answer this for themselves, and the two
  # may legitimately differ: procfs access is per-process and their credentials
  # need not match. The answer is therefore a result carrying a state rather
  # than a string or +nil+, so that "proven unsafe", "could not be verified",
  # "could not be derived at all" and "not Linux, by design" stay distinct.
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
    # Five states, because collapsing any two of them loses information that
    # decides behaviour:
    #
    # +:verified+:: PID 1 shares this process's mount namespace, so the
    #   container owns it and the generation identifies this incarnation.
    # +:unsafe+:: PID 1 is in another mount namespace. That is
    #   <tt>shareProcessNamespace: true</tt> or <tt>hostPID: true</tt>: PID 1
    #   outlives a restart of the worker container, so no generation derived
    #   from it can be trusted. Proof, not suspicion — it fails closed.
    # +:unverifiable+:: the generation was derived, but PID 1's mount namespace
    #   could not be read, so the topology behind it is unknown. The 0.1.2
    #   guard is kept and the worker warns once.
    # +:unavailable+:: Linux, but procfs yielded no generation at all. Only the
    #   0.1.1 freshness check remains, and the worker warns once.
    # +:non_linux+:: not Linux. An intentional compatibility mode rather than a
    #   degradation, so it is silent.
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

      # @return [Boolean]
      def unverifiable? = @state == :unverifiable

      # @return [Boolean]
      def unavailable? = @state == :unavailable

      # @return [Boolean]
      def non_linux? = @state == :non_linux
    end

    class << self
      # Reads the three procfs entries the protocol needs, in the one order that
      # cannot be talked out of a rejection: an unsafe topology is decided before
      # anything is derived from PID 1, because in that topology PID 1 belongs to
      # the pod sandbox or the node and its start time means nothing here.
      #
      # @param linux [Boolean] injected in specs, where procfs is stubbed
      # @return [Result]
      def current(linux: RUBY_PLATFORM.include?('linux'))
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
        return [started_at, nil] if started_at

        [nil, "cannot parse #{PID1_STAT}"]
      rescue StandardError => e
        [nil, "cannot read #{PID1_STAT} (#{e.class})"]
      end

      # @param stat [String] the contents of /proc/1/stat
      # @return [String, nil]
      def start_time_field(stat)
        closing_parenthesis = stat.rindex(') ')
        return unless closing_parenthesis

        # After the command in parentheses, field 3 (`state`) is index 0. Process
        # start time is field 22, therefore index 19 in this tail.
        started_at = stat[(closing_parenthesis + 2)..].split[19]
        started_at if started_at && Integer(started_at).positive?
      rescue ArgumentError, TypeError
        nil
      end
    end
  end

  # The liveness marks on the filesystem: written by the worker, read by the
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

    # The probe's verdict for a PID topology in which the heartbeat cannot be
    # scoped to this container at all. One string, whoever proved it: the probe
    # from its own procfs, or the worker through the state it published.
    # @return [String]
    UNSUPPORTED_TOPOLOGY = 'unsupported PID topology: pod must not set shareProcessNamespace or hostPID'.freeze

    # @return [Hash{Symbol => String}] setting name to environment variable
    ENV_NAMES = {
      dir: 'KICKS_LIVENESS_DIR',
      max_age: 'KICKS_LIVENESS_MAX_AGE',
      tick: 'KICKS_LIVENESS_TICK'
    }.freeze

    # Linux exposes a stable identifier shared by a private-PID container and
    # its exec probes. A restarted container gets a new identifier even though
    # its Kubernetes emptyDir survives.
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
    # @return [ContainerGeneration::Result] what this process proved about its incarnation
    attr_reader :topology
    # @return [String, nil] the container incarnation, when there is one to use
    attr_reader :generation

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
    # @return [Integer] bytes written
    def declare!(processes)
      return reject_topology! if @topology.unsafe?

      make_dir
      atomic_write(generation_path, @generation) if @generation
      atomic_write(expected_path, processes)
    end

    # Refreshes this fork's mark.
    #
    # The file is named by supervisor slot, not by PID: a fork killed with
    # SIGKILL is respawned into the same slot and overwrites its own file. With a
    # PID in the name that file would stay stale forever and the probe would fail
    # permanently.
    #
    # The timestamp, pid and slot exist for a human running
    # <tt>kubectl exec ... cat</tt>. The generation is also checked by the probe:
    # a Kubernetes emptyDir survives a container restart, so freshness alone
    # cannot distinguish this process from the one that just exited.
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
    # Omitting the marks would not be enough on its own: a generation file and a
    # fresh slot mark inherited from a previous container may still be lying in
    # the volume, and this container cannot tell them apart from its own. So the
    # state is published rather than implied, it is published before any normal
    # write could race it, and nothing ever removes it — the two settings that
    # cause it cannot be changed on a live pod, and the emptyDir dies with that
    # pod.
    #
    # @return [Integer] bytes written
    def reject_topology!
      make_dir
      atomic_write(topology_path, "#{[UNSUPPORTED_TOPOLOGY, @topology.detail].compact.join("\n")}\n")
    end

    # The probe side: is every declared fork's mark present and fresh?
    #
    # The returned message names slots the way the files are named, so that a
    # human reading the Unhealthy event knows which file to look at.
    #
    # Proof of an unsupported topology comes first, from either participant and
    # before anything is read from the marks: the worker's published state, then
    # this process's own procfs. Neither an inherited mark nor a weaker local
    # result can talk the probe out of it.
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
