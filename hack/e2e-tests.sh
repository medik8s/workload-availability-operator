#!/usr/bin/env bash
# Run the rhwa-system-tests e2e suite against an already deployed WAO.
#
# This mirrors the CI prow job (openshift/release, ci-operator config
# medik8s-workload-availability-operator-wao__5.0.yaml, test step
# e2e-nmo) without prow:
#   - wait for the WAO controller, enable the nodeMaintenance operand and
#     wait for it to reach phase Available
#   - run the tests with the same ECO_* configuration, using either runner:
#     - clone (default): clone openshift/rhwa-system-tests (branch wao) into
#       a tmp dir, or reuse E2E_SYSTEM_TESTS_DIR when set, and run
#       `make run-tests` from the checkout
#     - image: run the prebuilt CI image E2E_SYSTEM_TESTS_IMAGE with the
#       container tool; the image carries the test source, the Go module
#       cache and ginkgo, and its entrypoint is rhwa-system-tests'
#       scripts/test-runner.sh. The kubeconfig is flattened, mounted into the
#       container and removed afterwards; reports are kept on the host.
#
# Deploy WAO first, e.g.: KUBECONFIG=... make dev-olm-deploy
#
# Required:
#   KUBECONFIG  kubeconfig of a disposable OpenShift cluster with WAO installed
#
# Optional environment (defaults in parens):
#   E2E_RUNNER              (clone) clone | image: how the tests are executed
#   E2E_SYSTEM_TESTS_REPO   (https://github.com/openshift/rhwa-system-tests.git)
#   E2E_SYSTEM_TESTS_BRANCH (wao)
#   E2E_SYSTEM_TESTS_DIR    (tmp clone) reuse an existing checkout instead
#   E2E_SYSTEM_TESTS_IMAGE  (quay.io/medik8s/system-tests:wao) image runner
#   CONTAINER_TOOL          (podman) container tool for the image runner
#   E2E_ENABLE_NMO          (true) enable nodeMaintenance first; set false to
#                            skip the pre-flight when running another
#                            ECO_TEST_FEATURES whose operand you enabled yourself
#   E2E_NAMESPACE           (openshift-workload-availability)
#   ECO_TEST_FEATURES       (nmo-operator) space separated rhwa-system-tests features
#   ECO_TEST_LABELS         (!component:olm) ginkgo label filter; the default runs
#                            ALL nmo-operator specs, including destructive ones that
#                            create NodeMaintenance CRs and drain nodes - use a
#                            disposable cluster. component:olm stays excluded because
#                            WAO installs operands from manifests, not OLM, so the
#                            CSV specs cannot pass.
#   ECO_TEST_VERBOSE        (true)
#   ECO_DUMP_FAILED_TESTS   (true)
#   WORKLOAD_IMAGE          (registry.access.redhat.com/ubi9/ubi-minimal:latest)
#                            image for test workload pods; the tests require it
#   ECO_TEST_FOCUS, ECO_TEST_TRACE, ECO_TEST_TIMEOUT, ECO_REPORTS_DUMP_DIR,
#   ARTIFACT_DIR: see scripts/test-runner.sh in rhwa-system-tests

set -euo pipefail

: "${KUBECONFIG:?set KUBECONFIG to the disposable cluster kubeconfig}"

RUNNER="${E2E_RUNNER:-clone}"
REPO="${E2E_SYSTEM_TESTS_REPO:-https://github.com/openshift/rhwa-system-tests.git}"
BRANCH="${E2E_SYSTEM_TESTS_BRANCH:-wao}"
IMAGE="${E2E_SYSTEM_TESTS_IMAGE:-quay.io/medik8s/system-tests:wao}"
CONTAINER_TOOL="${CONTAINER_TOOL:-podman}"
ENABLE_NMO="${E2E_ENABLE_NMO:-true}"
NAMESPACE="${E2E_NAMESPACE:-openshift-workload-availability}"
export ECO_TEST_FEATURES="${ECO_TEST_FEATURES:-nmo-operator}"
export ECO_TEST_LABELS="${ECO_TEST_LABELS:-!component:olm}"
export ECO_TEST_VERBOSE="${ECO_TEST_VERBOSE:-true}"
export ECO_DUMP_FAILED_TESTS="${ECO_DUMP_FAILED_TESTS:-true}"
# Test workload pods run this image; the tests panic without it. The default
# is the value prow's medik8s-lib step hardcodes as the single source of
# truth (ci-operator step-registry/medik8s/lib).
export WORKLOAD_IMAGE="${WORKLOAD_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}"

if [ "$RUNNER" != "clone" ] && [ "$RUNNER" != "image" ]; then
  echo "Error: E2E_RUNNER must be 'clone' or 'image', got '$RUNNER'" >&2
  exit 1
fi

# Announce the execution location up front; a banner repeats it right before
# the tests start, so long logs always show where the tests are running.
if [ "$RUNNER" = "image" ]; then
  echo "==> Test execution location: INSIDE the container $IMAGE (via $CONTAINER_TOOL)"
else
  echo "==> Test execution location: ON THE HOST (clone runner)"
fi

# CI containers may run with a non-writable HOME; give Go a writable build
# cache for the ginkgo build inside the cloned rhwa-system-tests checkout.
if [ -z "${GOCACHE:-}" ] && ! [ -w "${HOME:-/nonexistent}" ]; then
  export GOCACHE=/tmp/wao-e2e-gocache
fi

if command -v oc >/dev/null 2>&1; then
  CLI=oc
elif command -v kubectl >/dev/null 2>&1; then
  CLI=kubectl
else
  echo "Error: oc or kubectl is required" >&2
  exit 1
fi

kc() { "$CLI" --kubeconfig "$KUBECONFIG" "$@"; }

tmp_clone=""
flat_kubeconfig=""
cleanup() {
  # Use if/fi, not `[ -n ] && cmd`: with set -e the failed test of an
  # empty variable would make this EXIT trap return non-zero and fail the
  # whole run after the suite already passed.
  if [ -n "${tmp_clone:-}" ]; then
    rm -rf -- "$tmp_clone"
  fi
  if [ -n "${flat_kubeconfig:-}" ]; then
    rm -f -- "$flat_kubeconfig"
  fi
}
trap cleanup EXIT

echo "==> Wait for the WAO controller Deployment to become ready"
kc wait --for=condition=Available \
  deployment/workload-availability-operator-controller-manager \
  -n "$NAMESPACE" --timeout=10m

if [ "$ENABLE_NMO" = "true" ]; then
  echo '==> Enable the nodeMaintenance operand via the WorkloadAvailabilityConfig'
  kc patch workloadavailabilityconfig cluster --type=merge \
    -p '{"spec":{"components":{"nodeMaintenance":{"enabled":true}}}}'

  echo '==> Wait for the NMO operand to reach phase Available'
  attempt=1
  until [ "$(kc get workloadavailabilityconfig cluster \
    -o jsonpath='{.status.components[?(@.name=="nodeMaintenance")].phase}')" = "Available" ]; do
    if [ "$attempt" -gt 60 ]; then
      echo '==> NMO operand never reached phase Available; dumping cluster state' >&2
      kc get workloadavailabilityconfig cluster -o yaml >&2
      kc get deployment,daemonset,pod -n "$NAMESPACE" >&2
      exit 1
    fi
    echo "  attempt ${attempt}/60 - NMO operand not Available yet, waiting 10s..."
    attempt=$(( attempt + 1 ))
    sleep 10
  done

  echo '==> Wait for the NMO manager Deployment to become ready'
  kc wait --for=condition=Available \
    deployment/node-maintenance-operator-controller-manager \
    -n "$NAMESPACE" --timeout=10m
fi

echo "==> Run rhwa-system-tests feature(s) '$ECO_TEST_FEATURES' with label filter '$ECO_TEST_LABELS'"

if [ "$RUNNER" = "image" ]; then
  if ! command -v "$CONTAINER_TOOL" >/dev/null 2>&1; then
    echo "Error: CONTAINER_TOOL '$CONTAINER_TOOL' not found" >&2
    exit 1
  fi

  # Flatten the kubeconfig so a single file mount carries every credential;
  # the file is removed by the EXIT trap. 0644: the container runs as uid 1000.
  flat_kubeconfig="$(mktemp "${TMPDIR:-/tmp}/wao-e2e-kubeconfig.XXXXXX")"
  chmod 644 "$flat_kubeconfig"
  kc config view --flatten --raw > "$flat_kubeconfig"

  reports_dir="$(mktemp -d "${TMPDIR:-/tmp}/wao-e2e-reports.XXXXXX")"
  chmod 777 "$reports_dir"

  # Forward optional ECO_* variables only when set; the four main ones always.
  env_args=(-e KUBECONFIG=/kubeconfig
    -e ECO_TEST_FEATURES -e ECO_TEST_LABELS
    -e ECO_TEST_VERBOSE -e ECO_DUMP_FAILED_TESTS
    -e WORKLOAD_IMAGE
    -e ECO_REPORTS_DUMP_DIR=/reports)
  for var in ECO_TEST_FOCUS ECO_TEST_TRACE ECO_TEST_TIMEOUT; do
    [ -n "${!var:-}" ] && env_args+=(-e "$var")
  done

  echo "====================================================================="
  echo "==> Tests are running INSIDE the container: $IMAGE"
  echo "==> started with: $CONTAINER_TOOL run --rm --network=host $IMAGE"
  echo "====================================================================="
  echo "    reports: $reports_dir"
  # --network=host: the tests must reach the cluster API, including clusters
  # whose API is published on the host loopback (e.g. Kind).
  set +e
  "$CONTAINER_TOOL" run --rm --network=host \
    "${env_args[@]}" \
    -v "$flat_kubeconfig":/kubeconfig:Z,ro \
    -v "$reports_dir":/reports:Z \
    "$IMAGE"
  rc=$?
  set -e
  echo "==> container run finished; reports kept in: $reports_dir"
  exit "$rc"
fi

if [ -n "${E2E_SYSTEM_TESTS_DIR:-}" ]; then
  tests_dir="${E2E_SYSTEM_TESTS_DIR}"
  echo "==> Using existing rhwa-system-tests checkout: $tests_dir"
else
  tmp_clone="$(mktemp -d "${TMPDIR:-/tmp}/rhwa-system-tests.XXXXXX")"
  echo "==> Cloning $REPO (branch $BRANCH) into $tmp_clone"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$tmp_clone"
  tests_dir="$tmp_clone"
fi

echo "    reports: ${ECO_REPORTS_DUMP_DIR:-${ARTIFACT_DIR:-/tmp/reports}}"
echo "====================================================================="
echo "==> Tests are running ON THE HOST from: $tests_dir"
echo "====================================================================="
cd "$tests_dir"
make run-tests
