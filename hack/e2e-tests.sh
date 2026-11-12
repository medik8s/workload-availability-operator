#!/usr/bin/env bash
# Run the rhwa-system-tests e2e suite against an already deployed WAO.
#
# This mirrors the CI prow job (openshift/release, ci-operator config
# medik8s-workload-availability-operator-wao__5.0.yaml, test step
# e2e-nmo) without prow:
#   - clone openshift/rhwa-system-tests (branch wao) into a tmp dir,
#     or reuse E2E_SYSTEM_TESTS_DIR when set
#   - wait for the WAO controller, enable the nodeMaintenance operand and
#     wait for it to reach phase Available
#   - run `make run-tests` from the checkout with the same ECO_* configuration
#
# Deploy WAO first, e.g.: KUBECONFIG=... make dev-olm-deploy
#
# Required:
#   KUBECONFIG  kubeconfig of a disposable OpenShift cluster with WAO installed
#
# Optional environment (defaults in parens):
#   E2E_SYSTEM_TESTS_REPO   (https://github.com/openshift/rhwa-system-tests.git)
#   E2E_SYSTEM_TESTS_BRANCH (wao)
#   E2E_SYSTEM_TESTS_DIR    (tmp clone) reuse an existing checkout instead
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
#   ECO_TEST_TIMEOUT, ECO_REPORTS_DUMP_DIR, ARTIFACT_DIR: see
#   scripts/test-runner.sh in rhwa-system-tests

set -euo pipefail

: "${KUBECONFIG:?set KUBECONFIG to the disposable cluster kubeconfig}"

REPO="${E2E_SYSTEM_TESTS_REPO:-https://github.com/openshift/rhwa-system-tests.git}"
BRANCH="${E2E_SYSTEM_TESTS_BRANCH:-wao}"
ENABLE_NMO="${E2E_ENABLE_NMO:-true}"
NAMESPACE="${E2E_NAMESPACE:-openshift-workload-availability}"
export ECO_TEST_FEATURES="${ECO_TEST_FEATURES:-nmo-operator}"
export ECO_TEST_LABELS="${ECO_TEST_LABELS:-!component:olm}"
export ECO_TEST_VERBOSE="${ECO_TEST_VERBOSE:-true}"
export ECO_DUMP_FAILED_TESTS="${ECO_DUMP_FAILED_TESTS:-true}"

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
cleanup() { [ -n "$tmp_clone" ] && rm -rf "$tmp_clone"; }
trap cleanup EXIT

if [ -n "${E2E_SYSTEM_TESTS_DIR:-}" ]; then
  tests_dir="${E2E_SYSTEM_TESTS_DIR}"
  echo "==> Using existing rhwa-system-tests checkout: $tests_dir"
else
  tmp_clone="$(mktemp -d "${TMPDIR:-/tmp}/rhwa-system-tests.XXXXXX")"
  echo "==> Cloning $REPO (branch $BRANCH) into $tmp_clone"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$tmp_clone"
  tests_dir="$tmp_clone"
fi

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
echo "    reports: ${ECO_REPORTS_DUMP_DIR:-${ARTIFACT_DIR:-/tmp/reports}}"
cd "$tests_dir"
make run-tests
