#!/bin/sh
set -eu

# Runtime contract
# - Purpose: execute Red Hat preflight container certification against the upstream docker-splunk release image.
# - Inputs: the resolved release-cycle Splunk Enterprise image plus Pyxis certification metadata for docker-splunk.
# - Outputs: executed preflight logs, resolved image/source context, and submission evidence under rehearsal/.
# - Guardrails: this stage certifies the upstream container prerequisite only; it does not mutate operator catalogs or partner portals.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/redhat-preflight-common.sh"

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
output_dir="rehearsal/${WORKFLOW_SLUG}-output"
commands_file="${output_dir}/preflight-commands.md"
summary_file="${output_dir}/summary.txt"
results_dir="${output_dir}/results"
dockerconfig_file="${output_dir}/docker-config.json"
pyxis_metadata_file="${output_dir}/pyxis-project.json"
container_log="${results_dir}/container-preflight.log"
preflight_version="${STAGING_PREFLIGHT_VERSION:-1.16.0}"
preflight_bin_dir="${CI_PROJECT_DIR}/bin"

mkdir -p "rehearsal" "${output_dir}" "${results_dir}" "${preflight_bin_dir}"
: > "${context_file}"
ensure_jq
require_commands awk base64 curl jq

load_repo_dotenv "${CI_PROJECT_DIR}/.env"
load_optional_release_controller_env "${CI_PROJECT_DIR}/rehearsal/release-controller/release-cycle.env"
resolve_enterprise_source_image

container_image="${STAGING_DOCKER_SPLUNK_PREFLIGHT_CONTAINER_IMAGE:-${RESOLVED_SPLUNK_ENTERPRISE_IMAGE}}"
dockerconfig_secret="${STAGING_DOCKER_SPLUNK_PREFLIGHT_DOCKERCONFIG:-${STAGING_PREFLIGHT_DOCKERCONFIG:-}}"
project_id="${STAGING_DOCKER_SPLUNK_PYXIS_CERTIFICATION_PROJECT_ID:-}"
project_object_id="${STAGING_DOCKER_SPLUNK_PYXIS_CERTIFICATION_PROJECT_OBJECT_ID:-}"
component_id="${STAGING_DOCKER_SPLUNK_PYXIS_CERTIFICATION_COMPONENT_ID:-}"

run_container_preflight() {
  image_ref="$1"
  log_file="$2"

  set -- preflight check container "${image_ref}" \
    --submit \
    --pyxis-api-token "${STAGING_PYXIS_API_TOKEN}" \
    "${identifier_flag}" "${identifier_value}"
  if [ -f "${dockerconfig_file}" ]; then
    set -- "$@" --docker-config "${dockerconfig_file}"
  fi
  "$@" > "${log_file}" 2>&1
}

require_envs STAGING_PYXIS_API_TOKEN
install_preflight_release_binary "${preflight_version}" "${preflight_bin_dir}"
resolve_preflight_identifier "${project_id}" "${project_object_id}" "${component_id}" "${STAGING_PYXIS_API_TOKEN}" "${pyxis_metadata_file}"
prepare_preflight_dockerconfig "${dockerconfig_secret}" "${dockerconfig_file}" "${container_image}" || true
run_container_preflight "${container_image}" "${container_log}"

append_context "${context_file}" "container_image" "${container_image}"
append_context "${context_file}" "enterprise_image_source" "${RESOLVED_SPLUNK_ENTERPRISE_IMAGE_SOURCE}"
append_context "${context_file}" "source_mode" "${RESOLVED_SOK_SOURCE_MODE}"
append_context "${context_file}" "trigger_kind" "${RESOLVED_SOK_TRIGGER_KIND}"
append_context "${context_file}" "preflight_version" "${preflight_version}"
append_context "${context_file}" "pyxis_identifier_flag" "${identifier_flag}"
append_context "${context_file}" "pyxis_identifier_value" "${identifier_value}"
append_context "${context_file}" "pyxis_project_id" "${project_id:-unset}"
append_context "${context_file}" "pyxis_project_object_id" "${project_object_id:-unset}"
append_context "${context_file}" "pyxis_component_id" "${component_id:-unset}"
append_context "${context_file}" "dockerconfig_path" "$(if [ -f "${dockerconfig_file}" ]; then printf '%s' "${dockerconfig_file}"; else printf '%s' 'not-required'; fi)"

cat > "${commands_file}" <<EOF
# Docker Splunk Preflight Certification Plan

- container image: ${container_image}
- source mode: ${RESOLVED_SOK_SOURCE_MODE}
- source trigger: ${RESOLVED_SOK_TRIGGER_KIND}
- enterprise image source: ${RESOLVED_SPLUNK_ENTERPRISE_IMAGE_SOURCE}
- pyxis identifier flag: ${identifier_flag}
- pyxis identifier value: ${identifier_value}
- docker auth: $(if [ -f "${dockerconfig_file}" ]; then printf '%s' 'configured'; else printf '%s' 'not-required'; fi)

## Container certification

\`\`\`bash
preflight check container ${container_image} \\
  ${identifier_flag} ${identifier_value} \\
  --pyxis-api-token \$STAGING_PYXIS_API_TOKEN \\
  --submit
\`\`\`

## Release policy

- The upstream docker-splunk certification must be green before operator bundle submission proceeds.
- This job certifies the release-cycle Splunk Enterprise image selected by the controller.
- Catalog PR generation stays blocked until this prerequisite is green.
EOF

cat > "${summary_file}" <<EOF
Executed the docker-splunk container certification stage.

- container_image: ${container_image}
- source_mode: ${RESOLVED_SOK_SOURCE_MODE}
- source_trigger: ${RESOLVED_SOK_TRIGGER_KIND}
- pyxis_identifier_flag: ${identifier_flag}
- pyxis_identifier_value: ${identifier_value}
- commands_file: ${commands_file}
- container_log: ${container_log}
EOF
