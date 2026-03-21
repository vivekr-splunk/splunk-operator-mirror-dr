#!/bin/sh
set -eu

# Runtime contract
# - Purpose: prepare the downstream ecosystem submission pack for OperatorHub and Red Hat certification channels.
# - Inputs: release version, bundle metadata, submission targets, and contact/project metadata.
# - Outputs: PR/submission plan and ownership summary under rehearsal/.
# - Guardrails: no external PR creation and no partner-portal mutation during rehearsal.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
output_dir="rehearsal/${WORKFLOW_SLUG}-output"
submission_file="${output_dir}/ecosystem-submission-plan.md"
summary_file="${output_dir}/summary.txt"

mkdir -p "rehearsal" "${output_dir}"
: > "${context_file}"

load_repo_dotenv "${CI_PROJECT_DIR}/.env"
load_optional_release_controller_env "${CI_PROJECT_DIR}/rehearsal/release-controller/release-cycle.env"

current_version="$(awk '/^VERSION[[:space:]]*\?/ {print $3; exit}' "${CI_PROJECT_DIR}/Makefile")"
release_version="${SOK_RELEASE_CANDIDATE_VERSION:-${SOK_TARGET_RELEASE_VERSION:-${current_version}}}"
operator_name="${STAGING_OPERATORHUB_PACKAGE_NAME:-splunk-operator}"
community_repo="${STAGING_OPERATORHUB_REPO:-k8s-operatorhub/community-operators}"
upstream_repo="${STAGING_UPSTREAM_OPERATORHUB_REPO:-operator-framework/upstream-community-operators}"
redhat_target="${STAGING_REDHAT_CERT_TARGET:-partner-portal/certified-operators}"
ci_yaml_path="${STAGING_OPERATORHUB_CI_YAML_PATH:-operators/${operator_name}/ci.yaml}"
bundle_directory="${STAGING_OPERATORHUB_BUNDLE_DIR:-operators/${operator_name}/${release_version}}"

append_context "${context_file}" "release_version" "${release_version}"
append_context "${context_file}" "operator_name" "${operator_name}"
append_context "${context_file}" "community_repo" "${community_repo}"
append_context "${context_file}" "upstream_repo" "${upstream_repo}"
append_context "${context_file}" "redhat_target" "${redhat_target}"
append_context "${context_file}" "ci_yaml_path" "${ci_yaml_path}"
append_context "${context_file}" "bundle_directory" "${bundle_directory}"

cat > "${submission_file}" <<EOF
# Ecosystem Submission Plan

- operator: ${operator_name}
- version: ${release_version}
- community repo: ${community_repo}
- upstream community repo: ${upstream_repo}
- Red Hat target: ${redhat_target}
- ci.yaml path: ${ci_yaml_path}
- bundle directory: ${bundle_directory}

## OperatorHub and community operators

1. Generate the bundle directory for version ${release_version}.
2. Validate with:
   - \`operator-sdk bundle validate --select-optional name=operatorhub .\`
   - optional \`operator-sdk scorecard\`
3. Prepare PR payload for:
   - ${community_repo}
   - ${upstream_repo}
4. Keep \`ci.yaml\` aligned with reviewer and update policy.

## Red Hat certification

1. Attach the preflight evidence bundle for operator and container certification.
2. Prepare the partner-portal or certified-operator submission packet.
3. Record the certification project, component ownership, and approval contacts.

## Release policy

- GitLab should automate artifact generation, validation, and PR-ready payload assembly.
- External review, certification approval, and upstream merge remain outside GitLab control and must be tracked explicitly.
EOF

cat > "${summary_file}" <<EOF
Prepared the ecosystem submission plan.

- operator_name: ${operator_name}
- version: ${release_version}
- community_repo: ${community_repo}
- upstream_repo: ${upstream_repo}
- redhat_target: ${redhat_target}
- submission_file: ${submission_file}
EOF
