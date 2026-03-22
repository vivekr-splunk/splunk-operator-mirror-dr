# GitLab Release Qualification Controller

This document describes the current controller slice for the GitLab-native SOK release and qualification flow.

## Purpose

The future-state operating model needs more than a translated release train. It needs:

- a checked-in cycle manifest
- an explicit lane-selection step
- a qualification record
- a compatibility publication plan

This controller slice is the first implementation of that model in `splunk-operator`.

## Checked-In Input

The controller reads:

- `release-process/cycle-template.env`

That file provides a reviewable cycle description instead of relying only on large manual trigger forms.

## Current Controller Jobs

Under `REHEARSAL_PIPELINE_MODE=qualification_lane`, the controller slice now includes:

1. `release-manifest-resolve-rehearsal`
2. `lane-select-rehearsal`
3. `qualification-report-rehearsal`
4. `compatibility-publish-rehearsal`

## Current Outputs

The controller emits artifacts under `rehearsal/release-controller/`:

- `release-cycle-manifest.json`
- `release-cycle.env`
- `lane-selection.json`
- `lane-selection.env`
- `qualification-report.md`
- `qualification-manifest.json`
- `compatibility-decision.json`
- `compatibility-record.json`
- `blocker-summary.json`
- `compatibility-publish-plan.json`
- `compatibility-publish-plan.md`

The status publication slice now turns those controller artifacts into two GitLab-native views:

- `pages`
  - publishes the current dashboard at the stable project Pages root
- `pages-cycle`
  - publishes one preserved dashboard per qualification or release pipeline at a path derived from:
    - `REHEARSAL_PIPELINE_MODE`
    - `CI_PIPELINE_ID`

That split means stakeholders can see both:

- the latest current state
- the exact status snapshot for a specific release or qualification cycle

## What This Solves

This closes several foundational gaps in the release and qualification model:

- the product repo now has a checked-in control input
- lane selection is explicit and artifact-backed
- qualification produces machine-readable disposition artifacts
- compatibility publication is now modeled as a first-class controller output
- the product-release path can carry an explicit `release/<version>` contract instead of assuming a direct `develop` to `main` promotion

The current controller also protects against false-green qualification summaries:

- if the downstream evidence jobs have not produced artifacts yet, the report stays at `qualified with caveats`
- it records the missing evidence jobs explicitly instead of claiming the baseline is already qualified

## What Still Remains

This is a controller bootstrap, not the final automation state. The product repo still needs:

- upstream watchers for `splcore/main` and `docker-splunk-internal`
- automatic digest discovery and pinning from upstream image readiness
- controller-driven triggering of the qualification and release families
- real publication to Jira and the GitLab-native status surfaces:
  - GitLab Pages current plus per-cycle dashboards for live cycle detail
  - org-managed `gitlab-slack` for transition alerts
- automated escalation from qualification disposition into the executable product-release lane
