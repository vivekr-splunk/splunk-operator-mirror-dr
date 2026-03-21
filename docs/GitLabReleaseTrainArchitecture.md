# GitLab Release Train Architecture

This document defines the target production-grade release train for the Splunk Operator GitLab migration.

It answers a narrower question than the general workflow review:

- how the existing GitHub release workflows fit together
- how they should be orchestrated in GitLab
- where manual approvals should remain
- where human intervention should be removed

For the approved upstream branch-cut, qualification, and lane-selection operating model that should feed this release train, use the reviewed decision records in `sok/decision-records/migration`.

## Repository Ownership Rule

The release train must live in the same authoritative `splunk-operator` GitLab project as the source code and runtime validation.

- release governance, RC build, validation, chart publication, and bundle publication should be driven from `splunk-operator`
- checked-in release scripts and CI modules should remain in the same repository
- a separate release-control or testing repository is not the target steady state

Reference repos can still inform the design, but they should not become the day-to-day source of truth for the operator release process.

## Operating Model Decision

The release-process review changes the target from a single quarterly-style release automation path to a two-lane operating model:

1. `Monthly qualification lane`
   - default lane
   - validate the current supported SOK baseline against the new Splunk monthly release
   - publish a qualification record and compatibility decision
   - do not mint a new SOK semver unless a real operator delta is required
2. `Product release lane`
   - exception lane
   - cut a new SOK release only when qualification fails, a planned operator change must ship, or support/security policy requires a new artifact

That means the final GitLab pipeline cannot be only a direct translation of the old GitHub release workflows.
It must support both qualification and product release as first-class lanes.

## Develop Check-In Rule

The release train must not become the default `develop` pipeline.

- `develop` push pipelines stay fast and developer-oriented
- release-train stages run from the controller-driven qualification lane, the product-release lane, `main`, `release/<version>`, or explicit release triggers
- MR pipelines can stay broader than `develop` pushes, but they still exclude the product-release train

## Source Workflow Mapping

The current GitHub release family is split across these files:

- `merge-develop-to-main-workflow.yml` as the legacy source workflow name
- `pre-release-workflow.yml`
- `automated-release-workflow.yml`
- `release.yml`
- `bundle-push-post-release.yml`

Those are not five unrelated workflows. They form one release train.

They also represent only the product-release lane.

The release-process documents make it clear that SOK also needs a lower-cost qualification lane that:

- detects the target Splunk monthly release
- selects the current SOK baseline automatically
- runs a qualification matrix
- publishes a compatibility record
- escalates into a product release only if the qualification lane cannot pass

That lane does not exist as a first-class GitHub workflow today and must be added in GitLab.

## Qualification Lane Requirements

The monthly qualification lane should produce:

- one machine-readable qualification manifest
- one human-readable qualification report
- one compatibility disposition:
  - `qualified with current SOK`
  - `qualified with caveats`
  - `new SOK release required`
- blocker links and owner routing
- compatibility-matrix update output

The minimum qualification matrix from the release-process documents is:

- install validation
- upgrade validation
- smoke validation
- latest 3 Splunk Enterprise version checks
- architecture-specific or compliance suites required by support policy

This lane should be cheaper than a full product release and should be the monthly default.

## Upstream Signal Integration

The qualification lane should start from upstream release signals, not from an operator release-time event.

Observed upstream systems already provide two useful signals:

- `splcore/main`
  - protected `release/*` and `patch/*` branches
  - release-oriented variables such as `RELEASE_COMMIT_SHA_MAIN`, `RELEASE_COMMIT_REF_NAME`, and `RELEASE_BUILD_VERSION`
- `core-ee/docker-splunk-internal`
  - unpublished Enterprise image builds keyed by `UNRELEASED_SPLUNK_SHA`
  - internal Artifactory-backed Docker publication for unreleased Enterprise images

That means the desired automation is:

1. detect planned and actual branch-cut from the upstream Splunk release flow
2. record the target Splunk branch and SHA in the SOK release manifest
3. detect unpublished Enterprise image availability
4. automatically start the SOK qualification lane
5. escalate into the product-release lane only if qualification cannot carry the release

SOK should therefore qualify early, based on image readiness, instead of waiting for the formal SOK release moment.

## Target GitLab Release Phases

### 1. Release Governance

- source:
  - legacy source reference: `merge-develop-to-main-workflow.yml`
- target:
  - create `release/<version>` from an approved `develop` commit
  - create a GitLab MR from `release/<version>` to `main`
  - attach release metadata
  - record reviewer/approval requirements
  - produce RC candidate metadata

### 2. Pre-Release Preparation

- source:
  - `pre-release-workflow.yml`
- target:
  - update versions in docs, Helm, bundle metadata, manifests, and `.env`
  - generate changelog and release notes drafts
  - create a dedicated release branch or MR
  - publish only staging-safe artifacts during rehearsal

### 3. RC Build And Validation

- source:
  - legacy source reference: `merge-develop-to-main-workflow.yml`
  - `automated-release-workflow.yml`
- target:
  - build RC UBI and distroless images
  - publish RC images to staging/internal release registries
  - generate RC release artifacts
  - attach artifacts to GitLab jobs or draft GitLab releases

### 4. Final Release Publication

- source:
  - `automated-release-workflow.yml`
- target:
  - promote RC images to final release tags
  - sign and verify release images
  - generate release manifests
  - create the canonical GitLab release object
  - keep official public publication downstream of GitLab release success

### 5. PSR Release Qualification

- source:
  - `psr/k8s-operator`
- target:
  - trigger the PSR upgrade, app-framework, and performance suites against the release candidate
  - collect downstream PSR pipeline URLs, verdicts, and owner triage
  - make PSR disposition part of the RC-to-GA approval packet

### 6. Chart Publication And Verification

- source:
  - `release.yml`
- target:
  - package charts in GitLab
  - publish charts to an internal OCI chart repository first
  - validate installability and publication metadata from that internal OCI location
  - generate a legacy index only when a compatibility consumer still requires it
  - run chart publication or certification checks before official publication
  - later mirror to official chart destinations as a downstream output

### 7. Bundle And Catalog Publication

- source:
  - `bundle-push-post-release.yml`
- target:
  - build bundle and catalog artifacts
  - push them to staging bundle/catalog destinations first
  - validate pull/install metadata before public publication

### 8. Preflight Certification Gates

- source:
  - `openshift-preflight`
- target:
  - run operator-bundle preflight on the bundle image
  - run container preflight on the release images that need Red Hat certification
  - use a partner-accessible OCI registry plus Docker auth for certification inputs; do not assume world-public images are required
  - preserve full preflight evidence as a release gate before ecosystem submission

### 9. Ecosystem Submission

- source:
  - `community-operators`
  - Red Hat partner certification workflow
- target:
  - prepare PR-ready payloads for community and upstream OperatorHub catalogs
  - prepare the Red Hat partner-portal or certified-operator submission pack
  - keep external review and approval clearly outside GitLab control while automating everything up to submission

## Automation Principles

- GitLab is the authoritative release control plane.
- `splunk-operator` is the authoritative release project, not just the source project.
- Qualification should be cheaper than release and should be the default monthly path.
- `develop` push should remain a fast check-in lane and must not be forced through the release train.
- Public DockerHub or public ECR publication must never happen before GitLab has produced the canonical release result.
- PSR is a release-quality gate, not a post-release report.
- RC and final release promotion should be one linked GitLab release train, not separate manual islands unless governance requires a manual approval gate.
- GitHub release publication is a mirrored downstream output, not the authoritative release creation step.
- Version mutation, artifact generation, chart release, PSR qualification, certification, and bundle publication should be checked-in scripts or templates, not large inline shell bodies.
- Decision logic should live in scripts or a controller, not primarily in CI YAML or manual workflow-dispatch inputs.
- Internal publication and validation should happen before any external ecosystem mutation or public publication.
- Red Hat preflight and certification do not require world-public images, but they do require registries that Red Hat systems can access with supplied credentials.

## Target GitLab Lane Shape

### Lane A: Monthly qualification

The qualification lane should run:

1. release signal intake
2. Splunk image detection and digest pinning
3. SOK baseline selection
4. qualification manifest generation
5. fast-path validation matrix
6. rerun and failure bucketing
7. qualification report publication
8. compatibility update output
9. escalation into the product release lane only if needed

### Lane B: Product release

The product-release lane should run:

1. governance and release MR creation
2. pre-release content mutation and validation
3. RC image build and artifact creation
4. RC validation gates
5. PSR release qualification
6. final release publication
7. chart publication and verification
8. bundle and catalog publication
9. preflight certification gates
10. ecosystem submission preparation
11. mirror and public artifact synchronization after approvals

## Expected GitLab Release Train Shape

The production target is one GitLab release control system with two orchestrated lanes:

1. monthly qualification lane
2. product release lane

The product-release lane contains the phases listed above for RC and GA publication.

## Human Intervention Boundaries

Manual approval is appropriate for:

- release MR approval
- RC-to-final promotion approval
- rollback decision

Manual execution is not the desired steady state for:

- selecting the lane
- entering release parameters into CI forms
- preparing qualification records
- updating the compatibility matrix
- opening a direct `develop` to `main` promotion path for a product release
- version file updates
- artifact generation
- release note draft creation
- chart packaging
- bundle and catalog push
- public mirror synchronization

## What The Current Rehearsal Already Covers

- release-cycle manifest generation
- lane selection between `qualification` and `product-release`
- qualification-report artifact generation
- pre-release dry-run scripting
- automated-release dry-run scripting
- PSR release-qualification plan generation
- chart package dry-run scripting
- bundle/catalog dry-run scripting
- preflight certification plan generation
- ecosystem submission plan generation
- internal-only staging guardrails

## What Must Still Be Added For Production Readiness

- automatic Splunk image discovery and digest pinning
- automatic baseline selection
- compatibility-matrix publication
- blocker bucketing and rerun automation
- auto-created work items and status updates for Jira plus the GitLab-native status surfaces:
  - GitLab Pages for live cycle detail
  - org-managed `gitlab-slack` for transition alerts
- automatic escalation from qualification failure to product-release lane
- official Helm publication away from GitHub Pages
- executable PSR downstream triggers and verdict ingestion
- executable preflight bundle and container gates
- executable OperatorHub and Red Hat submission automation
- final public promotion path only at the end of the product-release lane

## Current Rehearsal Status

- release jobs are represented in `.gitlab-ci.yml`
- release family structure exists
- staging-only guardrails are already documented in the workflow metadata
- the release train is not yet fully implemented as executable GitLab runtime scripts
- the qualification lane does not yet exist as a first-class GitLab controller path

## Diagrams

Source and PNG files:

- [gitlab-release-train-flow.puml](diagrams/gitlab-release-train-flow.puml)
- [gitlab-release-train-flow.png](diagrams/gitlab-release-train-flow.png)
- [gitlab-release-train-components.puml](diagrams/gitlab-release-train-components.puml)
- [gitlab-release-train-components.png](diagrams/gitlab-release-train-components.png)

![GitLab release train flow](diagrams/gitlab-release-train-flow.png)

![GitLab release train components](diagrams/gitlab-release-train-components.png)
