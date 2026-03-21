#!/bin/sh
set -eu

# Runtime contract
# - Purpose: produce a staging-safe governance dry run for the release-branch->main release MR flow.
# - Inputs: release version, enterprise version, and RC number from STAGING_* variables.
# - Outputs: MR payload draft, RC tag plan, and reviewer summary under rehearsal/.
# - Guardrails: no real MR creation, no tag mutation, no public publication.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
output_dir="rehearsal/${WORKFLOW_SLUG}-output"
mr_payload_file="${output_dir}/mr-payload.json"
rc_plan_file="${output_dir}/rc-plan.env"
summary_file="${output_dir}/summary.txt"

mkdir -p "rehearsal" "${output_dir}"
: > "${context_file}"
mkdir -p "${output_dir}"

load_repo_dotenv "${CI_PROJECT_DIR}/.env"
load_optional_release_controller_env "${CI_PROJECT_DIR}/rehearsal/release-controller/release-cycle.env"

release_version="${STAGING_RELEASE_VERSION}"
enterprise_version="${STAGING_ENTERPRISE_VERSION}"
rc_version="${STAGING_RELEASE_CANDIDATE_VERSION}"
reviewers="${REVIEWERS:-}"
release_branch="${SOK_RELEASE_BRANCH:-release/${release_version}}"

append_context "${context_file}" "release_version" "${release_version}"
append_context "${context_file}" "enterprise_version" "${enterprise_version}"
append_context "${context_file}" "release_candidate_version" "${rc_version}"
append_context "${context_file}" "release_branch" "${release_branch}"
append_context "${context_file}" "reviewers" "${reviewers}"

cat > "${mr_payload_file}" <<EOF
{
  "source_branch": "${release_branch}",
  "target_branch": "main",
  "title": "Release ${release_version} RC${rc_version}",
  "labels": [
    "release-governance",
    "gitlab-migration-rehearsal"
  ],
  "reviewers": "${reviewers}",
  "description": "Staging-safe dry run for the GitLab release-governance workflow."
}
EOF

cat > "${rc_plan_file}" <<EOF
RELEASE_VERSION=${release_version}
ENTERPRISE_VERSION=${enterprise_version}
RELEASE_CANDIDATE_VERSION=${rc_version}
RC_TAG=${release_version}-RC${rc_version}
RC_TITLE=Release ${release_version} RC${rc_version}
EOF

cat > "${summary_file}" <<EOF
Prepared a release-branch->main release-governance dry run.

- release_version: ${release_version}
- enterprise_version: ${enterprise_version}
- release_candidate_version: ${rc_version}
- release_branch: ${release_branch}
- reviewers: ${reviewers}
- output_mr_payload: ${mr_payload_file}
- output_rc_plan: ${rc_plan_file}
EOF
