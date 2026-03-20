#!/bin/sh
set -eu

# Runtime contract
# - Purpose: prepare a staging-safe bundle and catalog publication plan without pushing images.
# - Inputs: staging bundle registry, token presence, and release notes target.
# - Outputs: bundle image plan, catalog image plan, and publication summary under rehearsal/.
# - Guardrails: no registry push, no DockerHub usage, no public catalog mutation.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
output_dir="rehearsal/${WORKFLOW_SLUG}-output"
bundle_plan_file="${output_dir}/bundle-plan.env"
summary_file="${output_dir}/summary.txt"

mkdir -p "rehearsal" "${output_dir}"
: > "${context_file}"
mkdir -p "${output_dir}"

load_repo_dotenv "${CI_PROJECT_DIR}/.env"

current_version="$(awk '/^VERSION[[:space:]]*\?/ {print $3; exit}' "${CI_PROJECT_DIR}/Makefile")"
bundle_registry="${STAGING_BUNDLE_REGISTRY}"
operator_image_name="${ARTIFACTORY_SPLUNK_OPERATOR_IMAGE_NAME:-splunk-operator}"

append_context "${context_file}" "release_version" "${current_version}"
append_context "${context_file}" "bundle_registry" "${bundle_registry}"
append_context "${context_file}" "release_notes_target" "${STAGING_RELEASE_NOTES_TARGET}"

cat > "${bundle_plan_file}" <<EOF
BUNDLE_IMG=${bundle_registry}/${operator_image_name}-bundle:v${current_version}
CATALOG_IMG=${bundle_registry}/${operator_image_name}-catalog:v${current_version}
IMAGE_TAG_BASE=${bundle_registry}/${operator_image_name}
VERSION=${current_version}
EOF

cat > "${summary_file}" <<EOF
Prepared a staging-safe bundle/catalog publication dry run.

- version: ${current_version}
- bundle_registry: ${bundle_registry}
- release_notes_target: ${STAGING_RELEASE_NOTES_TARGET}
- bundle_plan_file: ${bundle_plan_file}
EOF
