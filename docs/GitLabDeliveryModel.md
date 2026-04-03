# GitLab Delivery Model

This is the single long-term process document for how `sok/splunk-operator` works in GitLab.

It replaces the migration-status and design-review style GitLab documents as the steady-state reference for:

- development workflow
- qualification workflow
- product release workflow
- GitHub mirror and intake boundaries

Migration logs, rehearsal notes, and architecture review write-ups should stay outside the long-term repo surface.

## Operating Principles

- GitLab is the authoritative source of truth for source, CI, qualification, and release.
- GitHub remains mirror and intake only after cutover.
- The same `splunk-operator` repository owns source code, runtime validation, and release automation.
- Development, qualification, and release are separate flows with different cost and approval expectations.
- Qualification is the default monthly path. New SOK release is the exception path.

## Pipeline Families

| Flow | Trigger | Purpose | Typical outputs |
|---|---|---|---|
| Merge request / development | MR open or update | Fast authoritative engineering validation | test results, scan results, image metadata for downstream lanes |
| Protected branch | push to protected branch | Re-validate merged code on the authoritative branch | branch pipeline status, repeatable build/test evidence |
| Nightly / scheduled runtime | schedule | Run broader runtime partitions that are too expensive for normal MR gating | long-running runtime evidence, runtime trend data |
| Monthly qualification | qualification controller lane | Decide whether the current SOK baseline supports the target Splunk release | qualification report, compatibility decision, per-cycle Pages snapshot |
| Product release | release lane | Produce a new SOK release when qualification cannot carry the target or when planned product change must ship | RC and GA artifacts, GitLab release, chart and bundle publication artifacts |
| GitHub intake and mirror | GitHub events and mirror sync | Keep GitHub as downstream intake and visibility surface only | intake issues/MRs, mirror parity status |

## Development Workflow

The development path should stay fast and developer-oriented.

1. A contributor opens or updates a merge request in GitLab.
2. The base MR pipeline runs the authoritative always-on checks:
   - `format-and-vet`
   - `bias-language`
   - `unit-tests`
   - `kubectl-splunk-tests`
   - `semgrep-scan`
   - `fossa-scan`
3. Build and runtime modules run according to the active pipeline mode and branch policy. The normal intent is:
   - fast validation on MR pipelines
   - broader runtime coverage on dedicated lanes, schedules, or explicit execution paths
4. Code owner approval, reviewer approval, and pipeline success gate merge.
5. The protected branch pipeline re-validates the merged result on the authoritative branch.

Development flow should not run the full release train by default.

## Build And Runtime Modules

The development and qualification flows reuse the same build and runtime modules rather than maintaining separate per-workflow implementations.

### Build and image assurance

The reusable build family covers:

- standard image build
- distroless build
- ARM build variants
- Trivy image scan

Expected reusable outputs:

- pushed image reference
- digest
- scan artifacts

### Runtime validation

The reusable runtime family covers:

- EKS operator validation
- AKS validation
- GKE validation
- Helm / KUTTL validation
- namespace-scope and nightly variants where still needed

The target model is parameterized runtime execution, not a large set of workflow-shaped clones.

## Runtime Profiles

Long-running suites are intentionally partitioned into smaller profiles so MR, nightly, qualification, and release flows can pick the right coverage level.

### EKS profiles

Driven by `STAGING_INT_TEST_PROFILE`:

- `managersecret`
- `smoke`
- `appframework`
- `full`
- `custom`

### Helm profiles

Driven by `STAGING_HELM_TEST_PROFILE`:

- `smoke`
- `clustered`
- `apps`
- `full`
- `custom`

Recommended usage:

- MR validation: smaller profiles such as `managersecret` and `smoke`
- nightly and scheduled validation: broader profiles such as `appframework`, `clustered`, or `full`
- release readiness: explicit profile selection based on the release gate set

## Monthly Qualification Workflow

Monthly qualification is the default operating path for SOK.

The goal is to prove that the currently supported SOK baseline works with the upcoming Splunk monthly release without automatically minting a new SOK version.

High-level flow:

1. Resolve the checked-in release-cycle input.
2. Select the lane and record the cycle manifest.
3. Pin the target Splunk release context and choose the SOK baseline under test.
4. Run the required validation matrix using the selected runtime profiles.
5. Publish the qualification report and compatibility decision.
6. Publish GitLab-native status views, including stable current Pages output and preserved per-cycle Pages output.
7. End in one of these dispositions:
   - `qualified with current SOK`
   - `qualified with caveats`
   - `new SOK release required`

The qualification controller is responsible for making the lane decision explicit and artifact-backed. It should not rely only on ad hoc manual CI variables.

## Product Release Workflow

Product release is the exception lane. It is used when:

- qualification cannot support the target Splunk release
- a planned SOK code change must ship
- support, compliance, or security policy requires a new SOK release

High-level flow:

1. Create and approve the release input or release MR.
2. Run pre-release content updates and validation.
3. Build release candidate images and release artifacts.
4. Run RC validation gates, including required runtime and downstream gates.
5. Promote the approved candidate to the final release.
6. Create the canonical GitLab release record and release assets.
7. Publish charts, bundles, and other release artifacts to approved destinations.
8. Run required certification or ecosystem submission preparation.
9. Mirror or publish downstream public outputs only after the GitLab release path is complete.

Manual approval should remain only where governance requires it, such as:

- release MR approval
- RC to GA approval
- rollback decision

## GitHub Intake And Mirror

GitHub is not part of the authoritative merge or release path after cutover.

Its steady-state role is:

- downstream mirror for visibility and compatibility
- issue and PR intake surface for external contributors

Expected behavior:

- GitHub intake automation opens or links the corresponding GitLab records
- maintainers review and merge only in GitLab
- GitHub release and mirror outputs remain downstream of GitLab success

## Human Intervention Boundaries

Human approval is expected for:

- merge request approval
- release approval gates
- rollback decisions

Human execution should not be the normal steady state for:

- lane selection
- release metadata preparation
- compatibility report generation
- routine chart packaging
- routine bundle publication
- routine mirror synchronization

## Diagrams

Reference diagrams remain under `docs/diagrams/`:

- `gitlab-ci-runtime-flow.png`
- `gitlab-ci-component-architecture.png`
- `gitlab-release-train-flow.png`
- `gitlab-release-train-components.png`

Use them as supporting visuals for this document rather than as separate primary documentation.
