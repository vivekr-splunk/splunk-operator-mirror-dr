#!/bin/sh
set -eu

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

mkdir -p rehearsal

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
summary_file="rehearsal/${WORKFLOW_SLUG}-summary.txt"
plan_file="rehearsal/${WORKFLOW_SLUG}-plan.md"
command_log_file="rehearsal/${WORKFLOW_SLUG}-command-log.tsv"
decision_file="rehearsal/${WORKFLOW_SLUG}-decision-checklist.md"

rollback_window_minutes="${STAGING_ROLLBACK_TARGET_WINDOW_MINUTES:-60}"
mirror_repo="${STAGING_GITHUB_MIRROR_REPO:-unset}"

: > "${context_file}"
: > "${summary_file}"
: > "${plan_file}"
: > "${command_log_file}"
: > "${decision_file}"

append_context "${context_file}" "observed_at_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
append_context "${context_file}" "rollback_window_minutes" "${rollback_window_minutes}"
append_context "${context_file}" "pipeline_id" "${CI_PIPELINE_ID:-unknown}"
append_context "${context_file}" "pipeline_url" "${CI_PIPELINE_URL:-unknown}"
append_context "${context_file}" "mirror_repo" "${mirror_repo}"
append_context "${context_file}" "mutation_policy" "rehearsal-no-public-writes"

cat > "${plan_file}" <<EOF
# Rollback Rehearsal Plan

- Target recovery window: ${rollback_window_minutes} minutes
- Mirror repository: ${mirror_repo}
- Pipeline: ${CI_PIPELINE_URL:-unknown}

## Rehearsal Order

1. Freeze GitLab-side release promotion and mirror activity.
2. Restore GitHub write and merge authority on the approved rollback target.
3. Record any GitLab-only deltas that would need reconciliation.
4. Validate that public intake and release comms can switch back to the rollback posture.
5. Capture elapsed time, owners, and evidence.

This rehearsal job is evidence-only. It does not disable the mirror or mutate GitHub authority directly.
EOF

cat > "${decision_file}" <<EOF
# Rollback Decision Checklist

- [ ] Trigger condition met and documented
- [ ] Command-center owner approved rollback
- [ ] GitLab release/mirror freeze initiated
- [ ] GitHub authority restoration plan confirmed
- [ ] Delta reconciliation owner assigned
- [ ] External communication draft selected
- [ ] Recovery window target acknowledged (${rollback_window_minutes} minutes)
EOF

cat > "${command_log_file}" <<EOF
step_id\towner\tcommand_or_action\tstart_utc\tend_utc\tstatus\tevidence
1\trollback-owner\tFreeze GitLab release and mirror activity\t\t\tplanned\t
2\tgithub-owner\tRestore GitHub branch and merge authority\t\t\tplanned\t
3\treconciliation-owner\tRecord GitLab-only delta for replay\t\t\tplanned\t
4\tcomms-owner\tIssue rollback communication\t\t\tplanned\t
EOF

cat > "${summary_file}" <<EOF
rollback_window_minutes=${rollback_window_minutes}
mirror_repo=${mirror_repo}
public_mutation_performed=false
gitlab_mutation_performed=false
rehearsal_packet_generated=true
EOF
