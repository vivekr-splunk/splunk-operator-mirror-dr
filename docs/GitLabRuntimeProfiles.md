# GitLab Runtime Profiles

This document defines the current profile model for the long-running GitLab runtime families.

The purpose is to make EKS and Helm execution smaller, repeatable, and easier to schedule without relying on one monolithic long job for every validation path.

## EKS Integration Profiles

The EKS integration runtime is driven by `STAGING_INT_TEST_PROFILE`.

Supported profiles:

- `managersecret`
  - default profile
  - focus: `managersecret`
  - default skip: non-`integration` tests
  - default cluster sizing:
    - nodes: `1`
    - workers: `3`
- `smoke`
  - focus: `smoke`
  - default skip: none
  - default cluster sizing:
    - nodes: `1`
    - workers: `2`
- `appframework`
  - focus: `appframework`
  - default skip: non-`integration` tests
  - default cluster sizing:
    - nodes: `2`
    - workers: `5`
- `full`
  - focus: `integration`
  - default skip: none
  - default cluster sizing:
    - nodes: `2`
    - workers: `5`
- `custom`
  - achieved by setting:
    - `STAGING_INT_TEST_PROFILE=<custom-name>`
    - `STAGING_INT_TEST_FOCUS=<label-or-regex>`
    - optional:
      - `STAGING_INT_TEST_TO_SKIP`
      - `STAGING_INT_CLUSTER_NODES`
      - `STAGING_INT_CLUSTER_WORKERS`

## Helm / KUTTL Profiles

The Helm runtime is driven by `STAGING_HELM_TEST_PROFILE`.

Supported profiles:

- `smoke`
  - default profile
  - test dirs:
    - `./kuttl/tests/helm/s1`
    - `./kuttl/tests/helm/s1-with-operator`
    - `./kuttl/tests/helm/operator-with-ephemeral-volume`
- `clustered`
  - test dirs:
    - `./kuttl/tests/helm/c3`
    - `./kuttl/tests/helm/c3-with-operator`
    - `./kuttl/tests/helm/m4`
    - `./kuttl/tests/helm/m4-with-operator`
- `apps`
  - test dirs:
    - `./kuttl/tests/helm/c3-with-apps`
    - `./kuttl/tests/helm/c3-with-apps-private-link`
- `full`
  - test dir:
    - `./kuttl/tests/helm`
- `custom`
  - achieved by setting:
    - `STAGING_HELM_TEST_DIRS`
    - optional:
      - `STAGING_HELM_TEST_TIMEOUT`
      - `STAGING_HELM_TEST_PARALLEL`

## Why Profiles Exist

- the real EKS and Helm workflows have already proven they can exceed smaller timeout budgets
- production-grade GitLab CI should schedule smaller runtime modules intentionally
- profile-driven execution lets us keep GitHub-workflow traceability while moving toward fewer, more reusable GitLab runtime modules

## Recommended Usage

- MR validation:
  - start with `managersecret` for EKS and `smoke` for Helm
- nightly or scheduled validation:
  - run `appframework`, `clustered`, or `full` profiles
- release-readiness:
  - run the required profile set explicitly and capture artifacts per profile

## Example API Launches

EKS managersecret profile:

```bash
curl --request POST \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --header "Content-Type: application/json" \
  --data '{
    "ref": "gitlab-ci-core-bootstrap",
    "variables": [
      {"key":"REHEARSAL_PIPELINE_MODE","value":"eks_integration"},
      {"key":"STAGING_EXECUTE_BUILD_TEST_PUSH","value":"true"},
      {"key":"STAGING_EXECUTE_EKS_INTEGRATION","value":"true"},
      {"key":"STAGING_INT_TEST_PROFILE","value":"managersecret"}
    ]
  }' \
  "https://cd.splunkdev.com/api/v4/projects/266299/pipeline"
```

Helm clustered profile:

```bash
curl --request POST \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --header "Content-Type: application/json" \
  --data '{
    "ref": "gitlab-ci-core-bootstrap",
    "variables": [
      {"key":"REHEARSAL_PIPELINE_MODE","value":"helm_integration"},
      {"key":"STAGING_EXECUTE_BUILD_TEST_PUSH","value":"true"},
      {"key":"STAGING_EXECUTE_HELM_TEST","value":"true"},
      {"key":"STAGING_HELM_TEST_PROFILE","value":"clustered"}
    ]
  }' \
  "https://cd.splunkdev.com/api/v4/projects/266299/pipeline"
```
