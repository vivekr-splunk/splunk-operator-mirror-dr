#!/bin/sh
set -eu

# Runtime contract
# - Purpose: execute Red Hat preflight certification checks for release containers and optional operator bundles.
# - Inputs: release image refs, registry auth, and Pyxis metadata.
# - Outputs: executed preflight logs, resolved certification metadata, and command inventory under rehearsal/.
# - Guardrails: container checks submit only to the configured Red Hat certification project; bundle checks remain optional until an OpenShift test cluster is provided.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/cloud-rehearsal-common.sh"

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
output_dir="rehearsal/${WORKFLOW_SLUG}-output"
commands_file="${output_dir}/preflight-commands.md"
summary_file="${output_dir}/summary.txt"
results_dir="${output_dir}/results"
dockerconfig_file="${output_dir}/docker-config.json"
pyxis_metadata_file="${output_dir}/pyxis-project.json"
container_log="${results_dir}/container-preflight.log"
distroless_log="${results_dir}/distroless-preflight.log"
bundle_log="${results_dir}/bundle-preflight.log"
preflight_version="${STAGING_PREFLIGHT_VERSION:-1.16.0}"
preflight_bin_dir="${CI_PROJECT_DIR}/bin"

mkdir -p "rehearsal" "${output_dir}" "${results_dir}" "${preflight_bin_dir}"
: > "${context_file}"
ensure_jq
require_commands awk base64 curl go jq
PATH="${preflight_bin_dir}:${PATH}"
export PATH

load_repo_dotenv "${CI_PROJECT_DIR}/.env"
load_optional_release_controller_env "${CI_PROJECT_DIR}/rehearsal/release-controller/release-cycle.env"

current_version="$(awk '/^VERSION[[:space:]]*\?/ {print $3; exit}' "${CI_PROJECT_DIR}/Makefile")"
release_version="${SOK_RELEASE_CANDIDATE_VERSION:-${SOK_TARGET_RELEASE_VERSION:-${current_version}}}"
resolve_staging_image_repository "${STAGING_RELEASE_REPOSITORY}" "splunk/splunk-operator"
release_repository="${RESOLVED_IMAGE_REPOSITORY}"
bundle_registry="${STAGING_BUNDLE_REGISTRY:-${STAGING_CERTIFICATION_REGISTRY:-unset}}"
operator_image_name="${ARTIFACTORY_SPLUNK_OPERATOR_IMAGE_NAME:-splunk-operator}"
bundle_image="${STAGING_PREFLIGHT_BUNDLE_IMAGE:-${bundle_registry}/${operator_image_name}-bundle:v${release_version}}"
container_image="${STAGING_PREFLIGHT_CONTAINER_IMAGE:-${release_repository}:${release_version}}"
distroless_image="${STAGING_PREFLIGHT_DISTROLESS_IMAGE:-${release_repository}:${release_version}-distroless}"
project_id="${STAGING_PYXIS_CERTIFICATION_PROJECT_ID:-}"
project_object_id="${STAGING_PYXIS_CERTIFICATION_PROJECT_OBJECT_ID:-}"
component_id="${STAGING_PYXIS_CERTIFICATION_COMPONENT_ID:-}"
bundle_kubeconfig="${STAGING_PREFLIGHT_OPENSHIFT_KUBECONFIG:-}"
bundle_execute="false"
identifier_flag=""
identifier_value=""
bundle_status="skipped-no-openshift-kubeconfig"

install_preflight() {
  if command -v preflight >/dev/null 2>&1; then
    return 0
  fi

  GOBIN="${preflight_bin_dir}" go install "github.com/redhat-openshift-ecosystem/openshift-preflight/cmd/preflight@v${preflight_version}"
}

resolve_pyxis_project_id() {
  if [ -n "${project_id}" ]; then
    identifier_flag="--certification-project-id"
    identifier_value="${project_id}"
    return 0
  fi

  if [ -n "${project_object_id}" ]; then
    curl -sS --fail \
      -H "X-API-KEY: ${STAGING_PYXIS_API_TOKEN}" \
      -H "Accept: application/json" \
      "https://catalog.redhat.com/api/containers/v1/projects/certification/id/${project_object_id}" \
      > "${pyxis_metadata_file}"
    project_id="$(jq -r '.container.isv_pid // .pid // empty' "${pyxis_metadata_file}")"
    if [ -n "${project_id}" ]; then
      identifier_flag="--certification-project-id"
      identifier_value="${project_id}"
      return 0
    fi
  fi

  if [ -n "${component_id}" ]; then
    identifier_flag="--certification-component-id"
    identifier_value="${component_id}"
    return 0
  fi

  echo "Missing Red Hat certification identifier. Set STAGING_PYXIS_CERTIFICATION_PROJECT_ID, STAGING_PYXIS_CERTIFICATION_PROJECT_OBJECT_ID, or STAGING_PYXIS_CERTIFICATION_COMPONENT_ID." >&2
  return 1
}

write_registry_auth() {
  registry_host="$1"
  password="$2"

  auth_b64="$(printf 'AWS:%s' "${password}" | base64 | tr -d '\n')"
  jq --arg host "${registry_host}" \
     --arg user "AWS" \
     --arg pass "${password}" \
     --arg auth "${auth_b64}" \
     '.auths[$host] = {username:$user,password:$pass,auth:$auth}' \
     "${dockerconfig_file}" > "${dockerconfig_file}.tmp"
  mv "${dockerconfig_file}.tmp" "${dockerconfig_file}"
}

prepare_dockerconfig() {
  if [ -n "${STAGING_PREFLIGHT_DOCKERCONFIG:-}" ]; then
    materialize_file_secret "${STAGING_PREFLIGHT_DOCKERCONFIG}" "${dockerconfig_file}"
    return 0
  fi

  printf '%s\n' '{"auths":{}}' > "${dockerconfig_file}"

  release_registry_host="$(printf '%s' "${release_repository}" | cut -d/ -f1)"
  bundle_registry_host="$(printf '%s' "${bundle_registry}" | cut -d/ -f1)"

  case "${release_registry_host}" in
    *.dkr.ecr.*.amazonaws.com)
      require_commands aws
      ecr_region="$(printf '%s' "${release_registry_host}" | cut -d. -f4)"
      ecr_password="$(aws ecr get-login-password --region "${ecr_region}")"
      write_registry_auth "${release_registry_host}" "${ecr_password}"
      if [ -n "${bundle_registry_host}" ] && [ "${bundle_registry_host}" != "${release_registry_host}" ]; then
        bundle_region="$(printf '%s' "${bundle_registry_host}" | cut -d. -f4)"
        bundle_password="$(aws ecr get-login-password --region "${bundle_region}")"
        write_registry_auth "${bundle_registry_host}" "${bundle_password}"
      fi
      return 0
      ;;
  esac

  echo "Missing STAGING_PREFLIGHT_DOCKERCONFIG and unable to derive registry auth automatically for ${release_registry_host}" >&2
  return 1
}

run_container_preflight() {
  image_ref="$1"
  log_file="$2"

  preflight check container "${image_ref}" \
    --docker-config "${dockerconfig_file}" \
    --submit \
    --pyxis-api-token "${STAGING_PYXIS_API_TOKEN}" \
    "${identifier_flag}" "${identifier_value}" \
    > "${log_file}" 2>&1
}

run_bundle_preflight() {
  if [ -z "${bundle_kubeconfig}" ]; then
    return 0
  fi

  materialize_file_secret "${bundle_kubeconfig}" "${output_dir}/openshift-kubeconfig"
  export KUBECONFIG="${output_dir}/openshift-kubeconfig"
  bundle_execute="true"
  preflight check operator "${bundle_image}" \
    --docker-config "${dockerconfig_file}" \
    > "${bundle_log}" 2>&1
  bundle_status="executed"
}

require_envs STAGING_PYXIS_API_TOKEN
install_preflight
resolve_pyxis_project_id
prepare_dockerconfig
run_container_preflight "${container_image}" "${container_log}"
run_container_preflight "${distroless_image}" "${distroless_log}"
run_bundle_preflight || bundle_status="failed"

append_context "${context_file}" "release_version" "${release_version}"
append_context "${context_file}" "bundle_image" "${bundle_image}"
append_context "${context_file}" "container_image" "${container_image}"
append_context "${context_file}" "distroless_image" "${distroless_image}"
append_context "${context_file}" "release_repository" "${release_repository}"
append_context "${context_file}" "preflight_version" "${preflight_version}"
append_context "${context_file}" "pyxis_identifier_flag" "${identifier_flag}"
append_context "${context_file}" "pyxis_identifier_value" "${identifier_value}"
append_context "${context_file}" "pyxis_project_id" "${project_id:-unset}"
append_context "${context_file}" "pyxis_project_object_id" "${project_object_id:-unset}"
append_context "${context_file}" "pyxis_component_id" "${component_id:-unset}"
append_context "${context_file}" "bundle_status" "${bundle_status}"

cat > "${commands_file}" <<EOF
# Red Hat Preflight Certification Plan

- release_version: ${release_version}
- operator bundle image: ${bundle_image}
- container image: ${container_image}
- distroless container image: ${distroless_image}
- pyxis identifier flag: ${identifier_flag}
- pyxis identifier value: ${identifier_value}

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
  ${identifier_flag} ${identifier_value} \\
  --submit
\`\`\`

\`\`\`bash
preflight check container ${distroless_image} \\
  --docker-config \$STAGING_PREFLIGHT_DOCKERCONFIG \\
  --pyxis-api-token \$STAGING_PYXIS_API_TOKEN \\
  ${identifier_flag} ${identifier_value} \\
  --submit
\`\`\`

## Release policy

- Preflight results are a release gate before ecosystem submission.
- Final certification images do not need to be world-public, but they must be in a partner-accessible OCI registry that Red Hat tooling can pull from with provided credentials.
- Failures block partner-portal submission and public catalog publication.
- Final certification approval remains external to GitLab, but GitLab must emit the full evidence bundle.
EOF

cat > "${summary_file}" <<EOF
Executed the Red Hat preflight certification stage.

- release_version: ${release_version}
- bundle_image: ${bundle_image}
- container_image: ${container_image}
- distroless_image: ${distroless_image}
- release_repository: ${release_repository}
- pyxis_identifier_flag: ${identifier_flag}
- pyxis_identifier_value: ${identifier_value}
- bundle_status: ${bundle_status}
- commands_file: ${commands_file}
- container_log: ${container_log}
- distroless_log: ${distroless_log}
EOF
