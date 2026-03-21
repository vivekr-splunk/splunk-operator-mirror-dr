# Release Process Artifacts

This directory holds living implementation artifacts for the GitLab release and qualification control plane.

Keep here:

- checked-in cycle manifest inputs
- controller-facing release and qualification templates
- files consumed directly by the product-repo GitLab CI controller jobs

Do not keep here:

- reviewed governance decisions
- official migration plans
- approval-only runbooks

Those durable reviewed records live in `sok/decision-records/migration`.

## Cycle Selection Model

- `current-cycle.txt`
  - checked-in selector for the currently active release or qualification cycle
  - should point to one file under `release-process/cycles/`
- `cycles/`
  - one checked-in file per release or qualification cycle
  - each file carries the reviewed operator-version and Splunk-release inputs for that cycle
- `cycle-template.env`
  - bootstrap fallback only
  - used when no explicit cycle file and no `current-cycle.txt` selection exists

## Operator Version Planning

For each cycle file:

- `SOK_BASELINE_TAG`
  - current supported operator baseline under test
- `PRODUCT_RELEASE_VERSION`
  - the next operator version only when a real SOK release is required
- `RELEASE_CANDIDATE_VERSION`
  - RC number for the active release train

This keeps the Splunk Enterprise version upstream-driven while the SOK operator version remains a reviewed SOK release decision.
