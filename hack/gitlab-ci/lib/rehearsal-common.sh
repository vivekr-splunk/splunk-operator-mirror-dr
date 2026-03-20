#!/bin/sh

# Shared GitLab rehearsal helpers
# - Keep these functions POSIX-shell compatible because the workflow template invokes them with /bin/sh.
# - Centralize registry resolution, tool bootstrapping, artifact checks, naming normalization, and context capture.
# - Runtime scripts should prefer these helpers instead of duplicating parsing or bootstrap logic.

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

install_helm_version() {
  helm_version="$1"
  ci_bin_dir="$2"
  temp_archive="/tmp/helm-${helm_version}-linux-amd64.tar.gz"

  ensure_ci_bin_path "$ci_bin_dir"

  if [ ! -x "${ci_bin_dir}/helm" ]; then
    curl -fsSL -o "${temp_archive}" "https://get.helm.sh/helm-${helm_version}-linux-amd64.tar.gz"
    tar -xzf "${temp_archive}" -C /tmp linux-amd64/helm
    mv /tmp/linux-amd64/helm "${ci_bin_dir}/helm"
    chmod +x "${ci_bin_dir}/helm"
    rm -f "${temp_archive}"
    rm -rf /tmp/linux-amd64
  fi
}

install_kuttl_version() {
  kuttl_version="$1"
  ci_bin_dir="$2"
  temp_archive="/tmp/kuttl_${kuttl_version#v}_linux_x86_64.tar.gz"

  ensure_ci_bin_path "$ci_bin_dir"

  if [ ! -x "${ci_bin_dir}/kubectl-kuttl" ]; then
    curl -fsSL -o "${temp_archive}" "https://github.com/kudobuilder/kuttl/releases/download/${kuttl_version}/kuttl_${kuttl_version#v}_linux_x86_64.tar.gz"
    tar -xzf "${temp_archive}" -C /tmp kubectl-kuttl
    mv /tmp/kubectl-kuttl "${ci_bin_dir}/kubectl-kuttl"
    chmod +x "${ci_bin_dir}/kubectl-kuttl"
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

trim_csv_field() {
  printf '%s' "$1" | sed 's/^ *//; s/ *$//'
}

resolve_integration_profile() {
  requested_profile="$1"

  case "${requested_profile}" in
    ""|managersecret)
      RESOLVED_INT_TEST_PROFILE="managersecret"
      RESOLVED_INT_TEST_FOCUS="${STAGING_INT_TEST_FOCUS:-managersecret}"
      RESOLVED_INT_TEST_TO_SKIP_DEFAULT='^(?:[^i]+|i(?:$|[^n]|n(?:$|[^t]|t(?:$|[^e]|e(?:$|[^g]|g(?:$|[^r]|r(?:$|[^a]|a(?:$|[^t]|t(?:$|[^i]|i(?:$|[^o]|o(?:$|[^n])))))))))))*$'
      RESOLVED_INT_CLUSTER_NODES_DEFAULT="${STAGING_INT_MANAGERSECRET_CLUSTER_NODES:-1}"
      RESOLVED_INT_CLUSTER_WORKERS_DEFAULT="${STAGING_INT_MANAGERSECRET_CLUSTER_WORKERS:-3}"
      ;;
    smoke)
      RESOLVED_INT_TEST_PROFILE="smoke"
      RESOLVED_INT_TEST_FOCUS="${STAGING_INT_TEST_FOCUS:-smoke}"
      RESOLVED_INT_TEST_TO_SKIP_DEFAULT="${STAGING_INT_SMOKE_TEST_TO_SKIP:-^$}"
      RESOLVED_INT_CLUSTER_NODES_DEFAULT="${STAGING_INT_SMOKE_CLUSTER_NODES:-1}"
      RESOLVED_INT_CLUSTER_WORKERS_DEFAULT="${STAGING_INT_SMOKE_CLUSTER_WORKERS:-2}"
      ;;
    appframework)
      RESOLVED_INT_TEST_PROFILE="appframework"
      RESOLVED_INT_TEST_FOCUS="${STAGING_INT_TEST_FOCUS:-appframework}"
      RESOLVED_INT_TEST_TO_SKIP_DEFAULT="${STAGING_INT_APPFRAMEWORK_TEST_TO_SKIP:-^(?:[^i]+|i(?:$|[^n]|n(?:$|[^t]|t(?:$|[^e]|e(?:$|[^g]|g(?:$|[^r]|r(?:$|[^a]|a(?:$|[^t]|t(?:$|[^i]|i(?:$|[^o]|o(?:$|[^n])))))))))))*$}"
      RESOLVED_INT_CLUSTER_NODES_DEFAULT="${STAGING_INT_APPFRAMEWORK_CLUSTER_NODES:-2}"
      RESOLVED_INT_CLUSTER_WORKERS_DEFAULT="${STAGING_INT_APPFRAMEWORK_CLUSTER_WORKERS:-5}"
      ;;
    full)
      RESOLVED_INT_TEST_PROFILE="full"
      RESOLVED_INT_TEST_FOCUS="${STAGING_INT_TEST_FOCUS:-integration}"
      RESOLVED_INT_TEST_TO_SKIP_DEFAULT="${STAGING_INT_FULL_TEST_TO_SKIP:-^$}"
      RESOLVED_INT_CLUSTER_NODES_DEFAULT="${STAGING_INT_FULL_CLUSTER_NODES:-2}"
      RESOLVED_INT_CLUSTER_WORKERS_DEFAULT="${STAGING_INT_FULL_CLUSTER_WORKERS:-5}"
      ;;
    *)
      RESOLVED_INT_TEST_PROFILE="${requested_profile}"
      RESOLVED_INT_TEST_FOCUS="${STAGING_INT_TEST_FOCUS:-${requested_profile}}"
      RESOLVED_INT_TEST_TO_SKIP_DEFAULT="${STAGING_INT_TEST_TO_SKIP_DEFAULT:-^$}"
      RESOLVED_INT_CLUSTER_NODES_DEFAULT="${STAGING_INT_CLUSTER_NODES:-1}"
      RESOLVED_INT_CLUSTER_WORKERS_DEFAULT="${STAGING_INT_CLUSTER_WORKERS:-3}"
      ;;
  esac
}

resolve_helm_test_profile() {
  requested_profile="$1"

  if [ -n "${STAGING_HELM_TEST_DIRS:-}" ]; then
    RESOLVED_HELM_TEST_PROFILE="${requested_profile:-custom}"
    RESOLVED_HELM_TEST_DIRS="${STAGING_HELM_TEST_DIRS}"
    RESOLVED_HELM_TEST_TIMEOUT="${STAGING_HELM_TEST_TIMEOUT:-7000}"
    RESOLVED_HELM_TEST_PARALLEL="${STAGING_HELM_TEST_PARALLEL:-1}"
    return 0
  fi

  case "${requested_profile}" in
    ""|smoke)
      RESOLVED_HELM_TEST_PROFILE="smoke"
      RESOLVED_HELM_TEST_DIRS="./kuttl/tests/helm/s1,./kuttl/tests/helm/s1-with-operator,./kuttl/tests/helm/operator-with-ephemeral-volume"
      RESOLVED_HELM_TEST_TIMEOUT="${STAGING_HELM_SMOKE_TIMEOUT:-4000}"
      RESOLVED_HELM_TEST_PARALLEL="${STAGING_HELM_SMOKE_PARALLEL:-1}"
      ;;
    clustered)
      RESOLVED_HELM_TEST_PROFILE="clustered"
      RESOLVED_HELM_TEST_DIRS="./kuttl/tests/helm/c3,./kuttl/tests/helm/c3-with-operator,./kuttl/tests/helm/m4,./kuttl/tests/helm/m4-with-operator"
      RESOLVED_HELM_TEST_TIMEOUT="${STAGING_HELM_CLUSTERED_TIMEOUT:-7000}"
      RESOLVED_HELM_TEST_PARALLEL="${STAGING_HELM_CLUSTERED_PARALLEL:-1}"
      ;;
    apps)
      RESOLVED_HELM_TEST_PROFILE="apps"
      RESOLVED_HELM_TEST_DIRS="./kuttl/tests/helm/c3-with-apps,./kuttl/tests/helm/c3-with-apps-private-link"
      RESOLVED_HELM_TEST_TIMEOUT="${STAGING_HELM_APPS_TIMEOUT:-7000}"
      RESOLVED_HELM_TEST_PARALLEL="${STAGING_HELM_APPS_PARALLEL:-1}"
      ;;
    full)
      RESOLVED_HELM_TEST_PROFILE="full"
      RESOLVED_HELM_TEST_DIRS="./kuttl/tests/helm"
      RESOLVED_HELM_TEST_TIMEOUT="${STAGING_HELM_FULL_TIMEOUT:-7000}"
      RESOLVED_HELM_TEST_PARALLEL="${STAGING_HELM_FULL_PARALLEL:-1}"
      ;;
    *)
      RESOLVED_HELM_TEST_PROFILE="${requested_profile}"
      RESOLVED_HELM_TEST_DIRS="./kuttl/tests/helm"
      RESOLVED_HELM_TEST_TIMEOUT="${STAGING_HELM_TEST_TIMEOUT:-7000}"
      RESOLVED_HELM_TEST_PARALLEL="${STAGING_HELM_TEST_PARALLEL:-1}"
      ;;
  esac
}

write_kuttl_testsuite_config() {
  output_path="$1"
  test_dirs_csv="$2"
  parallel_value="$3"
  timeout_value="$4"
  artifacts_dir="$5"

  {
    echo "# Generated by hack/gitlab-ci/lib/rehearsal-common.sh"
    echo "apiVersion: kuttl.dev/v1beta1"
    echo "kind: TestSuite"
    echo "testDirs:"
    old_ifs="${IFS}"
    IFS=','
    for raw_dir in ${test_dirs_csv}; do
      test_dir="$(trim_csv_field "${raw_dir}")"
      [ -z "${test_dir}" ] && continue
      echo "- ${test_dir}"
    done
    IFS="${old_ifs}"
    echo "parallel: ${parallel_value}"
    echo "timeout: ${timeout_value}"
    echo "startKIND: false"
    echo "artifactsDir: ${artifacts_dir}"
    echo "kindNodeCache: false"
  } > "${output_path}"
}
