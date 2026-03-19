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

## Not Yet Migrated

- image build and push jobs
- cosign signing and verification jobs
- vulnerability scan jobs
- nightly and scheduled jobs
- multi-cloud integration jobs
- ARM and distroless variant jobs
- release and bundle publication jobs
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
- The bias-language job installs the linter dependencies explicitly and runs the linter from its own checkout directory with an explicit error-file path to avoid GitHub-only assumptions in the helper tool.
- The `kubectl-splunk` job uses the actual package path `tools/kubectl-splunk` and forces `PIP_INDEX_URL=https://pypi.org/simple` so rehearsal execution is not coupled to local internal pip configuration.
- Additional workflow classes should be migrated incrementally and validated in staging before production cutover.
