#!/bin/sh
set -eu

# Runtime contract
# - Purpose: prepare the downstream PSR release-qualification matrix for a release candidate.
# - Inputs: target operator version, base version for upgrade coverage, enterprise image, and PSR scenario selection.
# - Outputs: PSR trigger matrix and operator-facing summary under rehearsal/.
# - Guardrails: no downstream pipeline trigger by default; this stage records the exact PSR contract first.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
output_dir="rehearsal/${WORKFLOW_SLUG}-output"
matrix_file="${output_dir}/psr-trigger-matrix.md"
payload_file="${output_dir}/psr-trigger-payloads.env"
summary_file="${output_dir}/summary.txt"

mkdir -p "rehearsal" "${output_dir}"
: > "${context_file}"

load_repo_dotenv "${CI_PROJECT_DIR}/.env"
load_optional_release_controller_env "${CI_PROJECT_DIR}/rehearsal/release-controller/release-cycle.env"
resolve_enterprise_source_image

current_version="$(awk '/^VERSION[[:space:]]*\?/ {print $3; exit}' "${CI_PROJECT_DIR}/Makefile")"
target_version="${STAGING_PSR_TARGET_VERSION:-${SOK_RELEASE_CANDIDATE_VERSION:-${SOK_TARGET_RELEASE_VERSION:-${current_version}}}}"
base_version="${STAGING_PSR_BASE_VERSION:-${current_version}}"
enterprise_image="${RESOLVED_SPLUNK_ENTERPRISE_IMAGE_NO_DOCKER_IO}"
test_types="${STAGING_PSR_TEST_TYPES:-upgrade,app_framework,perf}"
clouds="${STAGING_PSR_CLOUDS:-aws,azure}"
psr_project="${STAGING_PSR_PROJECT_PATH:-psr/k8s-operator}"

append_context "${context_file}" "release_branch" "${SOK_RELEASE_BRANCH:-}"
append_context "${context_file}" "source_mode" "${RESOLVED_SOK_SOURCE_MODE}"
append_context "${context_file}" "trigger_kind" "${RESOLVED_SOK_TRIGGER_KIND}"
append_context "${context_file}" "enterprise_image_source" "${RESOLVED_SPLUNK_ENTERPRISE_IMAGE_SOURCE}"
append_context "${context_file}" "psr_project" "${psr_project}"
append_context "${context_file}" "psr_target_version" "${target_version}"
append_context "${context_file}" "psr_base_version" "${base_version}"
append_context "${context_file}" "psr_test_types" "${test_types}"
append_context "${context_file}" "psr_clouds" "${clouds}"
append_context "${context_file}" "enterprise_image" "${enterprise_image}"

cat > "${payload_file}" <<EOF
PSR_PROJECT_PATH=${psr_project}
PSR_TARGET_VERSION=${target_version}
PSR_BASE_VERSION=${base_version}
PSR_TEST_TYPES=${test_types}
PSR_CLOUDS=${clouds}
PSR_IMAGE_SPLUNK_ENTERPRISE=${enterprise_image}
EOF

{
  cat <<EOF
# PSR Release Qualification Matrix

- project: ${psr_project}
- target_version: ${target_version}
- base_version: ${base_version}
- enterprise_image: ${enterprise_image}
- test_types: ${test_types}
- clouds: ${clouds}

## Trigger payloads
EOF

  old_ifs="${IFS}"
  IFS=','
  for test_type in ${test_types}; do
    test_type="$(echo "${test_type}" | sed 's/^ *//; s/ *$//')"
    [ -z "${test_type}" ] && continue
    printf '\n### %s\n' "${test_type}"
    for cloud in ${clouds}; do
      cloud="$(echo "${cloud}" | sed 's/^ *//; s/ *$//')"
      [ -z "${cloud}" ] && continue
      cat <<EOF
- cloud: ${cloud}
  - TEST_TYPE=${test_type}
  - CLOUD=${cloud}
  - TARGET_VERSION=${target_version}
EOF
      if [ "${test_type}" = "upgrade" ]; then
        printf '  - BASE_VERSION=%s\n' "${base_version}"
      fi
      if [ "${test_type}" = "app_framework" ] || [ "${test_type}" = "perf" ] || [ "${test_type}" = "perf-index-and-ingestion-separation" ]; then
        printf '  - IMAGE_SPLUNK_ENTERPRISE=%s\n' "${enterprise_image}"
      fi
    done
  done
  IFS="${old_ifs}"

  cat <<EOF

## Release policy

- PSR is a release gate for RC promotion, not a post-GA afterthought.
- The GitLab release lane should collect PSR pipeline URLs and verdicts into the qualification report before RC-to-GA approval.
- Downstream PSR dispatch is temporarily disabled from the SOK release lane.
- This stage records the exact single-test-type trigger inputs for later use when the PSR team reopens capacity.
- `TEST_TYPE=all` must not be triggered from the SOK release lane when execution is re-enabled.
- Performance regressions require explicit owner triage and disposition before public publication.
EOF
} > "${matrix_file}"

cat > "${summary_file}" <<EOF
Prepared the PSR release-qualification trigger plan.

- project: ${psr_project}
- target_version: ${target_version}
- base_version: ${base_version}
- enterprise_image: ${enterprise_image}
- matrix_file: ${matrix_file}
- payload_file: ${payload_file}
EOF
