#!/bin/sh
set -eu

# Runtime contract
# - Purpose: generate staging-safe pre-release artifacts and draft release notes without publishing them.
# - Inputs: staging release repository, release bucket, and release notes target.
# - Outputs: generated release manifests, draft notes, and artifact inventory under rehearsal/.
# - Guardrails: local artifact generation only; no registry push and no bucket mutation.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
output_dir="rehearsal/${WORKFLOW_SLUG}-output"
notes_file="${output_dir}/draft-release-notes.md"
manifest_file="${output_dir}/artifact-manifest.txt"

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
append_context "${context_file}" "enterprise_image" "${enterprise_image}"

cat > "${notes_file}" <<EOF
# Release ${current_version}

- Source branch: ${CI_COMMIT_REF_NAME}
- Commit: ${CI_COMMIT_SHA}
- Staging release repository: ${RESOLVED_IMAGE_REPOSITORY}
- Staging release bucket: ${STAGING_RELEASE_BUCKET}
- Release notes target: ${STAGING_RELEASE_NOTES_TARGET}

## Checklist

- [ ] validate generated release manifests
- [ ] validate chart package versions
- [ ] validate bundle/catalog version alignment
- [ ] validate downstream mirrored publication targets
EOF

make generate-artifacts \
  IMG="${RESOLVED_IMAGE_REPOSITORY}:${current_version}-pre" \
  VERSION="${current_version}" \
  SPLUNK_ENTERPRISE_IMAGE="${enterprise_image}" \
  SPLUNK_GENERAL_TERMS="--accept-sgt-current-at-splunk-com" \
  WATCH_NAMESPACE=""

find "${CI_PROJECT_DIR}/release-${current_version}" -maxdepth 1 -type f | sort > "${manifest_file}"
cp -R "${CI_PROJECT_DIR}/release-${current_version}" "${output_dir}/"
