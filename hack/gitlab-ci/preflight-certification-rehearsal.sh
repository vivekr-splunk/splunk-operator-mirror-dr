#!/bin/sh
set -eu

# Runtime contract
# - Purpose: prepare Red Hat preflight certification checks for operator bundles and release containers.
# - Inputs: bundle image, release images, docker auth, and Pyxis metadata.
# - Outputs: preflight execution plan and command inventory under rehearsal/.
# - Guardrails: no partner-portal mutation and no certification submission from rehearsal.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
output_dir="rehearsal/${WORKFLOW_SLUG}-output"
commands_file="${output_dir}/preflight-commands.md"
summary_file="${output_dir}/summary.txt"

mkdir -p "rehearsal" "${output_dir}"
: > "${context_file}"

load_repo_dotenv "${CI_PROJECT_DIR}/.env"
load_optional_release_controller_env "${CI_PROJECT_DIR}/rehearsal/release-controller/release-cycle.env"

current_version="$(awk '/^VERSION[[:space:]]*\?/ {print $3; exit}' "${CI_PROJECT_DIR}/Makefile")"
release_version="${SOK_RELEASE_CANDIDATE_VERSION:-${SOK_TARGET_RELEASE_VERSION:-${current_version}}}"
release_repository="${STAGING_RELEASE_REPOSITORY:-unset}"
bundle_registry="${STAGING_BUNDLE_REGISTRY:-${STAGING_CERTIFICATION_REGISTRY:-unset}}"
operator_image_name="${ARTIFACTORY_SPLUNK_OPERATOR_IMAGE_NAME:-splunk-operator}"
bundle_image="${STAGING_PREFLIGHT_BUNDLE_IMAGE:-${bundle_registry}/${operator_image_name}-bundle:v${release_version}}"
container_image="${STAGING_PREFLIGHT_CONTAINER_IMAGE:-${release_repository}:${release_version}}"
distroless_image="${STAGING_PREFLIGHT_DISTROLESS_IMAGE:-${release_repository}:${release_version}-distroless}"
component_id="${STAGING_PYXIS_CERTIFICATION_COMPONENT_ID:-unset}"

append_context "${context_file}" "release_version" "${release_version}"
append_context "${context_file}" "bundle_image" "${bundle_image}"
append_context "${context_file}" "container_image" "${container_image}"
append_context "${context_file}" "distroless_image" "${distroless_image}"
append_context "${context_file}" "pyxis_component_id" "${component_id}"

cat > "${commands_file}" <<EOF
# Red Hat Preflight Certification Plan

- release_version: ${release_version}
- operator bundle image: ${bundle_image}
- container image: ${container_image}
- distroless container image: ${distroless_image}
- pyxis certification component id: ${component_id}

## Bundle certification

\`\`\`bash
preflight check operator ${bundle_image} \\
  --docker-config \$STAGING_PREFLIGHT_DOCKERCONFIG
\`\`\`

## Container certification

\`\`\`bash
preflight check container ${container_image} \\
  --docker-config \$STAGING_PREFLIGHT_DOCKERCONFIG \\
  --pyxis-api-token \$STAGING_PYXIS_API_TOKEN \\
  --certification-component-id ${component_id}
\`\`\`

\`\`\`bash
preflight check container ${distroless_image} \\
  --docker-config \$STAGING_PREFLIGHT_DOCKERCONFIG \\
  --pyxis-api-token \$STAGING_PYXIS_API_TOKEN \\
  --certification-component-id ${component_id}
\`\`\`

## Release policy

- Preflight results are a release gate before ecosystem submission.
- Final certification images do not need to be world-public, but they must be in a partner-accessible OCI registry that Red Hat tooling can pull from with provided credentials.
- Failures block partner-portal submission and public catalog publication.
- Final certification approval remains external to GitLab, but GitLab must emit the full evidence bundle.
EOF

cat > "${summary_file}" <<EOF
Prepared the Red Hat preflight certification plan.

- release_version: ${release_version}
- bundle_image: ${bundle_image}
- container_image: ${container_image}
- distroless_image: ${distroless_image}
- commands_file: ${commands_file}
EOF
