# Makefile rewrite — context for further work

Context from the 2026-11-10 session that rewrote `Makefile` from scratch. The previous
Makefile was moved to `Makefile.old` (kept for reference/diffing only — not wired into
anything, safe to delete once the new Makefile has been used for a while).

## Why

User asked to model WAO's `Makefile` on `oadp-operator/Makefile` as closely as possible.
Scope was narrowed via clarification:

- `deploy-olm` / `undeploy-olm` (OADP-style, full CatalogSource+Subscription install path)
  — wanted, added new.
- Tool version pinning + tool-install robustness (`versions` target, `CHECK_TOOL_VERSION`
  diagnostic, `go-install-tool`) — wanted, ported/kept.
- OADP's e2e/cloud-provider test infrastructure (AWS/GCP/Azure STS flows, HCP, virt/kubevirt,
  must-gather, non-admin-controller/VMFR/kubevirt-datamover manifest sync, catalog-test-upgrade)
  — explicitly **not** wanted; WAO's e2e testing lives in a separate repo.

## What changed structurally (OADP-style additions)

- Banner-commented tool-version block, `help`, `versions`, `check-go` targets, and the
  `CHECK_TOOL_VERSION` macro (prints installed-vs-pinned tool versions, auto-installs on
  mismatch/missing).
- `CONTAINER_TOOL` auto-detect: prefers `podman`, falls back to `docker`, hard errors if
  neither is present (OADP prefers docker first; flipped order to match WAO's existing default).
- `SHELL = /usr/bin/env bash -o pipefail` + `.SHELLFLAGS = -ec` (abort recipes on first
  failing command/pipe stage).
- New `##@ Cluster Deployment (OLM)` section: `login-required`, `OC_CLI`/`CLUSTER_TYPE`
  detection, `GIT_REV`, `TTL_DURATION`, `CATALOG_SOURCE_NAME` (`wao-poc-catalog`),
  `CATALOG_SOURCE_NAMESPACE` (`openshift-marketplace`), `OPERATOR_GROUP_NAME`
  (`workload-availability`), and the `deploy-olm`/`undeploy-olm` targets themselves.
  - `deploy-olm` builds operator/bundle/catalog images tagged for `ttl.sh` (keyed by
    `GIT_REV`), in a **throwaway `mktemp -d` copy of the repo** (OADP's `DEPLOY_TMP` trick)
    so the working tree's `bundle/` and `config/manager/kustomization.yaml` are never
    mutated by a deploy. Then applies `config/catalog/catalogsource.yaml` (via the existing
    `catalog-source` target) and `config/catalog/subscription.yaml`, with timeout-guarded
    polling for CatalogSource readiness, InstallPlan, CSV existence, CSV success — mirrors
    OADP's wait-loop style.
  - `undeploy-olm` deletes Subscription/CSV/CatalogSource/OperatorGroup only. CRDs, operand
    CRs and the namespace are left — full teardown is `hack/wao-purge.sh`.
  - This is a **second**, independent cluster-install path alongside the `dev-olm-deploy` /
    `dev-olm-undeploy` targets required by `AGENTS.md` (which come from the shared
    `medik8s/tools` `dev.mk` and install via `operator-sdk run bundle`, no catalog/subscription
    involved). Keep both — they test different things: `dev-olm-deploy` is the fast
    iterate-and-reinstall loop; `deploy-olm` exercises the real OperatorHub-style
    catalog+subscription flow.

## What was deliberately NOT ported from OADP

- **`BRANCH_VERSION` + `go-install-tool-versioned`** (OADP's scheme of installing
  controller-gen/kustomize/golangci-lint into a branch-namespaced subdir with a version-aware
  reinstall check, then symlinking to the plain path). This was tried and **reverted** — it
  broke `test/offline/build_preparation_test.go::TestDevBuildPreparesOperandsAfterLazyToolsDownload`,
  which pre-stages a `kustomize` binary directly at `$(LOCALBIN)/kustomize` and mocks `go` to
  reject any subcommand other than `env`/`run` (exits 99 with `unexpected-go-command`
  otherwise). Moving `KUSTOMIZE` off that exact path made the real install recipe fire and
  call `go version -m` / `go install`, which the mock rejects.
  - **If you want this robustness back**, the offline test fixture would need updating too
    (it's in `test/offline/build_preparation_test.go`, function `buildFixture`) — don't just
    change the Makefile again without touching that test.
  - Net effect: `controller-gen`, `kustomize`, `golangci-lint` still use the original plain
    `$(LOCALBIN)/<tool>` + `go-install-tool` (file-exists check only, **no** version-mismatch
    detection — a pre-existing, accepted limitation, not something introduced by this rewrite).
- `bundle-community-okd` / `add-ocp-annotations` (OADP-specific "Community Edition" CSV
  display-name + OCP annotation targets). Grepped the repo — unused anywhere (no CI, docs, or
  script references `OCP_VERSION`, which these targets need). Dropped as dead/unfinished
  rather than carried forward.
- `nullables` / `nullable-crds-*` (OADP's DPA CRD nullable-field patching). Not applicable —
  WAO has no equivalent CRD fields.
- SED/`codecov` machinery, cloud-provider env wiring, `catalog-test-upgrade`,
  `update-non-admin-manifests`/`update-vmfr-manifests`/`update-kubevirt-datamover-manifests`
  style "pull RBAC from a sibling repo" targets — all OADP/Velero-specific, no WAO analogue.

## Gotcha discovered while testing

`IMAGE_REGISTRY` is `?=`-assigned, so if it's already exported in your shell (e.g. a personal
`quay.io/<you>` default some devs keep in their profile), `bundle`/`bundle-reset` will
regenerate the CSV/kustomization with *your* registry, creating a spurious diff against the
committed bundle. This is pre-existing Makefile behavior (not introduced by this rewrite) —
when diagnosing a `verify-diff.sh`/`test` failure, check `env | grep IMAGE_REGISTRY` before
assuming the Makefile is broken. Run `env -u IMAGE_REGISTRY make test` to get a clean baseline.

## Verification performed this session

All run against a clean tree (`IMAGE_REGISTRY` unset):

- `make help` — target listing renders correctly under the new `##@` sections.
- `make versions` — bootstrapped every pinned tool from scratch (controller-gen, opm,
  golangci-lint, kustomize, yq, operator-sdk) and confirmed a second run reports
  "already installed" / "matches Makefile" for all of them.
- `make verify-operand-manifests test-offline` — passes (this is what CI's `test.yml` runs).
- `make check` — lint (0 issues), import order, operand verification all pass.
- `make test` — unit tests pass (85.4% coverage on `internal/controller`), bundle
  regenerates **byte-identical** to the committed bundle, `bundle-validate` passes.
  `verify-no-changes` only flagged the Makefile rename itself (expected, uncommitted at time
  of testing).
- `make -n deploy-olm` / `make -n undeploy-olm` (dry run with fake `CLUSTER_TYPE`/`OC_CLI`) —
  confirmed correct expansion of namespace/catalog-source/subscription names and no Make
  syntax errors. **Not** exercised against a real cluster — no disposable cluster was
  available/authorized in this session. Do that before relying on `deploy-olm` for real.

## Possible follow-ups (not done, not asked for)

- Delete `Makefile.old` once confident, or keep a release or two for diffing.
- Exercise `deploy-olm`/`undeploy-olm` against an actual disposable OpenShift cluster with
  classic OLM (per `AGENTS.md`'s cluster-work rules: explicit kubeconfig, confirmed cluster,
  no real remediation objects).
- Consider whether `hack/wao-make_and_deploy.sh` / `hack/wao-purge.sh` /
  `hack/olmv1-make-and-deploy-wao.sh` (personal dev scripts with hardcoded
  `quay.io/jwmatthews` registry and a hardcoded kubeconfig filename) should be trimmed or
  pointed at the new `deploy-olm`/`undeploy-olm` targets now that equivalent generic
  machinery exists in the Makefile.
