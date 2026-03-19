# GitLab CI Migration Status

## Current State

- Repository history has been imported into GitLab.
- The initial GitLab CI slice has been added.
- This first slice covers:
  - merge request pipelines
  - `main` branch pipelines
  - `develop` branch pipelines
  - formatting
  - vet
  - bias language scan
  - unit tests
  - `kubectl-splunk` Python tests
  - semgrep security scan
  - FOSSA dependency and license scan
  - JUnit test report publication
  - coverage artifact publication
- The remaining GitHub workflow files are now represented in GitLab CI as staging-safe rehearsal jobs.
- Those rehearsal jobs are intentionally plan-only by default:
  - they emit an artifact showing the source GitHub workflow, required `STAGING_*` variables, and the execution plan
  - they use an internal-registry-first policy for current execution
  - they do not push to DockerHub or production registries
  - they only become executable after staging-safe variables are loaded and a workflow-specific `STAGING_EXECUTE_*` flag is enabled
  - DockerHub and other public release destinations are deferred until the later pre-release and automated-release migration slice

## Not Yet Migrated

- concrete runtime implementation for the workflow-level rehearsal scaffolds
- staging registry publication and signing execution
- Trivy image-scan execution against staging images
- EKS, AKS, and GKE integration execution against staging clusters
- ARM and distroless execution against staging variant images
- release, bundle, and chart publication execution against staging destinations
- public-registry publication for pre-release and release workflows
- GitHub intake automation replacement

## Notes

- This file tracks the live rehearsal state in GitLab.
- The bootstrap CI file currently uses permissive `workflow:rules` so job execution can be proven before branch and MR gating is tightened.
- The bootstrap CI file is aligned to `go.mod` rather than the stale `.env` value, so it uses Go `1.24.2`.
- The bootstrap verify job follows the current GitHub workflow behavior by running `make fmt` without a post-format diff gate.
- The bootstrap pipeline now uses job-specific module flags: `format-and-vet` keeps writable module resolution, while `unit-tests` disables workspace mode and clears `GOFLAGS` before `make test`.
- Go caches now live outside the repository tree so `controller-gen` does not scan downloaded modules under `paths="./..."`.
- The pipeline also uses a new GitLab cache key and clears any restored `.cache/go` directory before job execution so stale archives from older rehearsals do not reintroduce repo-local module trees.
- The `envtest` helper in `Makefile` is pinned to `sigs.k8s.io/controller-runtime/tools/setup-envtest@v0.0.0-20240813183042-b901db121e1f`, which is the installable nested-module revision from the controller-runtime `v0.19.0` source tree. `@latest` now tracks a `go 1.25.0` tool module, while this repo's current rehearsal baseline is Go `1.24.2`.
- The `enterprise` package test suite exposed an environment-dependent assumption in `TestCreateAppDownloadDir`: the old invalid path `/xyzzz.txt` only failed on non-root shells. The test now uses a child path under a real file, and `createAppDownloadDir` now returns non-`ErrNotExist` stat errors instead of silently swallowing them.
- The first security slice adds `semgrep-scan` and `fossa-scan` jobs with GitHub-equivalent MR and `main`/`develop` trigger intent. These jobs are staging-safe: if `SEMGREP_APP_TOKEN` or `FOSSA_API_TOKEN` is not loaded in GitLab yet, they emit an explicit skip artifact instead of silently disappearing from the pipeline.
- Current registry policy for the rehearsal is internal-registry-only:
  - standard, distroless, ARM, smoke, integration, helm, and scan paths should use staging ECR, ACR, GAR, or internal bundle/chart targets only
  - DockerHub stays out of scope until the pre-release and release publication workflows are implemented intentionally later
- The bias-language job installs the linter dependencies explicitly and runs the linter from its own checkout directory with an explicit error-file path to avoid GitHub-only assumptions in the helper tool.
- The `kubectl-splunk` job uses the actual package path `tools/kubectl-splunk` and forces `PIP_INDEX_URL=https://pypi.org/simple` so rehearsal execution is not coupled to local internal pip configuration.
- The workflow-rehearsal scaffold template now clears inherited `before_script` and artifact `dependencies` so its `alpine` jobs do not try to run the repository-wide `apt-get` bootstrap intended for the Go-based jobs.
- The newly added workflow-level rehearsal jobs cover these GitHub workflow classes:
  - `build-test-push-workflow.yml`
  - `distroless-build-test-push-workflow.yml`
  - `int-test-workflow.yml`
  - `namespace-scope-int-workflow.yml`
  - `manual-int-test-workflow.yml`
  - `nightly-int-test-workflow.yml`
  - `int-test-azure-workflow.yml`
  - `int-test-gcp-workflow.yml`
  - `distroless-int-test-workflow.yml`
  - `helm-test-workflow.yml`
  - `arm-Ubuntu-build-test-push-workflow.yml`
  - `arm-Ubuntu-int-test-workflow.yml`
  - `arm-RHEL-build-test-push-workflow.yml`
  - `arm-RHEL-int-test-workflow.yml`
  - `arm-AL2023-build-test-push-workflow-AL2023.yml`
  - `arm-AL2023-int-test-workflow.yml`
  - `pre-release-workflow.yml`
  - `automated-release-workflow.yml`
  - `bundle-push-post-release.yml`
  - `release.yml`
  - `merge-develop-to-main-workflow.yml`
  - `cla-check.yml`
- These rehearsal jobs are intentionally conservative because no GitLab variables are loaded yet in the rehearsal project.
- Additional workflow classes should continue to move from scaffolded to fully executable and validated in staging before production cutover.
