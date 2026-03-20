#!/bin/sh
set -eu

# Runtime contract
# - Purpose: record the GitHub intake-side CLA/CoC behavior without performing any GitHub mutation.
# - Inputs: optional STAGING_GITHUB_INTAKE_TOKEN plus standard GitLab CI context.
# - Outputs: runtime context, note-only status, and a human-readable intake contract artifact under rehearsal/.
# - Guardrails: no outbound write calls, no GitHub API mutations, safe to run in MR pipelines.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

mkdir -p rehearsal

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
status_file="rehearsal/${WORKFLOW_SLUG}-status.txt"
mode_file="rehearsal/${WORKFLOW_SLUG}-mode.txt"
note_file="rehearsal/${WORKFLOW_SLUG}-intake-note.txt"
summary_file="rehearsal/${WORKFLOW_SLUG}-summary.txt"

: > "${context_file}"
: > "${status_file}"
: > "${mode_file}"
: > "${note_file}"
: > "${summary_file}"

github_intake_token_present="false"
if [ -n "${STAGING_GITHUB_INTAKE_TOKEN:-}" ]; then
  github_intake_token_present="true"
fi

append_context "${context_file}" "observed_at_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
append_context "${context_file}" "pipeline_mode" "${REHEARSAL_PIPELINE_MODE:-full}"
append_context "${context_file}" "pipeline_source" "${CI_PIPELINE_SOURCE:-unknown}"
append_context "${context_file}" "pipeline_id" "${CI_PIPELINE_ID:-unknown}"
append_context "${context_file}" "job_id" "${CI_JOB_ID:-unknown}"
append_context "${context_file}" "job_url" "${CI_JOB_URL:-unknown}"
append_context "${context_file}" "commit_sha" "${CI_COMMIT_SHA:-unknown}"
append_context "${context_file}" "ref_name" "${CI_COMMIT_REF_NAME:-unknown}"
append_context "${context_file}" "workflow_slug" "${WORKFLOW_SLUG:-cla-check}"
append_context "${context_file}" "workflow_class" "${WORKFLOW_CLASS:-github-intake-only}"
append_context "${context_file}" "workflow_name" "${WORKFLOW_NAME:-Agreements Workflow}"
append_context "${context_file}" "github_intake_token_present" "${github_intake_token_present}"
append_context "${context_file}" "mutation_policy" "disabled"
append_context "${context_file}" "authoritative_merge_path" "gitlab-only"

cat > "${status_file}" <<EOF
workflow_name=${WORKFLOW_NAME:-Agreements Workflow}
workflow_class=${WORKFLOW_CLASS:-github-intake-only}
source_workflow_file=${SOURCE_WORKFLOW_FILE:-.github/workflows/cla-check.yml}
note_mode=true
github_intake_token_present=${github_intake_token_present}
mutation_policy=disabled
authoritative_merge_path=gitlab-only
public_mutation=not_permitted
EOF

cat > "${note_file}" <<EOF
# GitHub Intake CLA/CoC Contract

This rehearsal job documents the post-cutover intake behavior for the public GitHub surface.

## Contract

- GitHub remains intake-only for CLA/CoC prompts and acknowledgements.
- GitLab remains the authoritative merge path.
- This job does not invoke GitHub APIs for write operations.
- This job does not create or update CLA/CoC signatures.
- This job is safe to run in merge-request pipelines.

## Observed Inputs

- Pipeline source: ${CI_PIPELINE_SOURCE:-unknown}
- Commit: ${CI_COMMIT_SHA:-unknown}
- Ref: ${CI_COMMIT_REF_NAME:-unknown}
- GitHub intake token available: ${github_intake_token_present}

## Expected Operational Behavior

- Public GitHub intake may continue to accept CLA/CoC acknowledgements after cutover.
- GitLab merge requests must not depend on GitHub-side CLA/CoC state as an authoritative gate.
- Any future intake automation must remain read-only in this rehearsal slice.
EOF

cat > "${summary_file}" <<EOF
note-only
github_intake_token_present=${github_intake_token_present}
mutation_policy=disabled
authoritative_merge_path=gitlab-only
no_github_writes=true
EOF

echo "note-only" | tee "${mode_file}"

