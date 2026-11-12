# Running e2e tests

`make e2e-tests` runs the [rhwa-system-tests](https://github.com/openshift/rhwa-system-tests)
suite against an already deployed WAO. It executes the same feature and label
filter as the CI prow job, but from a developer machine: the target clones the
`wao` branch of rhwa-system-tests into a tmp dir, enables the NMO operand,
waits for it to become ready, and launches ginkgo from the clone. The tmp
clone is removed when the run ends; reports survive in a reports directory.

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
- On the host: bash, git, make, Go, and `oc` (or `kubectl`). ginkgo is
  installed by rhwa-system-tests' own Makefile inside the clone.

## Quick start

```sh
KUBECONFIG=/path/to/disposable.kubeconfig make e2e-tests
```

The target then:

1. Clones `https://github.com/openshift/rhwa-system-tests.git` branch `wao`
   into a fresh tmp dir (unless `E2E_SYSTEM_TESTS_DIR` points at a checkout).
2. Waits for the WAO controller Deployment to become ready.
3. Patches `WorkloadAvailabilityConfig/cluster` to enable the
   `nodeMaintenance` component, waits for its phase to reach `Available` and
   for the NMO manager Deployment to become ready. This patch is the only
   change the target writes directly; WAO then creates the operand objects
   for the enabled component. Every component stays `Disabled` until then.
4. Runs `make run-tests` in the clone, which drives ginkgo with the `ECO_*`
   configuration below.

JUnit XML reports and failure dumps are written to `/tmp/reports`
(`ECO_REPORTS_DUMP_DIR`, or `ARTIFACT_DIR` when set) and survive the removal
of the tmp clone.

## Variables

All variables are optional; defaults are shown in parentheses. Pass them on
the make command line (`make e2e-tests VAR=value`) or in the environment
(`VAR=value make e2e-tests`) — both reach the test runner.

### WAO target variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `KUBECONFIG` | (required) | Kubeconfig of the target cluster. Always passed explicitly. |
| `E2E_SYSTEM_TESTS_REPO` | `https://github.com/openshift/rhwa-system-tests.git` | Repository cloned when no checkout is given. |
| `E2E_SYSTEM_TESTS_BRANCH` | `wao` | Branch cloned into the tmp dir. |
| `E2E_SYSTEM_TESTS_DIR` | (tmp clone) | Run an existing rhwa-system-tests checkout instead of cloning; the directory is kept. |
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

## Relation to CI

The prow job `install-wao-nmo-daily-aws` (openshift/release ci-operator
config `medik8s-workload-availability-operator-wao__5.0.yaml`, test step
`e2e-nmo`) runs this same `make e2e-tests` target in the
`quay.io/medik8s/system-tests:wao` image. The `ECO_*` values set in the job
match the defaults above, so a local run reproduces the CI test selection.
