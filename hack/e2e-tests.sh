#!/usr/bin/env bash
# Run the rhwa-system-tests e2e suite against an already deployed WAO.
#
# This mirrors the CI prow jobs (openshift/release, ci-operator config
# medik8s-workload-availability-operator-wao__5.0.yaml) without prow:
#   - wait for the WAO controller, enable the requested operand(s) and
#     wait for each to reach phase Available
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
#   E2E_ENABLE_COMPONENTS   (nmo) space separated operand short names (nhc, nmo,
#                            snr, sbr, far, mdr) to enable before the tests run;
#                            set empty to skip the pre-flight when you enabled
#                            the operand yourself
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
ENABLE_COMPONENTS="${E2E_ENABLE_COMPONENTS:-nmo}"
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

# WorkloadAvailabilityConfig component key for each operand short name
# (api/v1alpha1.ComponentKey*); kept in sync with internal/components/*.go
# ShortName/Key values.
component_key() {
  case "$1" in
    nhc) echo "nodeHealthCheck" ;;
    snr) echo "selfNodeRemediation" ;;
    sbr) echo "storageBasedRemediation" ;;
    nmo) echo "nodeMaintenance" ;;
    far) echo "fenceAgentsRemediation" ;;
    mdr) echo "machineDeletionRemediation" ;;
    *)
      echo "Error: unknown operand '$1' (expected nhc, nmo, snr, sbr, far or mdr)" >&2
      exit 1
      ;;
  esac
}

# Manager Deployment name for each operand short name; kept in sync with
# internal/components/*.go ManagerDeployment values.
component_deployment() {
  case "$1" in
    nhc) echo "node-healthcheck-controller-manager" ;;
    snr) echo "self-node-remediation-controller-manager" ;;
    sbr) echo "sbr-operator-controller-manager" ;;
    nmo) echo "node-maintenance-operator-controller-manager" ;;
    far) echo "fence-agents-remediation-controller-manager" ;;
    mdr) echo "machine-deletion-remediation-controller-manager" ;;
    *)
      echo "Error: unknown operand '$1' (expected nhc, nmo, snr, sbr, far or mdr)" >&2
      exit 1
      ;;
  esac
}

if [ -n "$ENABLE_COMPONENTS" ]; then
  patch='{"spec":{"components":{'
  sep=""
  for name in $ENABLE_COMPONENTS; do
    patch+="${sep}\"$(component_key "$name")\":{\"enabled\":true}"
    sep=","
  done
  patch+='}}}'

  echo "==> Enable component(s) '$ENABLE_COMPONENTS' via the WorkloadAvailabilityConfig"
  kc patch workloadavailabilityconfig cluster --type=merge -p "$patch"

  for name in $ENABLE_COMPONENTS; do
    key="$(component_key "$name")"
    echo "==> Wait for the $name operand to reach phase Available"
    attempt=1
    until [ "$(kc get workloadavailabilityconfig cluster \
      -o jsonpath="{.status.components[?(@.name==\"${key}\")].phase}")" = "Available" ]; do
      if [ "$attempt" -gt 60 ]; then
        echo "==> $name operand never reached phase Available; dumping cluster state" >&2
        kc get workloadavailabilityconfig cluster -o yaml >&2
        kc get deployment,daemonset,pod -n "$NAMESPACE" >&2
        exit 1
      fi
      echo "  attempt ${attempt}/60 - $name operand not Available yet, waiting 10s..."
      attempt=$(( attempt + 1 ))
      sleep 10
    done

    deployment="$(component_deployment "$name")"
    echo "==> Wait for the $deployment Deployment to become ready"
    kc wait --for=condition=Available \
      "deployment/${deployment}" \
      -n "$NAMESPACE" --timeout=10m
  done
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
