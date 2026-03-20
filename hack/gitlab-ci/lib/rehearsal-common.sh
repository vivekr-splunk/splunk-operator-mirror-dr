#!/bin/sh

append_context() {
  context_file="$1"
  key="$2"
  value="$3"
  printf '%s=%s\n' "$key" "$value" >> "$context_file"
}

load_repo_dotenv() {
  dotenv_path="$1"
  if [ ! -f "$dotenv_path" ]; then
    echo "Missing dotenv file: ${dotenv_path}" >&2
    return 1
  fi

  set -a
  . "$dotenv_path"
  set +a
}

require_file() {
  path="$1"
  description="$2"
  if [ ! -f "$path" ]; then
    echo "Missing required file: ${description} (${path})" >&2
    return 1
  fi
}

resolve_staging_image_repository() {
  staging_target="$1"
  default_repo_path="$2"

  case "${staging_target}" in
    */*)
      RESOLVED_ECR_REGISTRY="${staging_target%%/*}"
      RESOLVED_IMAGE_REPOSITORY="${staging_target}"
      RESOLVED_IMAGE_REPOSITORY_MODE="explicit-repository"
      ;;
    *)
      RESOLVED_ECR_REGISTRY="${staging_target}"
      RESOLVED_IMAGE_REPOSITORY="${staging_target}/${default_repo_path}"
      RESOLVED_IMAGE_REPOSITORY_MODE="registry-only"
      ;;
  esac
}

resolve_ecr_region() {
  configured_region="$1"
  ecr_registry="$2"
  trimmed_region="$(printf '%s' "${configured_region}" | tr -d '[:space:]')"

  if [ -n "${trimmed_region}" ]; then
    RESOLVED_ECR_REGION="${trimmed_region}"
    RESOLVED_ECR_REGION_SOURCE="configured-variable"
    return 0
  fi

  RESOLVED_ECR_REGION="$(printf '%s' "${ecr_registry}" | cut -d. -f4)"
  RESOLVED_ECR_REGION_SOURCE="registry-hostname"
}

ensure_ci_bin_path() {
  ci_bin_dir="$1"
  mkdir -p "$ci_bin_dir"
  PATH="${ci_bin_dir}:${PATH}"
  export PATH
}

install_kubectl_version() {
  kubectl_version="$1"
  ci_bin_dir="$2"

  ensure_ci_bin_path "$ci_bin_dir"

  if [ ! -x "${ci_bin_dir}/kubectl" ]; then
    curl -fsSL -o "${ci_bin_dir}/kubectl" "https://dl.k8s.io/release/${kubectl_version}/bin/linux/amd64/kubectl"
    chmod +x "${ci_bin_dir}/kubectl"
  fi
}

install_eksctl_version() {
  eksctl_version="$1"
  ci_bin_dir="$2"
  temp_archive="/tmp/eksctl-${eksctl_version}-amd64.tar.gz"

  ensure_ci_bin_path "$ci_bin_dir"

  if [ ! -x "${ci_bin_dir}/eksctl" ]; then
    curl --silent --location -o "${temp_archive}" "https://github.com/weaveworks/eksctl/releases/download/${eksctl_version}/eksctl_$(uname -s)_amd64.tar.gz"
    tar -xzf "${temp_archive}" -C "${ci_bin_dir}" eksctl
    chmod +x "${ci_bin_dir}/eksctl"
    rm -f "${temp_archive}"
  fi
}

copy_if_exists() {
  src="$1"
  dest="$2"

  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    return 0
  fi

  return 1
}

sanitize_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

normalize_testenv_commit_hash() {
  commit_hash="$1"
  max_length="${2:-8}"
  sanitized_hash="$(printf '%s' "${commit_hash}" | tr -cd '[:alnum:]')"

  if [ -z "${sanitized_hash}" ]; then
    NORMALIZED_TESTENV_COMMIT_HASH=""
    return 0
  fi

  NORMALIZED_TESTENV_COMMIT_HASH="$(printf '%s' "${sanitized_hash}" | cut -c1-"${max_length}")"
}
