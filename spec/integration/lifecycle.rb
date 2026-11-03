# Invoked by verify.sh after its context and namespace ownership checks.
# rubocop:disable Metrics/AbcSize, RSpec/Output -- Executable integration recipes, not RSpec examples.
require 'json'
require 'open3'
require 'timeout'
require_relative '../../lib/kicks_liveness/version'

class Lifecycle # rubocop:disable Metrics/ClassLength -- One disposable fixture and its recovery paths.
  def initialize(context, namespace)
    @prefix = ['kubectl', '--context', context, '--namespace', namespace, '--request-timeout=15s']
  end

  def run(scenario)
    owner = object('namespace', @prefix[4]).dig('metadata', 'labels', 'app.kubernetes.io/managed-by')
    raise 'namespace is not owned by this fixture' unless owner == 'kicks-liveness-fixture'

    @original = object('deployment', 'worker').fetch('spec')
    raise 'lifecycle scenarios require exactly one worker replica' unless @original['replicas'] == 1

    configure_worker
    public_send(scenario.tr('-', '_'))
  ensure
    if @original
      patch_spec(@original)
      kube('rollout', 'status', 'deploy/worker', '--timeout=120s')
      puts 'restored: original worker deployment'
    end
  end

  def shutdown
    ordinary_drain
    stuck_drain
  end

  def container_restart
    pod = worker_pod
    before = container_state(pod)
    generation = exec(pod, 'cat', '/opt/app/tmp/health/generation')
    exec(pod, 'touch', '/opt/app/tmp/lifecycle-witness')
    # Leave diagnostic state from an unhealthy run, without waiting a grace window.
    exec(pod, 'bundle', 'exec', 'ruby', '-rkicks_liveness', '-e',
         'a = KicksLiveness::Attempts.new(KicksLiveness.config.dir, generation: KicksLiveness::Heartbeat.topology.generation); ' \
         '3.times { a.record!(0) }')
    # The exec client may be killed with its namespace before it returns zero.
    _, status = command('exec', pod, '--', 'ruby', '-e', 'Process.kill("WINCH", 1)', checked: false)
    assert([0, 137].include?(status), "signal delivery failed: exit=#{status}")
    wait_until('container restart', 90) { container_state(pod).fetch('restartCount') > before.fetch('restartCount') }
    kube('wait', '--for=condition=Ready', "pod/#{pod}", '--timeout=90s')
    after = container_state(pod)
    assert(after.dig('lastState', 'terminated', 'exitCode') == 137, 'PID 1 did not exit through the fixture handler')
    assert(exec(pod, 'cat', '/opt/app/tmp/health/generation') != generation, 'generation did not change')
    exec(pod, 'test', '-e', '/opt/app/tmp/lifecycle-witness')
    logs = kube('logs', pod)
    assert(logs.scan('[liveness] slot 0: started:').size == 1, 'replacement did not report its own first start')
    assert(!logs.match?(/\[liveness\].*over \d+ starts/), 'replacement counted inherited attempts')
    assert(probe(pod).last.zero?, 'replacement probe did not recover')
    puts "container-restart: same pod=#{pod} restartCount=#{before['restartCount']}->#{after['restartCount']} exit=137"
    puts 'container-restart: generation changed; inherited attempts did not suppress started; probe exit=0'
  end

  private

  def command(*args, checked: true)
    out, err, status = Open3.capture3(*@prefix, *args)
    raise "kubectl #{args.join(' ')}: #{err}#{out}" if checked && !status.success?

    [out, status.exitstatus]
  end

  def kube(*args, **options)
    command(*args, **options).first
  end

  def object(kind, name)
    JSON.parse(kube('get', kind, name, '-o', 'json'))
  end

  def exec(pod, *args)
    kube('exec', pod, '--', *args)
  end

  def probe(pod)
    command('exec', pod, '--', 'bundle', 'exec', 'kicks-liveness', checked: false)
  end

  def assert(condition, message)
    raise message unless condition
  end

  def wait_until(label, seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      return if yield
      raise "timed out waiting for #{label}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.5
    end
  end

  def worker_pod
    items = JSON.parse(kube('get', 'pods', '-l', 'app=worker', '-o', 'json')).fetch('items')
    items.find { |pod| !pod.dig('metadata', 'deletionTimestamp') }.fetch('metadata').fetch('name')
  end

  def container_state(pod)
    object('pod', pod).fetch('status').fetch('containerStatuses').find { |state| state['name'] == 'worker' }
  end

  def patch_spec(spec)
    kube('patch', 'deploy/worker', '--type=json', '-p', JSON.generate([{ op: 'replace', path: '/spec', value: spec }]))
  end

  def configure_worker
    spec = Marshal.load(Marshal.dump(@original))
    pod = spec.fetch('template').fetch('spec')
    pod['terminationGracePeriodSeconds'] = 10
    worker = pod.fetch('containers').find { |container| container['name'] == 'worker' }
    env = worker.fetch('env').reject { |entry| entry['name'].start_with?('KICKS_LIVENESS_') || entry['name'] == 'WORKER_COUNT' }
    { 'WORKER_COUNT' => '1', 'KICKS_LIVENESS_TICK' => '1', 'KICKS_LIVENESS_MAX_AGE' => '3',
      'KICKS_LIVENESS_SHUTDOWN_GRACE' => '10' }.each { |name, value| env << { 'name' => name, 'value' => value } }
    worker['env'] = env
    %w[startupProbe livenessProbe].each { |name| worker.fetch(name)['periodSeconds'] = 1 }
    worker.fetch('livenessProbe')['failureThreshold'] = 2
    patch_spec(spec)
    kube('rollout', 'status', 'deploy/worker', '--timeout=120s')
    # Rollout completion does not mean the old consumer has finished draining.
    wait_until('old worker pods to disappear', 90) do
      JSON.parse(kube('get', 'pods', '-l', 'app=worker', '-o', 'json')).fetch('items').size == 1
    end
    version = exec(worker_pod, 'bundle', 'exec', 'ruby', '-rkicks_liveness', '-e', 'print KicksLiveness::VERSION')
    expected = KicksLiveness::VERSION
    assert(version == expected, "fixture runs #{version}, not the #{expected} source under test")
    puts 'fixture: tick=1s max_age=3s shutdown_grace=10s terminationGracePeriodSeconds=10'
  end

  def publish(pod, message)
    exec(pod, 'bundle', 'exec', 'ruby', '-rbunny', '-e',
         'c = Bunny.new(ENV.fetch("AMQP_URL")).start; ' \
         'c.create_channel.default_exchange.publish(ARGV.fetch(0), routing_key: "kicks_liveness.alpha"); c.close', message)
    wait_until("#{message} delivery", 30) { kube('logs', pod).include?("[alpha] #{message}") }
  end

  def capture_logs(pod)
    input, output, errors, process = Open3.popen3(*@prefix, 'logs', '-f', pod, '--request-timeout=0')
    input.close
    reader = Thread.new { output.read }
    error_reader = Thread.new { errors.read }
    yield
    Timeout.timeout(15) { process.value }
    reader.value
  ensure
    Process.kill('TERM', process.pid) if process&.alive?
    reader&.join(5)
    error_reader&.join(5)
    output&.close
    errors&.close
  end

  # Hold the job until the old pod is draining: SIGTERM arrives only after the
  # replacement is Ready, which can take longer than any fixed job duration.
  def ordinary_drain
    pod = worker_pod
    exec(pod, 'rm', '-f', '/opt/app/tmp/release-drain')
    publish(pod, 'block-drain')
    logs = capture_logs(pod) do
      kube('rollout', 'restart', 'deploy/worker')
      wait_until('rollout shutdown tick', 120) { kube('logs', pod).include?('shutting down: consumers are no longer checked') }
      exec(pod, 'touch', '/opt/app/tmp/release-drain')
      kube('rollout', 'status', 'deploy/worker', '--timeout=120s')
    end
    assert(logs.include?('[alpha] block-drain released'), 'rollout interrupted the in-flight job')
    assert(logs.include?('shutting down: consumers are no longer checked'), 'rollout never exercised a draining tick')
    assert(!logs.match?(/ERROR.*\[liveness\]/), 'ordinary drain emitted a liveness ERROR')
    assert(probe(worker_pod).last.zero?, 'rollout replacement is unhealthy')
    puts 'ordinary-drain: in-flight job completed; shutdown tick observed; no liveness ERROR; replacement probe exit=0'
  ensure
    release_drains
  end

  # A failed run can leave the held message unacknowledged, and the broker then
  # redelivers it to the replacement pod, whose emptyDir has no release file.
  def release_drains
    JSON.parse(kube('get', 'pods', '-l', 'app=worker', '-o', 'json')).fetch('items').each do |item|
      command('exec', item.dig('metadata', 'name'), '--', 'touch', '/opt/app/tmp/release-drain', checked: false)
    end
  end

  def mark_time(pod)
    exec(pod, 'stat', '-c', '%Y', '/opt/app/tmp/health/worker-0').strip
  end

  def stuck_drain
    pod = worker_pod
    before = container_state(pod).fetch('restartCount')
    exec(pod, 'rm', '-f', '/opt/app/tmp/release-drain')
    publish(pod, 'block-drain')
    exec(pod, 'ruby', '-e', 'Process.kill("TERM", 1)')
    wait_until('shutdown callback', 20) { kube('logs', pod).include?('shutting down: consumers are no longer checked') }
    # Alpha has unsubscribed and is stuck in the real pool drain. Remove the
    # idle beta consumer as well, proving the probe is temporarily green at zero.
    kube('exec', 'deploy/rabbitmq', '--', 'rabbitmqctl', 'delete_queue', 'kicks_liveness.beta')
    queues = kube('exec', 'deploy/rabbitmq', '--', 'rabbitmqctl', '-q', 'list_queues', 'name', 'consumers')
    queues = queues.lines.select { |line| line.start_with?('kicks_liveness.') }
    assert(!queues.empty? && queues.all? { |line| line.split.last == '0' }, "consumers remain: #{queues}")
    assert(probe(pod).last.zero?, 'probe did not retain the bounded drain exemption')
    wait_until('shutdown expiry', 20) { kube('logs', pod).include?('shutdown grace expired: heartbeat is no longer refreshed') }
    original_mark = mark_time(pod)
    wait_until('stale shutdown mark', 10) { probe(pod).first.start_with?('worker-0 stale ') }
    assert(mark_time(pod) == original_mark, 'monitor refreshed the expired mark')
    logs = kube('logs', pod)
    assert(logs.scan('shutdown grace expired: heartbeat is no longer refreshed').size == 1, 'expiry ERROR was not one-shot')
    puts 'stuck-drain: zero consumers; probe initially exit=0; one expiry ERROR; unchanged mark; stale probe exit=1'
    recover_stuck_drain(pod, before)
  ensure
    command('exec', pod, '--', 'touch', '/opt/app/tmp/release-drain', checked: false) if pod
  end

  def recover_stuck_drain(pod, before)
    wait_until('kubelet restart after shutdown expiry', 90) do
      state = container_state(pod)
      state.fetch('restartCount') > before && state.dig('state', 'running')
    end
    exec(pod, 'touch', '/opt/app/tmp/release-drain')
    kube('wait', '--for=condition=Ready', "pod/#{pod}", '--timeout=90s')
    assert(probe(pod).last.zero?, 'restart did not recover the probe')
    queues = kube('exec', 'deploy/rabbitmq', '--', 'rabbitmqctl', '-q', 'list_queues', 'name', 'consumers')
    assert(queues.lines.count { |line| line.split.last == '1' } == 2, 'replacement did not restore both consumers')
    puts "stuck-drain: kubelet restartCount=#{before}->#{container_state(pod)['restartCount']}; both consumers restored"
  end
end

scenario, context, namespace = ARGV
unless %w[shutdown container-restart].include?(scenario) && context && namespace
  abort 'usage: lifecycle.rb {shutdown|container-restart} CONTEXT NAMESPACE'
end
Lifecycle.new(context, namespace).run(scenario)
# rubocop:enable Metrics/AbcSize, RSpec/Output
