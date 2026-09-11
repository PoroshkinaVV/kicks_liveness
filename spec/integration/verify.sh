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
  docker --context "$DOCKER_CONTEXT_NAME" build \
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
    docker --context "$DOCKER_CONTEXT_NAME" rm --force "$GENERATION_CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ -n "${GENERATION_VOLUME:-}" ]]; then
    docker --context "$DOCKER_CONTEXT_NAME" volume rm "$GENERATION_VOLUME" >/dev/null 2>&1 || true
  fi
}

generation_probe() {
  docker --context "$DOCKER_CONTEXT_NAME" exec "$GENERATION_CONTAINER" \
    ruby -e 'require %q(kicks_liveness/probe)'
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
  if ! docker --context "$DOCKER_CONTEXT_NAME" image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "no image '$IMAGE' in Docker context '$DOCKER_CONTEXT_NAME': run '$0 build' first" >&2
    return 1
  fi

  GENERATION_CONTAINER="kicks-liveness-generation-$$"
  GENERATION_VOLUME="${GENERATION_CONTAINER}-state"
  trap cleanup_generation_restart EXIT

  docker --context "$DOCKER_CONTEXT_NAME" volume create "$GENERATION_VOLUME" >/dev/null
  docker --context "$DOCKER_CONTEXT_NAME" run --detach \
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
  before_generation="$(docker --context "$DOCKER_CONTEXT_NAME" exec "$GENERATION_CONTAINER" \
    cat /opt/app/tmp/health/generation)"

  docker --context "$DOCKER_CONTEXT_NAME" restart --time 1 "$GENERATION_CONTAINER" >/dev/null

  local after_generation
  after_generation="$(docker --context "$DOCKER_CONTEXT_NAME" exec "$GENERATION_CONTAINER" \
    ruby -r kicks_liveness/heartbeat -e 'print KicksLiveness::Heartbeat.container_generation')"
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

cmd_marks() { guard; kube exec deploy/worker -- ls -l /opt/app/tmp/health/; }
cmd_logs()  { guard; kube logs deploy/worker --tail="${1:-50}"; }
cmd_ui()    { guard; kube port-forward deploy/rabbitmq 15672:15672; }

case "${1:-}" in
  build) cmd_build ;;
  up) cmd_up ;;
  down) cmd_down ;;
  probe) cmd_probe ;;
  generation-restart) cmd_generation_restart ;;
  marks) cmd_marks ;;
  logs) shift; cmd_logs "${1:-50}" ;;
  ui) cmd_ui ;;
  status) cmd_status ;;
  *)
    echo "usage: $0 {build|up|down|probe|generation-restart|marks|logs [n]|ui|status}" >&2
    exit 64
    ;;
esac
