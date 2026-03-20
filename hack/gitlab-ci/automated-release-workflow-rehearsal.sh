#!/bin/sh
set -eu

# Runtime contract
# - Purpose: generate the staging-safe final-release manifest and signing target inventory.
# - Inputs: release repository, cosign material, release bucket, release notes target.
# - Outputs: release manifest, signing inventory, and publication plan under rehearsal/.
# - Guardrails: no push, no signing, no GitLab release mutation, no public publication.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
output_dir="rehearsal/${WORKFLOW_SLUG}-output"
manifest_file="${output_dir}/release-manifest.env"
signing_file="${output_dir}/signing-targets.txt"
summary_file="${output_dir}/summary.txt"

mkdir -p "rehearsal" "${output_dir}"
: > "${context_file}"
mkdir -p "${output_dir}"

load_repo_dotenv "${CI_PROJECT_DIR}/.env"

current_version="$(awk '/^VERSION[[:space:]]*\?/ {print $3; exit}' "${CI_PROJECT_DIR}/Makefile")"
enterprise_image="${SPLUNK_ENTERPRISE_RELEASE_IMAGE:-${SPLUNK_ENTERPRISE_IMAGE:-${STAGING_SPLUNK_ENTERPRISE_IMAGE:-}}}"

resolve_staging_image_repository "${STAGING_RELEASE_REPOSITORY}" "splunk/splunk-operator"

append_context "${context_file}" "release_version" "${current_version}"
append_context "${context_file}" "release_repository" "${RESOLVED_IMAGE_REPOSITORY}"
append_context "${context_file}" "release_bucket" "${STAGING_RELEASE_BUCKET}"
append_context "${context_file}" "release_notes_target" "${STAGING_RELEASE_NOTES_TARGET}"
append_context "${context_file}" "cosign_private_key_present" "true"
append_context "${context_file}" "cosign_public_key_present" "true"

cat > "${manifest_file}" <<EOF
RELEASE_VERSION=${current_version}
RELEASE_IMAGE=${RESOLVED_IMAGE_REPOSITORY}:${current_version}
DISTROLESS_RELEASE_IMAGE=${RESOLVED_IMAGE_REPOSITORY}:${current_version}-distroless
ENTERPRISE_IMAGE=${enterprise_image}
RELEASE_BUCKET=${STAGING_RELEASE_BUCKET}
RELEASE_NOTES_TARGET=${STAGING_RELEASE_NOTES_TARGET}
EOF

cat > "${signing_file}" <<EOF
${RESOLVED_IMAGE_REPOSITORY}:${current_version}
${RESOLVED_IMAGE_REPOSITORY}:${current_version}-distroless
EOF

cat > "${summary_file}" <<EOF
Prepared a staging-safe automated-release dry run.

- release_version: ${current_version}
- release_repository: ${RESOLVED_IMAGE_REPOSITORY}
- release_bucket: ${STAGING_RELEASE_BUCKET}
- release_notes_target: ${STAGING_RELEASE_NOTES_TARGET}
- signing_targets_file: ${signing_file}
- manifest_file: ${manifest_file}
EOF
