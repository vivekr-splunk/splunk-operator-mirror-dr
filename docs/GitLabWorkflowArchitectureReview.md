# GitLab Workflow Architecture Review

## Purpose

This document answers a narrower question than the migration runbook:

- Have all GitHub workflow classes been checked?
- Are they mapped into GitLab CI in a modular way?
- Is the current GitLab CI design already production-grade?
- What must change so the final GitLab workflow model minimizes human intervention?

Use the companion diagram set in:

- `docs/GitLabCIArchitectureDiagrams.md`

when you want the visual runtime flow and component partitioning instead of the written assessment.

Use these companion design docs when you need the narrower family-level view:

- `docs/GitLabRuntimeProfiles.md`
- `docs/GitLabReleaseTrainArchitecture.md`

## Direct Answer

Not yet fully.

- The GitHub workflow set has been reviewed and every workflow class has been accounted for.
- Most workflow classes are now represented in `.gitlab-ci.yml`.
- Some GitHub workflows are intentionally merged into shared GitLab jobs instead of being mapped one-to-one.
- The current GitLab CI file is still a rehearsal-first transitional design, not the final production-grade modular architecture.
- There is still duplication in the current GitLab CI definition, especially across workflow-scaffold jobs.
- The long-running EKS and Helm paths are now real, but they are not yet partitioned in the cleanest production form.

So the answer is:

- coverage review: yes
- production-grade modular final state: not yet

## Structural Refactor Status

The GitLab CI file has now moved one step closer to the desired production model.

The current branch introduces reusable hidden templates for:

- rule families
- build-family jobs
- image-scan-family jobs
- long-running integration families
- ARM integration families
- release-family jobs
- administration-family jobs
- shared standard-build artifact consumers

That matters because the earlier rehearsal file was still duplicating:

- stage declarations
- timeout policy
- interruptibility policy
- MR / branch / web / schedule rule blocks
- downstream `needs` / `dependencies` wiring

So the architecture is now better than a one-job-per-GitHub-workflow translation.
It is still not the final state, but the file is now being organized around workflow families and runtime behavior rather than only historical GitHub filenames.

## GitHub Workflow Coverage

### Directly Mapped To Named GitLab Workflow-Rehearsal Jobs

- `build-test-push-workflow.yml`
- `distroless-build-test-push-workflow.yml`
- `int-test-workflow.yml`
- `manual-int-test-workflow.yml`
- `nightly-int-test-workflow.yml`
- `namespace-scope-int-workflow.yml`
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

### Intentionally Merged Into Shared GitLab Jobs Instead Of One-To-One Workflow Jobs

- `bias-language-workflow.yml`
  - mapped into `bias-language`
- `kubectl-splunk-workflow.yml`
  - mapped into `kubectl-splunk-tests`
- `prodsec-workflow.yml`
  - mapped into:
    - `semgrep-scan`
    - `fossa-scan`

This is the correct direction. Those three do not need one GitLab workflow per original GitHub file.

## What The GitHub Workflows Actually Represent

The GitHub workflow set is not 25 unrelated automations. It is a smaller number of workflow families:

### 1. Baseline CI Family

- formatting
- vet
- unit tests
- `kubectl-splunk` tests
- bias-language scan
- security scans

### 2. Build And Image Assurance Family

- build operator image
- build distroless image
- build ARM variants
- sign and verify images
- run image vulnerability scans

### 3. EKS Runtime Test Family

- smoke tests from `build-test-push-workflow.yml`
- integration tests from `int-test-workflow.yml`
- nightly integration tests
- namespace-scope integration tests
- manual integration tests
- distroless integration tests
- ARM integration tests

These are mostly the same runtime pattern with different:

- trigger types
- image variants
- cluster-wide vs namespace-scope flags
- focus filters
- schedule/manual behavior
- post-run publication behavior

### 4. Cross-Cloud Runtime Test Family

- Azure integration
- GCP integration

These are cloud-specific variants of the same operator-runtime test pattern.

### 5. Helm / KUTTL Family

- `helm-test-workflow.yml`
- basic SVA style behavior already seen in the internal `splunk-operator-cicd` repo

This is its own runtime family and should not be modeled as a release job.

### 6. Release Train Family

- `pre-release-workflow.yml`
- `merge-develop-to-main-workflow.yml`
- `automated-release-workflow.yml`
- `release.yml`
- `bundle-push-post-release.yml`

These are not five independent workflows in the desired GitLab state.
They are one release train with different phases.

### 7. Public Intake / Compliance Family

- `cla-check.yml`

This should remain on the GitHub public intake surface, not in the GitLab authoritative merge path.

## Current GitLab CI Architecture Assessment

## What Is Good Right Now

- GitLab CI already uses modular checked-in scripts under `hack/gitlab-ci/`.
- Shared helpers exist in `hack/gitlab-ci/lib/rehearsal-common.sh`.
- The build, Trivy, EKS integration, and Helm runtime paths are now real executable code, not only placeholders.
- The CI uses internal images and internal registry-first behavior, which is closer to the desired production posture.
- GitHub-only workflows like bias-language, `kubectl-splunk`, and prodsec are already being collapsed into shared GitLab jobs, which reduces duplication.

## What Is Not Yet Production-Grade

### 1. Too Many Workflow-Named Scaffold Jobs

The current `.gitlab-ci.yml` still contains many workflow-shaped scaffold jobs whose main purpose is to represent the original GitHub files.

That is useful for migration tracking, but it is not the clean final automation model.

Production GitLab CI should be organized around execution families, not around historical GitHub filenames.

The recent reusable-family refactor reduces this problem, but it does not eliminate it yet.

A practical improvement has now landed on top of that refactor:

- namespace-scope, manual, and nightly EKS workflows now reuse the checked-in EKS runtime script instead of remaining plan-only placeholders
- chart release now has a dry-run packaging script instead of remaining documentation-only

### 2. Build / Smoke / Integration Are Not Yet Cleanly Separated Into Reusable Modules

Right now:

- `build-test-push-workflow.yml` has been split into:
  - base CI jobs
  - build job
  - Trivy scan
- but the smoke portion is not yet modeled as a first-class GitLab runtime family

The smoke path should become a reusable runtime module, not remain implied by the old GitHub file name.

### 3. Release Family Is Still Scaffolded, Not Orchestrated

The release train is currently represented, but not yet implemented as a linked GitLab release flow.

The desired release-phase orchestration is now documented separately in:

- `docs/GitLabReleaseTrainArchitecture.md`

Production target should be one orchestrated release pipeline with phases:

- promote develop to release-ready state
- create release MR
- build RC images
- validate RC
- promote RC to release
- generate release artifacts
- publish GitLab release
- publish charts
- publish bundles/catalogs

Not separate manual islands unless governance truly requires it.

### 4. Some Runtime Families Should Be Parameterized, Not Cloned

The following are variants of the same pattern and should eventually share one reusable job template plus inputs:

- `int-test-workflow`
- `manual-int-test-workflow`
- `nightly-int-test-workflow`
- `namespace-scope-int-workflow`
- `distroless-int-test-workflow`
- ARM integration variants

Current state still keeps these as separate workflow-shaped jobs.

### 5. Long-Running Suites Need Explicit Partition Strategy

We now know from live execution:

- EKS integration is real
- Helm KUTTL is real
- both can exceed several hours

Production-grade automation requires explicit partitioning strategy:

- by focus group
- by architecture
- by deployment type
- by schedule vs MR vs release context

Without that, the GitLab design will be correct but operationally inefficient.

The current interim partition model is now documented in:

- `docs/GitLabRuntimeProfiles.md`

## Target Production GitLab Workflow Model

The final GitLab design should be organized like this.

### A. Base MR / Branch CI Pipeline

Always-on and authoritative:

- format
- vet
- unit tests
- `kubectl-splunk` tests
- bias-language
- Semgrep
- FOSSA
- optional fast static policy checks

This should gate merge requests.

### B. Build And Image Assurance Module

Reusable module with parameters:

- image variant:
  - standard
  - distroless
  - arm-ubuntu
  - arm-rhel
  - arm-al2023
- target registry
- sign/verify enabled or disabled
- scan enabled or disabled

Outputs:

- image ref
- digest
- scan artifacts
- signing artifacts when enabled

### C. Runtime Test Module

Reusable module with parameters:

- cloud:
  - EKS
  - AKS
  - GKE
- deployment type:
  - operator
  - helm
- architecture:
  - amd64
  - arm64
- scope:
  - cluster-wide
  - namespace-scope
- suite class:
  - smoke
  - integration
  - nightly
  - helm-kuttl
- focus selector
- existing-cluster vs ephemeral-cluster

This is where most current duplication should be removed.

### D. Release Train Pipeline

One linked release automation family:

- release-prep
- release-mr creation
- rc-build
- rc-validate
- release-promote
- release-artifact generation
- GitLab release creation
- chart publication
- bundle/catalog publication

Human intervention should be limited to explicit approval gates where required.

### E. Public Intake Automation

Separate from source-of-truth CI:

- GitHub issue intake
- GitHub PR intake
- CLA / compliance checks
- backlink creation into GitLab

This should not be mixed into the authoritative GitLab build/release pipeline.

## Duplication That Should Be Reduced

Current duplication that is acceptable for rehearsal but should be reduced before production:

- separate workflow-named integration jobs with mostly the same structure
- repeated `WORKFLOW_*` metadata blocks for jobs that are really just parameter variants
- release workflows represented as separate placeholders instead of one release train

Recommended reduction approach:

- keep `WORKFLOW_*` metadata only in the migration-tracking layer
- create reusable hidden job templates for:
  - build family
  - runtime test family
  - release family
- move workflow-specific differences into variables, not separate shell bodies
- keep checked-in shell scripts only for real runtime logic, not per-workflow scaffolding

## What We Should Treat As The Final Minimal Human-Intervention Model

### Merge Request

- MR opens
- authoritative GitLab CI runs automatically
- approvals + code owners + pipeline success gate merge

### Main / Develop Branch

- protected-branch pipeline runs automatically
- no GitHub Actions build/release authority remains

### Nightly

- scheduled GitLab pipeline runs selected runtime partitions automatically

### Release

- release engineer triggers one GitLab release pipeline or approves the final promotion gate
- GitLab handles RC, artifact generation, release object creation, chart publication, and bundle publication
- GitHub only mirrors or serves public intake

### External Contributions

- GitHub intake automation opens linked GitLab records
- internal maintainers process and merge only in GitLab

## Current Conclusion

We have checked the workflow set well enough to say this clearly:

- all GitHub workflow classes have been examined
- most are represented in GitLab CI already
- some are correctly merged into shared GitLab jobs
- the current GitLab CI is not yet the final modular production architecture
- the biggest remaining production-grade work is:
  - collapse workflow-shaped duplication into reusable runtime families
  - turn the release family into one orchestrated release train
  - finish runtime partitioning for EKS and Helm
  - keep public intake separate from authoritative CI

## Immediate Next Implementation Priority

1. Finish the real long-runtime EKS and Helm executions with the corrected timeout policy.
2. Split smoke, integration, and helm runtime logic into reusable modules instead of workflow-shaped scaffolds.
3. Redesign the release family as one linked GitLab release train.
4. Keep `cla-check` and GitHub intake automation outside the authoritative GitLab merge/release path.
