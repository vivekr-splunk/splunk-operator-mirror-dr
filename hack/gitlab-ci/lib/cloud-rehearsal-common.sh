#!/bin/sh

# Cloud rehearsal helpers
# - Keep provider-specific wrappers thin and auditable.
# - Reuse the existing rehearsal-common helpers for context capture and file copying.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

log_step() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

require_command() {
  command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command: ${command_name}" >&2
    return 1
  fi
}

require_commands() {
  for command_name in "$@"; do
    require_command "${command_name}" || return 1
  done
}

require_env() {
  env_name="$1"
  env_value="$(printenv "${env_name}" 2>/dev/null || true)"
  if [ -z "${env_value}" ]; then
    echo "Missing required environment variable: ${env_name}" >&2
    return 1
  fi
}

require_envs() {
  for env_name in "$@"; do
    require_env "${env_name}" || return 1
  done
}

env_present() {
  env_name="$1"
  env_value="$(printenv "${env_name}" 2>/dev/null || true)"
  [ -n "${env_value}" ]
}

ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends jq
    return 0
  fi

  if command -v dnf >/dev/null 2>&1; then
    dnf install -y jq
    return 0
  fi

  if command -v yum >/dev/null 2>&1; then
    yum install -y jq
    return 0
  fi

  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache jq
    return 0
  fi

  echo "Unable to install jq because no supported package manager was found" >&2
  return 1
}

ensure_internal_image_ref() {
  image_ref="$1"
  description="$2"

  case "${image_ref}" in
    docker.io/*|public.ecr.aws/*|splunk/*)
      echo "${description} must point to an internal or staged registry image, not a public DockerHub/public-release reference: ${image_ref}" >&2
      return 1
      ;;
  esac
}

prepare_runtime_artifacts() {
  context_file="$1"
  cleanup_log="$2"
  cluster_log="$3"
  build_log="$4"
  run_log="$5"
  pod_log_dir="$6"
  mkdir -p "$(dirname "${context_file}")" "$(dirname "${cleanup_log}")" "$(dirname "${cluster_log}")" "$(dirname "${build_log}")" "$(dirname "${run_log}")" "${pod_log_dir}"
  : > "${context_file}"
  : > "${cleanup_log}"
  : > "${cluster_log}"
  : > "${build_log}"
  : > "${run_log}"
}

capture_test_logs() {
  source_root="$1"
  dest_dir="$2"

  if [ -d "${source_root}" ]; then
    find "${source_root}" -name "*.log" -type f -exec cp {} "${dest_dir}/" \; >/dev/null 2>&1 || true
  fi
}

capture_junit_artifact() {
  src="$1"
  dest="$2"
  copy_if_exists "${src}" "${dest}" >/dev/null 2>&1 || true
}

materialize_json_secret() {
  secret_value="$1"
  dest_path="$2"

  if printf '%s' "${secret_value}" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "${secret_value}" > "${dest_path}"
    return 0
  fi

  if printf '%s' "${secret_value}" | base64 -d >/dev/null 2>&1; then
    printf '%s' "${secret_value}" | base64 -d > "${dest_path}"
    return 0
  fi

  echo "Unable to interpret secret payload as JSON or base64-encoded JSON" >&2
  return 1
}

materialize_file_secret() {
  secret_value="$1"
  dest_path="$2"

  if [ -f "${secret_value}" ]; then
    cp "${secret_value}" "${dest_path}"
    return 0
  fi

  if printf '%s' "${secret_value}" | base64 -d > "${dest_path}" 2>/dev/null; then
    return 0
  fi

  printf '%s\n' "${secret_value}" > "${dest_path}"
}

azure_oidc_ready() {
  env_present GITLAB_OIDC_TOKEN &&
    env_present AZURE_CLIENT_ID &&
    env_present AZURE_TENANT_ID &&
    env_present AZURE_SUBSCRIPTION_ID
}

azure_login_oidc() {
  require_envs GITLAB_OIDC_TOKEN AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID
  az login --service-principal \
    --username "${AZURE_CLIENT_ID}" \
    --tenant "${AZURE_TENANT_ID}" \
    --federated-token "${GITLAB_OIDC_TOKEN}" >/dev/null
  az account set --subscription "${AZURE_SUBSCRIPTION_ID}" >/dev/null
}

gcp_oidc_ready() {
  env_present GITLAB_OIDC_TOKEN &&
    env_present GCP_WORKLOAD_IDENTITY_PROVIDER &&
    env_present GCP_SERVICE_ACCOUNT_EMAIL
}

gcp_login_oidc() {
  token_file="$1"
  cred_file="$2"

  require_envs GITLAB_OIDC_TOKEN GCP_WORKLOAD_IDENTITY_PROVIDER GCP_SERVICE_ACCOUNT_EMAIL
  printf '%s' "${GITLAB_OIDC_TOKEN}" > "${token_file}"
  gcloud iam workload-identity-pools create-cred-config \
    "${GCP_WORKLOAD_IDENTITY_PROVIDER}" \
    --service-account="${GCP_SERVICE_ACCOUNT_EMAIL}" \
    --credential-source-file="${token_file}" \
    --output-file="${cred_file}" >/dev/null
  gcloud auth login --cred-file="${cred_file}" --quiet >/dev/null
}
