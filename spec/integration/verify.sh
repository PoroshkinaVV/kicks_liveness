#!/usr/bin/env bash
# Brings the integration environment up and down. Every kubectl call names the
# context and namespace explicitly, and destructive commands require the
# namespace to carry this fixture's ownership label.
set -euo pipefail

CONTEXT="${KICKS_LIVENESS_K8S_CONTEXT:-docker-desktop}"
NAMESPACE="${KICKS_LIVENESS_K8S_NAMESPACE:-kicks-liveness}"
WORKER_GEM="${AMQP_WORKER_GEM:-kicks}"
IMAGE=kicks-liveness-fixture:latest
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
K8S="$ROOT/spec/integration/k8s"
MANAGED_BY_LABEL=app.kubernetes.io/managed-by
MANAGED_BY_VALUE=kicks-liveness-fixture

# The image has to be built into the engine that backs the cluster. On a machine
# that also runs OrbStack or Colima the default docker context is not the one
# Docker Desktop uses, and an image built into the wrong engine fails with
# ErrImageNeverPull.
DOCKER_CONTEXT_NAME="${KICKS_LIVENESS_DOCKER_CONTEXT:-desktop-linux}"

kube() { kubectl --context "$CONTEXT" --namespace "$NAMESPACE" "$@"; }
dock() { docker --context "$DOCKER_CONTEXT_NAME" "$@"; }

require_image() {
  if ! dock image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "no image '$IMAGE' in Docker context '$DOCKER_CONTEXT_NAME': run '$0 build' first" >&2
    return 1
  fi
}


guard() {
  if ! kubectl config get-contexts -o name | grep -qx "$CONTEXT"; then
    echo "no kube context '$CONTEXT': enable Kubernetes in Docker Desktop first" >&2
    exit 1
  fi
}

namespace_exists() {
  kubectl --context "$CONTEXT" get namespace "$NAMESPACE" >/dev/null 2>&1
}

namespace_owner() {
  kubectl --context "$CONTEXT" get namespace "$NAMESPACE" \
    -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/managed-by}'
}

require_managed_namespace() {
  if ! namespace_exists; then
    echo "namespace '$NAMESPACE' does not exist in context '$CONTEXT'" >&2
    return 1
  fi

  local owner
  owner="$(namespace_owner)"
  if [[ "$owner" != "$MANAGED_BY_VALUE" ]]; then
    echo "refusing: namespace '$NAMESPACE' in context '$CONTEXT' is not owned by this fixture" >&2
    echo "expected label $MANAGED_BY_LABEL=$MANAGED_BY_VALUE, got ${owner:-<unset>}" >&2
    return 1
  fi
}

cmd_build() {
  dock build \
    --build-arg "AMQP_WORKER_GEM=$WORKER_GEM" \
    -f "$ROOT/spec/integration/fixture/Dockerfile" -t "$IMAGE" "$ROOT"
}

cmd_up() {
  guard
  local reuse_namespace=false
  if namespace_exists; then
    require_managed_namespace
    reuse_namespace=true
    echo "reusing managed namespace '$NAMESPACE' in context '$CONTEXT'"
  else
    kubectl --context "$CONTEXT" create namespace "$NAMESPACE"
    kubectl --context "$CONTEXT" label namespace "$NAMESPACE" \
      "$MANAGED_BY_LABEL=$MANAGED_BY_VALUE"
  fi

  kube apply -f "$K8S/rabbitmq.yaml"
  kube rollout status deploy/rabbitmq --timeout=300s
  kube apply -f "$K8S/worker.yaml"
  if "$reuse_namespace"; then
    # The image uses a local, mutable `latest` tag. Recreate the pod so a build
    # for the other worker gem cannot leave the previous image running.
    kube rollout restart deploy/worker
  fi
  kube rollout status deploy/worker --timeout=300s
  kube get pods -o wide
}

cmd_down() {
  guard
  if ! namespace_exists; then
    echo "namespace '$NAMESPACE' is already absent from context '$CONTEXT'"
    return
  fi

  require_managed_namespace
  kubectl --context "$CONTEXT" delete namespace "$NAMESPACE"
}

cmd_status() {
  guard
  echo "context=$CONTEXT namespace=$NAMESPACE docker_context=$DOCKER_CONTEXT_NAME"
  if ! namespace_exists; then
    echo 'namespace=absent'
    return
  fi

  require_managed_namespace
  echo "namespace=managed ($MANAGED_BY_LABEL=$MANAGED_BY_VALUE)"
  kube get deployments,pods -o wide
}

cmd_probe() {
  guard
  echo '--- standard: bundle exec kicks-liveness'
  kube exec deploy/worker -- sh -c 'bundle exec kicks-liveness; echo "exit=$?"'
  echo '--- optimised: plain ruby -e (needs the gems in GEM_HOME)'
  kube exec deploy/worker -- sh -c \
    'ruby -e "require %q(kicks_liveness/probe)"; echo "exit=$?"'
}

cleanup_generation_restart() {
  if [[ -n "${GENERATION_CONTAINER:-}" ]]; then
    dock rm --force "$GENERATION_CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ -n "${GENERATION_VOLUME:-}" ]]; then
    dock volume rm "$GENERATION_VOLUME" >/dev/null 2>&1 || true
  fi
}

generation_probe() {
  dock exec "$GENERATION_CONTAINER" ruby -e 'require %q(kicks_liveness/probe)'
}

wait_for_generation_probe() {
  local output
  for _ in {1..30}; do
    if output="$(generation_probe 2>&1)"; then
      printf '%s\n' "$output"
      return
    fi
    sleep 1
  done

  printf '%s\n' "$output" >&2
  return 1
}

cmd_generation_restart() {
  require_image

  GENERATION_CONTAINER="kicks-liveness-generation-$$"
  GENERATION_VOLUME="${GENERATION_CONTAINER}-state"
  trap cleanup_generation_restart EXIT

  dock volume create "$GENERATION_VOLUME" >/dev/null
  dock run --detach \
    --name "$GENERATION_CONTAINER" \
    --mount "source=$GENERATION_VOLUME,target=/opt/app/tmp" \
    "$IMAGE" sh -c '
      if [ -e /opt/app/tmp/generation-restart-seen ]; then
        sleep 15
      else
        touch /opt/app/tmp/generation-restart-seen
      fi
      ruby -r kicks_liveness/heartbeat -e \
        "heartbeat = KicksLiveness::Heartbeat.new; heartbeat.declare!(1); heartbeat.touch!(0)"
      exec sleep infinity
    ' >/dev/null

  wait_for_generation_probe >/dev/null
  local before_generation
  before_generation="$(dock exec "$GENERATION_CONTAINER" cat /opt/app/tmp/health/generation)"
  expect_state 'generation-restart' verified "$(topology_state "$GENERATION_CONTAINER")"

  dock restart --time 1 "$GENERATION_CONTAINER" >/dev/null

  local after_generation
  after_generation="$(dock exec "$GENERATION_CONTAINER" \
    ruby -r kicks_liveness/heartbeat -e 'print KicksLiveness::Heartbeat.topology.generation')"
  if [[ "$before_generation" == "$after_generation" ]]; then
    echo "container generation did not change: $before_generation" >&2
    return 1
  fi

  local inherited_output inherited_exit=0
  if inherited_output="$(generation_probe 2>&1)"; then
    inherited_exit=0
  else
    inherited_exit=$?
  fi
  if [[ "$inherited_exit" -ne 1 ]] || \
     [[ "$inherited_output" != 'heartbeat belongs to a previous container: worker has not started yet' ]]; then
    echo "inherited heartbeat unexpectedly returned exit=$inherited_exit: $inherited_output" >&2
    return 1
  fi

  local recovered_output
  recovered_output="$(wait_for_generation_probe)"
  printf 'before=%s\n' "$before_generation"
  printf 'after=%s\n' "$after_generation"
  printf 'inherited=%s\n' "$inherited_output"
  printf 'recovered=%s\n' "$recovered_output"
}

# The PID topology matrix. Docker only: no cluster and no broker, because every
# case here is about which PID namespace the worker container is in, which is
# the one thing the container generation depends on.
TOPOLOGY_MESSAGE='unsupported PID topology: pod must not set shareProcessNamespace or hostPID'
TOPOLOGY_RESOURCES=()

cleanup_topology() {
  local resource
  for resource in "${TOPOLOGY_RESOURCES[@]:-}"; do
    case "$resource" in
      container:*) dock rm --force "${resource#container:}" >/dev/null 2>&1 || true ;;
      volume:*) dock volume rm "${resource#volume:}" >/dev/null 2>&1 || true ;;
    esac
  done
}

# The 0.1.2 identifier, computed the way 0.1.2 computed it. The point of the two
# unsafe cases is that this value survives a restart of the worker container, so
# it has to come from the old rule rather than from the code under test.
LEGACY_GENERATION_RUBY='
  stat = File.read("/proc/1/stat")
  print "#{File.readlink("/proc/self/ns/mnt")}:#{stat[(stat.rindex(") ") + 2)..].split[19]}"
'

# A complete, fresh heartbeat in the 0.1.2 format: what a formerly healthy
# container leaves in the volume, and what a 0.1.2 probe accepts.
PUBLISH_LEGACY_RUBY='
  require "fileutils"
  stat = File.read("/proc/1/stat")
  generation = "#{File.readlink("/proc/self/ns/mnt")}:#{stat[(stat.rindex(") ") + 2)..].split[19]}"
  dir = ENV.fetch("KICKS_LIVENESS_DIR")
  FileUtils.mkdir_p(dir)
  File.write("#{dir}/generation", generation)
  File.write("#{dir}/expected", "1")
  File.write("#{dir}/worker-0", "#{Time.now.utc.strftime("%FT%TZ")} pid=1 slot=0 generation=#{generation}\n")
'

# Marks from a container that is not this one, in the current format.
PUBLISH_FOREIGN_RUBY='
  dir = ENV.fetch("KICKS_LIVENESS_DIR")
  File.write("#{dir}/generation", "mnt:[0]:1")
  File.write("#{dir}/expected", "1")
  File.write("#{dir}/worker-0", "#{Time.now.utc.strftime("%FT%TZ")} pid=1 slot=0 generation=mnt:[0]:1\n")
'

PUBLISH_RUBY='
  heartbeat = KicksLiveness::Heartbeat.new
  heartbeat.declare!(1)
  heartbeat.touch!(0)
'

# Three incarnations of the monitor, which is what a fork respawn produces: a
# brand-new object every few hundred milliseconds, with nothing in memory to
# remember what the previous one said.
RESPAWN_RUBY='
  require "kicks_liveness"
  require "logger"
  KicksLiveness.config.logger = Logger.new($stdout)
  3.times do
    KicksLiveness::Monitor.new(slot: 0, processes: 1, consumers: 1, config: KicksLiveness.config).start!&.kill
  end
'

legacy_generation() { dock exec "$@" ruby -e "$LEGACY_GENERATION_RUBY"; }
topology_state() { dock exec "$@" ruby -r kicks_liveness/heartbeat -e 'print KicksLiveness::Heartbeat.topology.state'; }

probe_in() {
  PROBE_STATUS=0
  PROBE_OUTPUT="$(dock exec "$@" ruby -e 'require %q(kicks_liveness/probe)' 2>&1)" || PROBE_STATUS=$?
}

expect_probe() {
  local label="$1" status="$2" output="$3"
  if [[ "$PROBE_STATUS" -ne "$status" || "$PROBE_OUTPUT" != "$output" ]]; then
    echo "$label: expected exit $status and '$output', got exit=$PROBE_STATUS '$PROBE_OUTPUT'" >&2
    return 1
  fi
  printf '%s: exit=%s %s\n' "$label" "$PROBE_STATUS" "$PROBE_OUTPUT"
}

expect_state() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "$label: expected topology '$expected', got '$actual'" >&2
    return 1
  fi
  printf '%s: topology=%s\n' "$label" "$actual"
}

# Kubernetes shareProcessNamespace and hostPID, as far as Docker can reproduce
# them: in both, PID 1 is outside the worker container and outlives its restart.
topology_unsafe_case() {
  local label="$1"
  shift

  local worker="kicks-liveness-$label-$$" volume="kicks-liveness-$label-$$-state"
  TOPOLOGY_RESOURCES+=("container:$worker" "volume:$volume")
  dock volume create "$volume" >/dev/null
  dock run --detach --name "$worker" "$@" \
    --mount "source=$volume,target=/opt/app/tmp" "$IMAGE" sleep infinity >/dev/null

  local state
  state="$(topology_state "$worker")"
  if [[ "$state" == unverifiable ]]; then
    echo "$label: this engine refuses the ptrace-level read of /proc/1/ns/mnt, so the topology can only be" >&2
    echo "$label: reported as unverifiable here. That is the documented weaker outcome, not a regression;" >&2
    echo "$label: the unverifiable case below is the one that covers it." >&2
  fi
  expect_state "$label" unsafe "$state"

  # What the previous container left behind, in the format 0.1.2 wrote.
  dock exec "$worker" ruby -e "$PUBLISH_LEGACY_RUBY"
  local before after
  before="$(legacy_generation "$worker")"
  dock restart --time 1 "$worker" >/dev/null
  after="$(legacy_generation "$worker")"
  printf '%s: 0.1.2 generation before=%s after=%s\n' "$label" "$before" "$after"
  if [[ "$before" != "$after" ]]; then
    echo "$label: the 0.1.2 generation did not repeat, so this run does not demonstrate the defect" >&2
    echo "$label: PID 1 start time is unchanged either way; the mount namespace inode was not reused" >&2
    return 1
  fi

  # The probe on its own, before any 0.1.3 worker has published anything here:
  # the marks are complete and fresh, and 0.1.2 would have accepted them.
  probe_in "$worker"
  expect_probe "$label inherited heartbeat" 1 "$TOPOLOGY_MESSAGE"

  # And the worker: the fail-closed state instead of marks of its own.
  dock exec "$worker" ruby -r kicks_liveness/heartbeat -e "$PUBLISH_RUBY"
  printf '%s: marks directory holds %s\n' "$label" \
    "$(dock exec "$worker" sh -c 'ls /opt/app/tmp/health | tr "\n" " "')"
  dock exec "$worker" test -f /opt/app/tmp/health/topology-unsafe
  probe_in "$worker"
  expect_probe "$label after the worker published" 1 "$TOPOLOGY_MESSAGE"
}

# The positive control: an ordinary container, owning PID 1.
topology_private_case() {
  local worker="kicks-liveness-private-pid-$$"
  TOPOLOGY_RESOURCES+=("container:$worker")
  dock run --detach --name "$worker" "$IMAGE" sleep infinity >/dev/null

  expect_state private-pid verified "$(topology_state "$worker")"
  dock exec "$worker" ruby -r kicks_liveness/heartbeat -e "$PUBLISH_RUBY"
  probe_in "$worker"
  expect_probe private-pid 0 '1 process(es) healthy'
}

# The second positive control: a private-PID container whose checker cannot read
# /proc/1/ns/mnt. The topology is then unverifiable rather than proven, which
# must keep the 0.1.2 generation check and cost exactly one worker warning —
# never a permanently red probe.
#
# It is constructed here by running the checker as a user other than PID 1's.
# That is not what a Kubernetes exec probe does: an exec probe has no user
# setting of its own and normally inherits the container process credentials.
# It is simply the one way to produce an unreadable namespace link without a
# custom procfs mount.
topology_unverifiable_case() {
  local worker="kicks-liveness-unverifiable-$$"
  TOPOLOGY_RESOURCES+=("container:$worker")
  dock run --detach --name "$worker" "$IMAGE" \
    sh -c 'mkdir -p "$KICKS_LIVENESS_DIR" && chmod 0777 "$KICKS_LIVENESS_DIR" && exec sleep infinity' >/dev/null

  local as_other_user=(--user 1000:1000 "$worker")
  expect_state unverifiable unverifiable "$(topology_state "${as_other_user[@]}")"

  local warnings
  warnings="$(dock exec "${as_other_user[@]}" ruby -e "$RESPAWN_RUBY" 2>&1 |
    grep -c 'PID topology unverified' || true)"
  if [[ "$warnings" != 1 ]]; then
    echo "unverifiable: expected exactly one warning across three fork respawns, got $warnings" >&2
    return 1
  fi
  printf 'unverifiable: warnings across three fork respawns=%s\n' "$warnings"

  dock exec "${as_other_user[@]}" ruby -e "$PUBLISH_FOREIGN_RUBY"
  probe_in "${as_other_user[@]}"
  expect_probe 'unverifiable inherited heartbeat' 1 \
    'heartbeat belongs to a previous container: worker has not started yet'

  dock exec "${as_other_user[@]}" ruby -r kicks_liveness/heartbeat -e "$PUBLISH_RUBY"
  probe_in "${as_other_user[@]}"
  expect_probe 'unverifiable own heartbeat' 0 '1 process(es) healthy'
}

cmd_topology() {
  require_image
  trap cleanup_topology EXIT

  local sandbox="kicks-liveness-sandbox-$$"
  TOPOLOGY_RESOURCES+=("container:$sandbox")
  dock run --detach --name "$sandbox" "$IMAGE" sleep infinity >/dev/null

  # Kubernetes shareProcessNamespace: true — PID 1 is the pod sandbox.
  topology_unsafe_case shared-pid --pid "container:$sandbox"
  # Kubernetes hostPID: true — PID 1 is the node's init process. Reading its
  # namespace link is a ptrace-level operation, and a container without
  # CAP_SYS_PTRACE is normally refused; where it is refused the outcome is the
  # weaker "unverifiable" the case below covers.
  topology_unsafe_case host-pid --pid host --cap-add SYS_PTRACE
  topology_private_case
  topology_unverifiable_case
}

cmd_marks() { guard; kube exec deploy/worker -- ls -l /opt/app/tmp/health/; }
cmd_logs()  { guard; kube logs deploy/worker --tail="${1:-50}"; }
cmd_ui()    { guard; kube port-forward deploy/rabbitmq 15672:15672; }

case "${1:-}" in
  build) cmd_build ;;
  up) cmd_up ;;
  down) cmd_down ;;
  probe) cmd_probe ;;
  generation-restart) cmd_generation_restart ;;
  topology) cmd_topology ;;
  marks) cmd_marks ;;
  logs) shift; cmd_logs "${1:-50}" ;;
  ui) cmd_ui ;;
  status) cmd_status ;;
  *)
    echo "usage: $0 {build|up|down|probe|generation-restart|topology|marks|logs [n]|ui|status}" >&2
    exit 64
    ;;
esac
