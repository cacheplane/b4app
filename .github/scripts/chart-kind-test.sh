#!/usr/bin/env bash
# The b4hub chart's install test on a kind cluster (.github/workflows/hub-chart.yml, job
# `install`), runnable locally against any kubectl context:
#
#   chart-kind-test.sh run        CloudNativePG, the b4hub-db Secret, install, upgrade, uninstall
#   chart-kind-test.sh diagnose   dump cluster state and hub logs after a failure
#
# Environment:
#   IMAGE_REPOSITORY      hub image repository (required for run)
#   IMAGE_TAG             hub image tag (required for run)
#   IMAGE_PULL_SECRET     optional name of a docker-registry Secret in the default namespace
#   CNPG_CHART_VERSION    cloudnative-pg chart version (required for run)
#   CURL_IMAGE            curl image for the in-cluster readiness probe (required for run)
#   CHART_DIR             chart path (default Hub/chart/b4hub)
#
# Runs in the default namespace: ci/kind-values.yaml points hub.publicUrl at b4hub.default.svc.
set -euo pipefail

CHART_DIR="${CHART_DIR:-Hub/chart/b4hub}"
RELEASE=b4hub
NS=default
# The chart's fullname is the release name when it contains the chart name.
FULLNAME=b4hub

fail() {
  echo "::error::$*" >&2
  exit 1
}

group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

# Fails fast when a hub or migrate pod cannot pull its image, instead of waiting out the
# Helm timeout. Prints nothing and returns 0 otherwise.
check_image_pull() {
  local reasons
  reasons="$(kubectl -n "$NS" get pods -l app.kubernetes.io/instance="$RELEASE" -o json \
    | jq -r '[.items[].status | (.initContainerStatuses // []) + (.containerStatuses // [])
              | .[].state.waiting.reason // empty] | unique | join(",")')" || return 0
  case "$reasons" in
    *ImagePullBackOff* | *ErrImagePull* | *InvalidImageName*)
      kubectl -n "$NS" get pods -l app.kubernetes.io/instance="$RELEASE" -o wide || true
      kubectl -n "$NS" describe pods -l app.kubernetes.io/instance="$RELEASE" | grep -A3 -i 'failed to pull' || true
      fail "cannot pull $IMAGE_REPOSITORY:$IMAGE_TAG ($reasons). If the GHCR package is private, the owner step \"make the GHCR package public\" is pending; otherwise check that the tag exists."
      ;;
  esac
}

# Runs `helm "$@"` in the background and watches for image pull failures while it waits.
helm_watched() {
  helm "$@" &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if ! (check_image_pull); then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      exit 1
    fi
    sleep 5
  done
  wait "$pid"
}

# Asserts the hook Job `name` ran to completion. The Job and its pod are deleted on success
# (hook-delete-policy hook-succeeded), so the evidence is the Job controller's events, which
# outlive the object, plus the absence of a failed Job.
assert_job_completed() {
  local name="$1" reasons
  reasons="$(kubectl -n "$NS" get events \
    --field-selector "involvedObject.kind=Job,involvedObject.name=$name" -o json \
    | jq -r '[.items[].reason] | unique | join(",")')"
  echo "events for job/$name: ${reasons:-none}"
  case ",$reasons," in
    *,Completed,*) ;;
    *) fail "migration Job $name did not record a Completed event (events: ${reasons:-none})" ;;
  esac
  case ",$reasons," in
    *,BackoffLimitExceeded,* | *,DeadlineExceeded,*) fail "migration Job $name failed ($reasons)" ;;
  esac
  if kubectl -n "$NS" get job "$name" >/dev/null 2>&1; then
    local failed
    failed="$(kubectl -n "$NS" get job "$name" -o jsonpath='{.status.failed}')"
    [ -z "$failed" ] || [ "$failed" = 0 ] || fail "migration Job $name has failed pods"
  fi
}

# Asserts the hub answers /readyz in-cluster with its readiness JSON.
assert_ready() {
  local out body
  kubectl -n "$NS" delete pod curl --ignore-not-found --wait=true >/dev/null
  out="$(kubectl -n "$NS" run curl --rm -i --restart=Never --quiet --image="$CURL_IMAGE" \
    --command -- curl -fsS --max-time 10 "http://$FULLNAME:80/readyz")" \
    || fail "GET http://$FULLNAME:80/readyz failed: $out"
  body="$(grep -m1 '^{' <<< "$out" || true)"
  echo "readyz: $body"
  jq -e 'has("minClientProtocol")' <<< "$body" >/dev/null \
    || fail "/readyz did not return JSON with minClientProtocol: $out"
}

deployment_revision() {
  kubectl -n "$NS" get deployment "$FULLNAME" \
    -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}'
}

run() {
  : "${IMAGE_REPOSITORY:?}" "${IMAGE_TAG:?}" "${CNPG_CHART_VERSION:?}" "${CURL_IMAGE:?}"
  local values="$CHART_DIR/ci/kind-values.yaml"
  local image_args=(--set "image.repository=$IMAGE_REPOSITORY" --set "image.tag=$IMAGE_TAG")
  if [ -n "${IMAGE_PULL_SECRET:-}" ]; then
    image_args+=(--set "imagePullSecrets[0].name=$IMAGE_PULL_SECRET")
  fi

  group "CloudNativePG operator $CNPG_CHART_VERSION"
  helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update
  helm upgrade --install cnpg cnpg/cloudnative-pg --version "$CNPG_CHART_VERSION" \
    --namespace cnpg-system --create-namespace --wait --timeout 5m
  kubectl -n cnpg-system rollout status deployment/cnpg-cloudnative-pg --timeout=180s
  endgroup

  group "CloudNativePG cluster from examples/cnpg-cluster.yaml"
  grep -q '^  enableSuperuserAccess: true$' "$CHART_DIR/examples/cnpg-cluster.yaml" \
    || fail "examples/cnpg-cluster.yaml must set enableSuperuserAccess: true"
  kubectl -n "$NS" apply -f "$CHART_DIR/examples/cnpg-cluster.yaml"
  # The Cluster has no Ready condition until the operator first reconciles it.
  for _ in $(seq 30); do
    kubectl -n "$NS" get cluster/b4hub-db -o jsonpath='{.status.conditions}' | grep -q Ready && break
    sleep 2
  done
  kubectl -n "$NS" wait --for=condition=Ready cluster/b4hub-db --timeout=300s
  kubectl -n "$NS" get secrets -l cnpg.io/cluster=b4hub-db
  endgroup

  group "b4hub-db Secret, as the chart README builds it"
  # The README's "CloudNativePG example" sequence, with -n default.
  local admin_user admin_pw app_pw
  admin_user="$(kubectl -n "$NS" get secret b4hub-db-superuser -o jsonpath='{.data.username}' | base64 -d)"
  admin_pw="$(kubectl -n "$NS" get secret b4hub-db-superuser -o jsonpath='{.data.password}' | base64 -d)"
  app_pw="$(openssl rand -hex 24)"
  [ -n "$admin_user" ] && [ -n "$admin_pw" ] || fail "b4hub-db-superuser lacks username or password"
  kubectl -n "$NS" create secret generic b4hub-db \
    --from-file=DATABASE_URL=<(printf 'postgres://b4hub_app:%s@b4hub-db-rw:5432/b4hub' "$app_pw") \
    --from-file=DATABASE_ADMIN_URL=<(printf 'postgres://%s:%s@b4hub-db-rw:5432/b4hub' "$admin_user" "$admin_pw")
  endgroup

  group "helm install (revision 1)"
  helm_watched install "$RELEASE" "$CHART_DIR" -n "$NS" -f "$values" "${image_args[@]}" \
    --wait --timeout 5m
  assert_job_completed "$FULLNAME-migrate-1"
  local applied
  applied="$(kubectl -n "$NS" exec b4hub-db-1 -c postgres -- \
    psql -d b4hub -tAc 'SELECT count(*) FROM _sqlx_migrations WHERE success')"
  echo "applied migrations: $applied"
  [ "${applied:-0}" -gt 0 ] || fail "no migrations recorded in _sqlx_migrations"
  kubectl -n "$NS" exec b4hub-db-1 -c postgres -- \
    psql -d b4hub -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'b4hub_app'" | grep -qx 1 \
    || fail "the migration did not provision b4hub_app"
  kubectl -n "$NS" rollout status "deployment/$FULLNAME" --timeout=120s
  assert_ready
  local before
  before="$(deployment_revision)"
  endgroup

  group "helm upgrade --set hub.log=debug (revision 2)"
  helm_watched upgrade "$RELEASE" "$CHART_DIR" -n "$NS" -f "$values" "${image_args[@]}" \
    --set hub.log=debug --wait --timeout 5m
  assert_job_completed "$FULLNAME-migrate-2"
  kubectl -n "$NS" rollout status "deployment/$FULLNAME" --timeout=120s
  local after
  after="$(deployment_revision)"
  echo "deployment revision: $before -> $after"
  [ -n "$after" ] && [ "$after" != "$before" ] || fail "the Deployment did not roll on upgrade"
  kubectl -n "$NS" get deployment "$FULLNAME" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="B4HUB_LOG")].value}' | grep -qx debug \
    || fail "the upgraded Deployment does not carry B4HUB_LOG=debug"
  assert_ready
  endgroup

  group "helm uninstall"
  helm uninstall "$RELEASE" -n "$NS" --wait --timeout 2m
  if kubectl -n "$NS" get deployment -l app.kubernetes.io/instance="$RELEASE" -o name | grep -q .; then
    fail "a b4hub Deployment remains after helm uninstall"
  fi
  endgroup
  echo "chart install test passed"
}

diagnose() {
  set +e
  kubectl get all,jobs,events -A
  kubectl -n "$NS" describe pods -l app.kubernetes.io/instance="$RELEASE"
  kubectl -n "$NS" logs -l app.kubernetes.io/instance="$RELEASE" --all-containers --tail=200 --prefix
  kubectl -n "$NS" get cluster b4hub-db -o yaml
  helm -n "$NS" history "$RELEASE"
  return 0
}

case "${1:-}" in
  run) run ;;
  diagnose) diagnose ;;
  *)
    echo "usage: $0 run|diagnose" >&2
    exit 2
    ;;
esac
