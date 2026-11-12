# Running e2e tests

`make e2e-tests` runs the [rhwa-system-tests](https://github.com/openshift/rhwa-system-tests)
suite against an already deployed WAO. It executes the same feature and label
filter as the CI prow job, but from a developer machine: the target enables
the NMO operand, waits for it to become ready, and launches ginkgo. Two
runners execute the tests:

- **clone** (default): clones the `wao` branch of rhwa-system-tests into a
  tmp dir and runs `make run-tests` from the checkout. The tmp clone is
  removed when the run ends.
- **image** (`make e2e-ci-test`): runs the prebuilt CI image
  `quay.io/medik8s/system-tests:wao` with your container tool. The image
  carries the test source, the Go module cache and ginkgo from the `wao`
  branch, and its entrypoint is rhwa-system-tests' own test runner — the
  closest local equivalent to how the prow job executes the tests.

Reports survive the run in a reports directory either way.

The implementation lives in [hack/e2e-tests.sh](../hack/e2e-tests.sh).

## Prerequisites

- A **disposable** OpenShift cluster with classic OLM that you are authorized
  to modify — the same rule as the other cluster targets, see
  [AGENTS.md](../AGENTS.md). The default label filter runs **all** NMO specs,
  including destructive ones that create `NodeMaintenance` CRs and drain
  nodes; a disposable cluster is mandatory, not just recommended.
- WAO deployed on that cluster, for example:

  ```sh
  KUBECONFIG=/path/to/disposable.kubeconfig make dev-olm-deploy DEV_CLUSTER_TYPE=external
  ```

- `KUBECONFIG` must be passed explicitly on every invocation; the target
  refuses to run without it and never relies on the current context.
- On the host: bash and `oc` (or `kubectl`). For the clone runner also git,
  make and Go; ginkgo is installed by rhwa-system-tests' own Makefile inside
  the clone. For the image runner also a container tool (`CONTAINER_TOOL`,
  default podman).

## Quick start

```sh
KUBECONFIG=/path/to/disposable.kubeconfig make e2e-tests        # clone runner
KUBECONFIG=/path/to/disposable.kubeconfig make e2e-ci-test      # image runner
```

The target then:

1. Waits for the WAO controller Deployment to become ready.
2. Patches `WorkloadAvailabilityConfig/cluster` to enable the
   `nodeMaintenance` component, waits for its phase to reach `Available` and
   for the NMO manager Deployment to become ready. This patch is the only
   change the target writes directly; WAO then creates the operand objects
   for the enabled component. Every component stays `Disabled` until then.
3. Executes the tests with the selected runner:
   - clone: clones `https://github.com/openshift/rhwa-system-tests.git`
     branch `wao` into a fresh tmp dir (unless `E2E_SYSTEM_TESTS_DIR` points
     at a checkout) and runs `make run-tests` there, which drives ginkgo
     with the `ECO_*` configuration below.
   - image: runs `CONTAINER_TOOL run` on `E2E_SYSTEM_TESTS_IMAGE`. The
     kubeconfig is flattened into a tmp file, mounted into the container and
     deleted afterwards; a host tmp dir is mounted at `/reports` inside and
     kept after the run.

JUnit XML reports and failure dumps are written to `/tmp/reports`
(`ECO_REPORTS_DUMP_DIR`, or `ARTIFACT_DIR` when set) for the clone runner,
and to the mounted reports tmp dir printed at the start of an image-runner
run.

Every run states where the tests execute, so saved logs are unambiguous: a
line at startup (`==> Test execution location: ...`), a banner right before
the tests start (`==> Tests are running INSIDE the container: <image>` or
`==> Tests are running ON THE HOST from: <directory>`), and a closing line
when an image-runner container exits.

## Variables

All variables are optional; defaults are shown in parentheses. Pass them on
the make command line (`make e2e-tests VAR=value`) or in the environment
(`VAR=value make e2e-tests`) — both reach the test runner.

### WAO target variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `KUBECONFIG` | (required) | Kubeconfig of the target cluster. Always passed explicitly. |
| `E2E_RUNNER` | `clone` | How the tests are executed: `clone` or `image`. `make e2e-ci-test` sets this to `image`. |
| `E2E_SYSTEM_TESTS_REPO` | `https://github.com/openshift/rhwa-system-tests.git` | Repository cloned when no checkout is given. |
| `E2E_SYSTEM_TESTS_BRANCH` | `wao` | Branch cloned into the tmp dir. |
| `E2E_SYSTEM_TESTS_DIR` | (tmp clone) | Run an existing rhwa-system-tests checkout instead of cloning; the directory is kept. Clone runner only. |
| `E2E_SYSTEM_TESTS_IMAGE` | `quay.io/medik8s/system-tests:wao` | Image run by the image runner. |
| `CONTAINER_TOOL` | `podman` | Container tool used by the image runner. |
| `E2E_ENABLE_NMO` | `true` | Run the NMO pre-flight (patch + waits). Set `false` when running another feature whose operand you enabled yourself. |
| `E2E_NAMESPACE` | `openshift-workload-availability` | Namespace of the WAO and operand Deployments. |

### Test selection variables

These match the environment of the CI prow job and are forwarded to
rhwa-system-tests' `scripts/test-runner.sh`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `ECO_TEST_FEATURES` | `nmo-operator` | Space-separated feature directories under rhwa-system-tests `tests/` (`nmo-operator`, `nhc-operator`, `snr-operator`, `sbr-operator`, `far-operator`, `mdr-operator`, `wao-operator`), or `all`. |
| `ECO_TEST_LABELS` | `!component:olm` | ginkgo `--label-filter` expression; the default runs all NMO specs, destructive ones included. |
| `ECO_TEST_FOCUS` | (none) | Run a single spec by name. |
| `ECO_TEST_VERBOSE` | `true` | ginkgo `-vv`. |
| `ECO_TEST_TRACE` | (none) | ginkgo `--trace`. |
| `ECO_TEST_TIMEOUT` | `24h` | ginkgo timeout. |
| `ECO_DUMP_FAILED_TESTS` | `true` | Dump cluster state for failed specs. |
| `WORKLOAD_IMAGE` | `registry.access.redhat.com/ubi9/ubi-minimal:latest` | Image used for test workload pods; the suites require it and panic without it. |
| `ECO_REPORTS_DUMP_DIR` | `/tmp/reports` | Where reports are written (`ARTIFACT_DIR` takes precedence when set). |

The default label filter, `!component:olm`, runs **all** `nmo-operator` specs:

- Destructive specs are included: they create `NodeMaintenance` CRs, which
  drain (and reboot) nodes. Only run the default against a disposable
  cluster. To restore non-destructible-only selection, see the examples below.
- `component:olm` specs stay excluded because WAO installs the operands from
  manifests, not OLM; they would fail without a component
  ClusterServiceVersion.

Label-filter expressions use ginkgo's
[label-filter syntax](https://onsi.github.io/ginkgo/#label-filtering)
(`&&`, `||`, `!`, comma for `||`). The rhwa-system-tests label vocabulary is
defined in its `tests/internal/labels` package (`operator:*`, `tier:*`,
`disruption:*`, `component:*`, `platform:*`, ...).

## Examples

Run against a local rhwa-system-tests checkout instead of a fresh clone —
useful when iterating on test code:

```sh
KUBECONFIG=/path/to/disposable.kubeconfig make e2e-tests E2E_SYSTEM_TESTS_DIR=../rhwa-system-tests
```

Run a single spec by name:

```sh
KUBECONFIG=/path/to/disposable.kubeconfig make e2e-tests ECO_TEST_FOCUS='should successfully create a NodeMaintenance CR'
```

Restrict the run to non-destructive specs only (the previous default):

```sh
KUBECONFIG=/path/to/disposable.kubeconfig make e2e-tests ECO_TEST_LABELS='disruption:nondestructive && !component:olm'
```

Narrow the label filter further, e.g. to smoke-tier specs only:

```sh
KUBECONFIG=/path/to/disposable.kubeconfig make e2e-tests ECO_TEST_LABELS='disruption:nondestructive && tier:smoke'
```

Run another feature. Enable that component's operand yourself first (patch
`WorkloadAvailabilityConfig/cluster`, never create the operand policy
objects), then skip the NMO pre-flight:

```sh
KUBECONFIG=/path/to/disposable.kubeconfig make e2e-tests \
  E2E_ENABLE_NMO=false ECO_TEST_FEATURES=wao-operator
```

## The image runner

`make e2e-ci-test` (or `make e2e-tests E2E_RUNNER=image`) executes the tests
inside `E2E_SYSTEM_TESTS_IMAGE` instead of a git clone:

```sh
KUBECONFIG=/path/to/disposable.kubeconfig make e2e-ci-test
```

The image is built from the rhwa-system-tests `wao` branch by that repo's CI
and contains the test source, the Go module cache and ginkgo, so no clone,
Go toolchain or ginkgo build happens on the host. Differences from the clone
runner:

- The cluster pre-flight (waits, NMO enablement) still runs on the host with
  your `oc`/`kubectl`; only the test execution is containerized.
- The kubeconfig is flattened (credentials embedded) into a host tmp file,
  mounted read-only into the container and deleted when the run ends.
- Reports are written to a host tmp dir that is mounted at `/reports` inside
  the container and kept after the run; its path is printed before the tests
  start.
- The container runs with `--network=host` so clusters whose API is published
  on the host loopback (e.g. Kind) remain reachable.
- Test-selection variables (`ECO_*`) are forwarded into the container; host
  `ARTIFACT_DIR` is deliberately not forwarded, since its path would not
  exist inside the container.

The clone runner with `E2E_SYSTEM_TESTS_DIR` is better suited for iterating
on test code; the image runner reproduces the CI environment (the exact
image, module cache and ginkgo binary the prow job uses) and needs nothing
but a container tool on the host.

## Relation to CI

The prow job `install-wao-nmo-daily-aws` (openshift/release ci-operator
config `medik8s-workload-availability-operator-wao__5.0.yaml`, test step
`e2e-nmo`) runs this same `make e2e-tests` target in the
`quay.io/medik8s/system-tests:wao` image. The `ECO_*` values set in the job
match the defaults above, so a local run reproduces the CI test selection.
`make e2e-ci-test` additionally reproduces the CI execution environment,
since it runs the same image the prow job runs the tests in.
