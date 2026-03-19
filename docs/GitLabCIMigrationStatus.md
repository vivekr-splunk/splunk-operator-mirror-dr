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
  - unit tests
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
- Additional workflow classes should be migrated incrementally and validated in staging before production cutover.
