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

install_os_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
    return 0
  fi

  if command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
    return 0
  fi

  if command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
    return 0
  fi

  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$@"
    return 0
  fi

  echo "Unable to install packages because no supported package manager was found" >&2
  return 1
}

ensure_azure_cli() {
  if command -v az >/dev/null 2>&1; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    azure_apt_release="$(lsb_release -cs)"
    case "${azure_apt_release}" in
      bullseye|bookworm)
        ;;
      *)
        azure_apt_release="bookworm"
        ;;
    esac
    install_os_packages ca-certificates curl gnupg lsb-release apt-transport-https
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ ${azure_apt_release} main" >/etc/apt/sources.list.d/azure-cli.list
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends azure-cli
    return 0
  fi

  if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    install_os_packages ca-certificates curl gnupg2
    rpm --import https://packages.microsoft.com/keys/microsoft.asc
    cat >/etc/yum.repos.d/azure-cli.repo <<'EOF'
[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y azure-cli
    else
      yum install -y azure-cli
    fi
    return 0
  fi

  echo "Unable to install Azure CLI in this runtime image" >&2
  return 1
}

ensure_gcloud_cli() {
  if command -v gcloud >/dev/null 2>&1; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    install_os_packages ca-certificates curl gnupg apt-transport-https
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /etc/apt/keyrings/google-cloud-cli.gpg
    echo "deb [signed-by=/etc/apt/keyrings/google-cloud-cli.gpg] https://packages.cloud.google.com/apt cloud-sdk main" >/etc/apt/sources.list.d/google-cloud-sdk.list
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin
    return 0
  fi

  if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    install_os_packages ca-certificates curl gnupg2
    cat >/etc/yum.repos.d/google-cloud-cli.repo <<'EOF'
[google-cloud-cli]
name=Google Cloud CLI
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el8-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg https://packages.cloud.google.com/yum/doc/yum-key.gpg
EOF
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin
    else
      yum install -y google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin
    fi
    return 0
  fi

  echo "Unable to install Google Cloud CLI in this runtime image" >&2
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

registry_host_for_image() {
  image_ref="$1"
  printf '%s' "${image_ref}" | cut -d/ -f1
}

image_ref_uses_ecr() {
  image_ref="$1"
  registry_host="$(registry_host_for_image "${image_ref}")"

  case "${registry_host}" in
    *.dkr.ecr.*.amazonaws.com)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

login_source_registry_for_image() {
  source_image_ref="$1"
  source_registry_host="$(registry_host_for_image "${source_image_ref}")"

  if ! image_ref_uses_ecr "${source_image_ref}"; then
    return 0
  fi

  require_envs STAGING_AWS_ACCESS_KEY_ID STAGING_AWS_SECRET_ACCESS_KEY

  export AWS_ACCESS_KEY_ID="${STAGING_AWS_ACCESS_KEY_ID}"
  export AWS_SECRET_ACCESS_KEY="${STAGING_AWS_SECRET_ACCESS_KEY}"
  if [ -n "${STAGING_AWS_SESSION_TOKEN:-}" ]; then
    export AWS_SESSION_TOKEN="${STAGING_AWS_SESSION_TOKEN}"
  fi

  resolve_ecr_region "${STAGING_AWS_DEFAULT_REGION:-}" "${source_registry_host}"
  if [ -z "${RESOLVED_ECR_REGION}" ]; then
    echo "Unable to determine source ECR region for ${source_image_ref}" >&2
    return 1
  fi

  export AWS_DEFAULT_REGION="${RESOLVED_ECR_REGION}"
  export AWS_REGION="${RESOLVED_ECR_REGION}"

  aws ecr get-login-password --region "${RESOLVED_ECR_REGION}" | docker login --username AWS --password-stdin "${source_registry_host}"
}

promote_image_to_private_registry() {
  source_image_ref="$1"
  target_image_ref="$2"

  docker pull "${source_image_ref}"
  docker tag "${source_image_ref}" "${target_image_ref}"
  docker push "${target_image_ref}"
}
