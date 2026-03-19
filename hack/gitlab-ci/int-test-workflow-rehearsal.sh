#!/bin/sh
set -eu

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
cleanup_log="rehearsal/${WORKFLOW_SLUG}-cleanup.log"
cluster_log="rehearsal/${WORKFLOW_SLUG}-cluster.log"
pod_log_dir="rehearsal/${WORKFLOW_SLUG}-pod-logs"
integration_junit="rehearsal/${WORKFLOW_SLUG}-inttest-junit.xml"
integration_skip_regex='^(?:[^i]+|i(?:$|[^n]|n(?:$|[^t]|t(?:$|[^e]|e(?:$|[^g]|g(?:$|[^r]|r(?:$|[^a]|a(?:$|[^t]|t(?:$|[^i]|i(?:$|[^o]|o(?:$|[^n])))))))))))*$'

log_step() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

: > "${context_file}"
: > "${cleanup_log}"
: > "${cluster_log}"
mkdir -p "${pod_log_dir}"

load_repo_dotenv "${CI_PROJECT_DIR}/.env"

ci_bin_dir="${CI_PROJECT_DIR}/bin"
ensure_ci_bin_path "${ci_bin_dir}"

require_file "rehearsal/build-test-push-workflow-image-ref.txt" "standard build image reference"

export AWS_ACCESS_KEY_ID="${STAGING_AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${STAGING_AWS_SECRET_ACCESS_KEY}"

IMAGE_REF="$(cat rehearsal/build-test-push-workflow-image-ref.txt)"
IMAGE_REPOSITORY="${IMAGE_REF%:*}"
IMAGE_TAG="${IMAGE_REF##*:}"
ECR_REGISTRY="${IMAGE_REPOSITORY%%/*}"
OPERATOR_REPOSITORY_PATH="${IMAGE_REPOSITORY#${ECR_REGISTRY}/}"

resolve_ecr_region "${STAGING_AWS_DEFAULT_REGION:-}" "${ECR_REGISTRY}"
if [ -z "${RESOLVED_ECR_REGION}" ]; then
  echo "Unable to determine ECR region for integration test runtime" >&2
  exit 1
fi

enterprise_image="${STAGING_SPLUNK_ENTERPRISE_IMAGE#docker.io/}"
test_focus="${STAGING_INT_TEST_FOCUS:-managersecret}"
safe_test_focus="$(sanitize_slug "${test_focus}")"
cluster_name_prefix="${STAGING_EKS_CLUSTER_NAME_PREFIX:-eks-integration-test-cluster}"
cluster_nodes="${STAGING_INT_CLUSTER_NODES:-1}"
cluster_workers="${STAGING_INT_CLUSTER_WORKERS:-3}"

if printf '%s' "${test_focus}" | grep -q "appframework"; then
  cluster_nodes="${STAGING_INT_APPFRAMEWORK_CLUSTER_NODES:-2}"
  cluster_workers="${STAGING_INT_APPFRAMEWORK_CLUSTER_WORKERS:-5}"
fi

export AWS_DEFAULT_REGION="${RESOLVED_ECR_REGION}"
export AWS_REGION="${RESOLVED_ECR_REGION}"
export S3_REGION="${RESOLVED_ECR_REGION}"
export ECR_REGISTRY="${ECR_REGISTRY}"
export ECR_REPOSITORY="${ECR_REGISTRY}"
export PRIVATE_REGISTRY="${ECR_REGISTRY}"
export SPLUNK_OPERATOR_IMAGE="${OPERATOR_REPOSITORY_PATH}:${IMAGE_TAG}"
export SPLUNK_ENTERPRISE_IMAGE="${enterprise_image}"
export COMMIT_HASH="${CI_COMMIT_SHA}"
export TEST_FOCUS="${test_focus}"
export TEST_TO_SKIP="${STAGING_INT_TEST_TO_SKIP:-${integration_skip_regex}}"
export TEST_CLUSTER_PLATFORM="eks"
export TEST_CLUSTER_NAME="${cluster_name_prefix}-${safe_test_focus}-${CI_JOB_ID}"
export CLUSTER_WIDE="${STAGING_INT_CLUSTER_WIDE:-true}"
export DEPLOYMENT_TYPE="${STAGING_INT_DEPLOYMENT_TYPE:-}"
export CLUSTER_NODES="${cluster_nodes}"
export CLUSTER_WORKERS="${cluster_workers}"
export EKS_VPC_PUBLIC_SUBNET_STRING="${STAGING_EKS_VPC_PUBLIC_SUBNET_STRING}"
export EKS_VPC_PRIVATE_SUBNET_STRING="${STAGING_EKS_VPC_PRIVATE_SUBNET_STRING}"
export TEST_BUCKET="${STAGING_TEST_BUCKET}"
export TEST_INDEXES_S3_BUCKET="${STAGING_TEST_INDEXES_S3_BUCKET}"
export EKSCTL_VERSION="${STAGING_EKSCTL_VERSION:-${EKSCTL_VERSION}}"
export KUBECTL_VERSION="${STAGING_KUBECTL_VERSION:-${KUBECTL_VERSION}}"
export EKS_CLUSTER_K8_VERSION="${STAGING_EKS_CLUSTER_K8_VERSION:-${EKS_CLUSTER_K8_VERSION}}"

append_context "${context_file}" "input_artifact" "rehearsal/build-test-push-workflow-image-ref.txt"
append_context "${context_file}" "ecr_registry_present" "true"
append_context "${context_file}" "ecr_region_source" "${RESOLVED_ECR_REGION_SOURCE}"
append_context "${context_file}" "test_focus" "${TEST_FOCUS}"
append_context "${context_file}" "cluster_name" "${TEST_CLUSTER_NAME}"
append_context "${context_file}" "cluster_workers" "${CLUSTER_WORKERS}"
append_context "${context_file}" "cluster_nodes" "${CLUSTER_NODES}"
append_context "${context_file}" "cluster_wide" "${CLUSTER_WIDE}"
append_context "${context_file}" "operator_image" "${SPLUNK_OPERATOR_IMAGE}"
append_context "${context_file}" "enterprise_image" "${SPLUNK_ENTERPRISE_IMAGE}"
append_context "${context_file}" "kubectl_version" "${KUBECTL_VERSION}"
append_context "${context_file}" "eksctl_version" "${EKSCTL_VERSION}"
append_context "${context_file}" "ecr_registry" "${ECR_REGISTRY}"

cleanup_and_exit() {
  rc="$1"
  cleanup_rc=0

  trap - EXIT INT TERM
  set +e

  log_step "cleanup:start" | tee -a "${cleanup_log}" >/dev/null

  copy_if_exists "${CI_PROJECT_DIR}/inttest-junit.xml" "${integration_junit}" >/dev/null 2>&1 || true

  log_step "cleanup:collect-test-logs" | tee -a "${cleanup_log}" >/dev/null
  find "${CI_PROJECT_DIR}/test" -name "*.log" -type f -exec cp {} "${pod_log_dir}/" \; >> "${cleanup_log}" 2>&1 || cleanup_rc=1
  log_step "cleanup:make-cleanup" | tee -a "${cleanup_log}" >/dev/null
  make cleanup >> "${cleanup_log}" 2>&1 || cleanup_rc=1
  log_step "cleanup:make-clean" | tee -a "${cleanup_log}" >/dev/null
  make clean >> "${cleanup_log}" 2>&1 || cleanup_rc=1
  log_step "cleanup:cluster-down" | tee -a "${cleanup_log}" >/dev/null
  make cluster-down >> "${cleanup_log}" 2>&1 || cleanup_rc=1
  log_step "cleanup:complete cleanup_rc=${cleanup_rc}" | tee -a "${cleanup_log}" >/dev/null

  if [ "${rc}" -ne 0 ]; then
    exit "${rc}"
  fi

  if [ "${cleanup_rc}" -ne 0 ]; then
    exit "${cleanup_rc}"
  fi

  exit 0
}

trap 'cleanup_and_exit $?' EXIT INT TERM

log_step "tools:install kubectl=${KUBECTL_VERSION} eksctl=${EKSCTL_VERSION}"
install_kubectl_version "${KUBECTL_VERSION}" "${ci_bin_dir}"
install_eksctl_version "${EKSCTL_VERSION}" "${ci_bin_dir}"

log_step "build-helpers:setup-ginkgo:start"
make setup/ginkgo
log_step "build-helpers:setup-ginkgo:complete"

log_step "build-helpers:kustomize:start"
make kustomize
log_step "build-helpers:kustomize:complete"

log_step "versions:start"
kubectl version --client=true
eksctl version
docker version
aws --version
log_step "versions:complete"

log_step "registry:ecr-login ${ECR_REGISTRY}"
aws ecr get-login-password --region "${AWS_DEFAULT_REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
log_step "registry:ecr-login:complete"

log_step "cluster:up ${TEST_CLUSTER_NAME}"
make cluster-up 2>&1 | tee -a "${cluster_log}"
log_step "cluster:up:complete"

log_step "cluster:addons:metrics-server"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml 2>&1 | tee -a "${cluster_log}"
log_step "cluster:addons:metrics-server:complete"

log_step "cluster:addons:dashboard"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.5/aio/deploy/recommended.yaml 2>&1 | tee -a "${cluster_log}"
log_step "cluster:addons:dashboard:complete"

log_step "tests:int-test:start focus=${TEST_FOCUS}"
make int-test
log_step "tests:int-test:complete"

copy_if_exists "${CI_PROJECT_DIR}/inttest-junit.xml" "${integration_junit}" >/dev/null 2>&1 || true
