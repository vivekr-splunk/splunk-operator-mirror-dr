#!/bin/sh
set -eu

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

mkdir -p rehearsal

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
summary_file="rehearsal/${WORKFLOW_SLUG}-summary.txt"
report_file="rehearsal/${WORKFLOW_SLUG}-validation.md"
checks_file="rehearsal/${WORKFLOW_SLUG}-checks.tsv"

issue_workflow=".github/workflows/github-intake-issue.yml"
pr_workflow=".github/workflows/github-intake-pr.yml"
issue_script="hack/github-intake/issue-intake.sh"
pr_script="hack/github-intake/pr-intake.sh"
common_script="hack/github-intake/lib/intake-common.sh"

: > "${context_file}"
: > "${summary_file}"
: > "${report_file}"
: > "${checks_file}"

append_context "${context_file}" "observed_at_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
append_context "${context_file}" "issue_workflow" "${issue_workflow}"
append_context "${context_file}" "pr_workflow" "${pr_workflow}"
append_context "${context_file}" "issue_script" "${issue_script}"
append_context "${context_file}" "pr_script" "${pr_script}"
append_context "${context_file}" "common_script" "${common_script}"

require_file "${issue_workflow}" "GitHub issue intake workflow"
require_file "${pr_workflow}" "GitHub PR intake workflow"
require_file "${issue_script}" "GitHub issue intake script"
require_file "${pr_script}" "GitHub PR intake script"
require_file "${common_script}" "GitHub intake common helper"

bash -n "${common_script}"
bash -n "${issue_script}"
bash -n "${pr_script}"

check_line() {
  name="$1"
  status="$2"
  detail="$3"
  printf '%s\t%s\t%s\n' "${name}" "${status}" "${detail}" >> "${checks_file}"
}

if grep -q 'issues:' "${issue_workflow}"; then
  check_line "issue-workflow-event" "ok" "issues event found"
else
  check_line "issue-workflow-event" "fail" "issues event missing"
  exit 1
fi

if grep -q 'pull_request_target:' "${pr_workflow}"; then
  check_line "pr-workflow-event" "ok" "pull_request_target found"
else
  check_line "pr-workflow-event" "fail" "pull_request_target missing"
  exit 1
fi

if grep -q 'ref: ${{ github.event.pull_request.base.sha }}' "${pr_workflow}"; then
  check_line "pr-workflow-trusted-checkout" "ok" "base SHA checkout configured"
else
  check_line "pr-workflow-trusted-checkout" "fail" "trusted base checkout missing"
  exit 1
fi

if grep -q 'head.sha' "${pr_workflow}" || grep -q 'head.ref' "${pr_workflow}"; then
  check_line "pr-workflow-untrusted-head-checkout" "fail" "head ref or SHA detected"
  exit 1
else
  check_line "pr-workflow-untrusted-head-checkout" "ok" "no PR head checkout detected"
fi

if grep -q 'metadata-only' "${pr_script}"; then
  check_line "pr-script-metadata-only" "ok" "metadata-only contract recorded"
else
  check_line "pr-script-metadata-only" "warn" "metadata-only note not found"
fi

cat > "${report_file}" <<EOF
# GitHub Intake Automation Rehearsal

- Issue workflow: \`${issue_workflow}\`
- PR workflow: \`${pr_workflow}\`
- Issue script: \`${issue_script}\`
- PR script: \`${pr_script}\`
- Common helper: \`${common_script}\`

## Validation Summary

- Issue intake uses the \`issues\` event.
- PR intake uses \`pull_request_target\`.
- PR workflow checks out only the trusted base SHA.
- No PR head checkout was detected.
- Intake scripts lint successfully with \`bash -n\`.

This rehearsal job validates the checked-in GitHub intake automation contract without mutating GitHub or GitLab state.
EOF

cat > "${summary_file}" <<EOF
validated_workflows=${issue_workflow},${pr_workflow}
validated_scripts=${issue_script},${pr_script},${common_script}
trusted_pr_checkout=true
github_mutation_performed=false
gitlab_mutation_performed=false
EOF
