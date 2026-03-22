#!/bin/sh

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/cloud-rehearsal-common.sh"

is_redhat_project_object_id() {
  value="$1"
  printf '%s' "${value}" | grep -Eq '^[0-9a-fA-F]{24}$'
}

install_preflight_release_binary() {
  preflight_version="$1"
  preflight_bin_dir="$2"

  mkdir -p "${preflight_bin_dir}"
  PATH="${preflight_bin_dir}:${PATH}"
  export PATH

  if command -v preflight >/dev/null 2>&1; then
    return 0
  fi

  os_name="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch_name="$(uname -m)"
  case "${arch_name}" in
    x86_64|amd64)
      arch_name="amd64"
      ;;
    aarch64|arm64)
      arch_name="arm64"
      ;;
    ppc64le|s390x)
      ;;
    *)
      echo "Unsupported architecture for preflight binary: ${arch_name}" >&2
      return 1
      ;;
  esac

  download_url="https://github.com/redhat-openshift-ecosystem/openshift-preflight/releases/download/${preflight_version}/preflight-${os_name}-${arch_name}"
  curl -fsSL "${download_url}" -o "${preflight_bin_dir}/preflight"
  chmod 0755 "${preflight_bin_dir}/preflight"
}

fetch_pyxis_project_metadata() {
  project_object_id="$1"
  token="$2"
  metadata_file="$3"

  curl -sS --fail \
    -H "X-API-KEY: ${token}" \
    -H "Accept: application/json" \
    "https://catalog.redhat.com/api/containers/v1/projects/certification/id/${project_object_id}" \
    > "${metadata_file}"
}

resolve_preflight_identifier() {
  explicit_project_id="$1"
  project_object_id="$2"
  explicit_component_id="$3"
  pyxis_token="$4"
  metadata_file="$5"

  identifier_flag=""
  identifier_value=""

  if [ -n "${project_object_id}" ]; then
    fetch_pyxis_project_metadata "${project_object_id}" "${pyxis_token}" "${metadata_file}"
    identifier_flag="--certification-project-id"
    identifier_value="${project_object_id}"
  elif [ -n "${explicit_project_id}" ] && is_redhat_project_object_id "${explicit_project_id}"; then
    identifier_flag="--certification-project-id"
    identifier_value="${explicit_project_id}"
  elif [ -n "${explicit_component_id}" ]; then
    identifier_flag="--certification-component-id"
    identifier_value="${explicit_component_id}"
  elif [ -n "${explicit_project_id}" ]; then
    identifier_flag="--certification-component-id"
    identifier_value="${explicit_project_id}"
  else
    echo "Missing Red Hat certification identifier. Set a certification project object id or component id." >&2
    return 1
  fi

  export identifier_flag
  export identifier_value
}

write_registry_auth() {
  registry_host="$1"
  password="$2"
  dockerconfig_file="$3"

  auth_b64="$(printf 'AWS:%s' "${password}" | base64 | tr -d '\n')"
  jq --arg host "${registry_host}" \
     --arg user "AWS" \
     --arg pass "${password}" \
     --arg auth "${auth_b64}" \
     '.auths[$host] = {username:$user,password:$pass,auth:$auth}' \
     "${dockerconfig_file}" > "${dockerconfig_file}.tmp"
  mv "${dockerconfig_file}.tmp" "${dockerconfig_file}"
}

registry_host_from_image_ref() {
  image_ref="$1"
  first_component="$(printf '%s' "${image_ref}" | cut -d/ -f1)"
  case "${first_component}" in
    *.*|*:*|localhost)
      printf '%s' "${first_component}"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

prepare_preflight_dockerconfig() {
  dockerconfig_secret="$1"
  dockerconfig_file="$2"
  shift 2

  if [ -n "${dockerconfig_secret}" ]; then
    materialize_file_secret "${dockerconfig_secret}" "${dockerconfig_file}"
    return 0
  fi

  printf '%s\n' '{"auths":{}}' > "${dockerconfig_file}"
  auth_added="false"

  for image_ref in "$@"; do
    registry_host="$(registry_host_from_image_ref "${image_ref}")"
    if [ -z "${registry_host}" ]; then
      continue
    fi

    case "${registry_host}" in
      *.dkr.ecr.*.amazonaws.com)
        require_commands aws
        ecr_region="$(printf '%s' "${registry_host}" | cut -d. -f4)"
        ecr_password="$(aws ecr get-login-password --region "${ecr_region}")"
        write_registry_auth "${registry_host}" "${ecr_password}" "${dockerconfig_file}"
        auth_added="true"
        ;;
      docker.io|index.docker.io|registry-1.docker.io|ghcr.io|quay.io)
        ;;
      *)
        echo "Missing Docker auth for non-public registry host ${registry_host}. Set an explicit preflight dockerconfig secret." >&2
        return 1
        ;;
    esac
  done

  if [ "${auth_added}" != "true" ]; then
    rm -f "${dockerconfig_file}"
    return 1
  fi

  return 0
}
