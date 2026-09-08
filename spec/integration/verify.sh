#!/usr/bin/env bash
# Brings the integration environment up and down. Every kubectl call names the
# context and the namespace explicitly: this must never be able to reach a real
# cluster because someone's current-context happened to point at one.
set -euo pipefail

CONTEXT="${KICKS_LIVENESS_K8S_CONTEXT:-docker-desktop}"
NAMESPACE="${KICKS_LIVENESS_K8S_NAMESPACE:-kicks-liveness}"
IMAGE=kicks-liveness-fixture:latest
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
K8S="$ROOT/spec/integration/k8s"

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

cmd_build() {
  docker --context "$DOCKER_CONTEXT_NAME" build \
    -f "$ROOT/spec/integration/fixture/Dockerfile" -t "$IMAGE" "$ROOT"
}

cmd_up() {
  guard
  kubectl --context "$CONTEXT" create namespace "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
  kube apply -f "$K8S/rabbitmq.yaml"
  kube rollout status deploy/rabbitmq --timeout=300s
  kube apply -f "$K8S/worker.yaml"
  kube rollout status deploy/worker --timeout=300s
  kube get pods -o wide
}

cmd_down() {
  guard
  kubectl --context "$CONTEXT" delete namespace "$NAMESPACE" --ignore-not-found
}

cmd_probe() {
  guard
  echo '--- standard: bundle exec kicks-liveness'
  kube exec deploy/worker -- sh -c 'bundle exec kicks-liveness; echo "exit=$?"'
  echo '--- optimised: plain ruby -e (needs the gems in GEM_HOME)'
  kube exec deploy/worker -- sh -c \
    'ruby -e "require %q(kicks_liveness/probe)"; echo "exit=$?"'
}

cmd_marks() { guard; kube exec deploy/worker -- ls -l /opt/app/tmp/health/; }
cmd_logs()  { guard; kube logs deploy/worker --tail="${1:-50}"; }
cmd_ui()    { guard; kube port-forward deploy/rabbitmq 15672:15672; }

case "${1:-}" in
  build) cmd_build ;;
  up) cmd_up ;;
  down) cmd_down ;;
  probe) cmd_probe ;;
  marks) cmd_marks ;;
  logs) shift; cmd_logs "${1:-50}" ;;
  ui) cmd_ui ;;
  *)
    echo "usage: $0 {build|up|down|probe|marks|logs [n]|ui}" >&2
    exit 64
    ;;
esac
