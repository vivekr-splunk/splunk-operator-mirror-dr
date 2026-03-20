#!/bin/sh
set -eu

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
cleanup_log="rehearsal/${WORKFLOW_SLUG}-cleanup.log"
cluster_log="rehearsal/${WORKFLOW_SLUG}-cluster.log"
kuttl_log="rehearsal/${WORKFLOW_SLUG}-kuttl.log"
kuttl_artifacts_dir="rehearsal/${WORKFLOW_SLUG}-kuttl-artifacts"
helm_junit="rehearsal/${WORKFLOW_SLUG}-kuttl-junit.xml"

log_step() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

: > "${context_file}"
: > "${cleanup_log}"
: > "${cluster_log}"
: > "${kuttl_log}"
mkdir -p "${kuttl_artifacts_dir}"

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
  echo "Unable to determine ECR region for helm test runtime" >&2
  exit 1
fi

cluster_name_prefix="${STAGING_HELM_CLUSTER_NAME_PREFIX:-eks-helm-test-cluster}"

export AWS_DEFAULT_REGION="${RESOLVED_ECR_REGION}"
export AWS_REGION="${RESOLVED_ECR_REGION}"
export S3_REGION="${RESOLVED_ECR_REGION}"
export ECR_REGISTRY="${ECR_REGISTRY}"
export ECR_REPOSITORY="${ECR_REGISTRY}"
export PRIVATE_REGISTRY="${ECR_REGISTRY}"
export SPLUNK_OPERATOR_IMAGE="${OPERATOR_REPOSITORY_PATH}:${IMAGE_TAG}"
export SPLUNK_ENTERPRISE_IMAGE="${STAGING_SPLUNK_ENTERPRISE_IMAGE}"
export TEST_CLUSTER_PLATFORM="eks"
export TEST_CLUSTER_NAME="${cluster_name_prefix}-${CI_JOB_ID}"
export CLUSTER_WIDE="${STAGING_HELM_CLUSTER_WIDE:-true}"
export DEPLOYMENT_TYPE="helm"
export HELM_REPO_PATH="${CI_PROJECT_DIR}/helm-chart"
export INSTALL_OPERATOR="true"
export TEST_BUCKET="${STAGING_TEST_BUCKET}"
export TEST_S3_BUCKET="${STAGING_TEST_BUCKET}"
export TEST_INDEXES_S3_BUCKET="${STAGING_TEST_INDEXES_S3_BUCKET}"
export EKS_VPC_PUBLIC_SUBNET_STRING="${STAGING_EKS_VPC_PUBLIC_SUBNET_STRING}"
export EKS_VPC_PRIVATE_SUBNET_STRING="${STAGING_EKS_VPC_PRIVATE_SUBNET_STRING}"
export TEST_VPC_ENDPOINT_URL="${STAGING_TEST_VPC_ENDPOINT_URL}"
export EKSCTL_VERSION="${STAGING_EKSCTL_VERSION:-${EKSCTL_VERSION}}"
export KUBECTL_VERSION="${STAGING_KUBECTL_VERSION:-${KUBECTL_VERSION}}"
export HELM_VERSION="${STAGING_HELM_VERSION:-v3.8.2}"
export KUTTL_VERSION="${STAGING_KUTTL_VERSION:-v0.12.0}"
export EKS_CLUSTER_K8_VERSION="${STAGING_EKS_CLUSTER_K8_VERSION:-${EKS_CLUSTER_K8_VERSION}}"

append_context "${context_file}" "input_artifact" "rehearsal/build-test-push-workflow-image-ref.txt"
append_context "${context_file}" "operator_image" "${IMAGE_REF}"
append_context "${context_file}" "cluster_name" "${TEST_CLUSTER_NAME}"
append_context "${context_file}" "ecr_region_source" "${RESOLVED_ECR_REGION_SOURCE}"
append_context "${context_file}" "helm_version" "${HELM_VERSION}"
append_context "${context_file}" "kuttl_version" "${KUTTL_VERSION}"
append_context "${context_file}" "job_timeout" "${CI_JOB_TIMEOUT:-unknown}"

cleanup_and_exit() {
  rc="$1"
  cleanup_rc=0

  trap - EXIT INT TERM
  set +e

  log_step "cleanup:start" | tee -a "${cleanup_log}" >/dev/null

  if [ -d "${CI_PROJECT_DIR}/kuttl-artifacts" ]; then
    cp -R "${CI_PROJECT_DIR}/kuttl-artifacts/." "${kuttl_artifacts_dir}/" >> "${cleanup_log}" 2>&1 || cleanup_rc=1
  fi

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

log_step "tools:install kubectl=${KUBECTL_VERSION} eksctl=${EKSCTL_VERSION} helm=${HELM_VERSION} kuttl=${KUTTL_VERSION}"
install_kubectl_version "${KUBECTL_VERSION}" "${ci_bin_dir}"
install_eksctl_version "${EKSCTL_VERSION}" "${ci_bin_dir}"
install_helm_version "${HELM_VERSION}" "${ci_bin_dir}"
install_kuttl_version "${KUTTL_VERSION}" "${ci_bin_dir}"

log_step "build-helpers:kustomize:start"
make kustomize
log_step "build-helpers:kustomize:complete"

log_step "versions:start"
kubectl version --client=true
eksctl version
helm version
kubectl-kuttl version
docker version
aws --version
log_step "versions:complete"

log_step "registry:ecr-login ${ECR_REGISTRY}"
aws ecr get-login-password --region "${AWS_DEFAULT_REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
log_step "registry:ecr-login:complete"

log_step "registry:enterprise-image:start"
PRIVATE_SPLUNK_ENTERPRISE_IMAGE="$(bash "${CI_PROJECT_DIR}/test/get-private-registry-enterprise.sh" | tail -1)"
log_step "registry:enterprise-image:complete ${PRIVATE_SPLUNK_ENTERPRISE_IMAGE}"

log_step "cluster:up ${TEST_CLUSTER_NAME}"
make cluster-up 2>&1 | tee -a "${cluster_log}"
log_step "cluster:up:complete"
log_step "cluster:snapshot:nodes"
kubectl get nodes -o wide 2>&1 | tee -a "${cluster_log}"
log_step "cluster:snapshot:pods"
kubectl get pods -A 2>&1 | tee -a "${cluster_log}"

log_step "cluster:addons:metrics-server"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml 2>&1 | tee -a "${cluster_log}"
log_step "cluster:addons:metrics-server:complete"

log_step "cluster:addons:dashboard"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.5/aio/deploy/recommended.yaml 2>&1 | tee -a "${cluster_log}"
log_step "cluster:addons:dashboard:complete"

log_step "cluster:crds-install:start"
make install 2>&1 | tee -a "${cluster_log}"
log_step "cluster:crds-install:complete"

log_step "helm:package:start"
rm -f "${CI_PROJECT_DIR}/helm-chart/splunk-enterprise/charts"/splunk-operator-*.tgz
helm package "${CI_PROJECT_DIR}/helm-chart/splunk-operator" --destination "${CI_PROJECT_DIR}"
mv "${CI_PROJECT_DIR}"/splunk-operator-*.tgz "${CI_PROJECT_DIR}/helm-chart/splunk-enterprise/charts/"
log_step "helm:package:complete"

export KUTTL_SPLUNK_ENTERPRISE_IMAGE="${PRIVATE_SPLUNK_ENTERPRISE_IMAGE}"
export KUTTL_SPLUNK_OPERATOR_IMAGE="${IMAGE_REF}"

append_context "${context_file}" "private_splunk_enterprise_image" "${PRIVATE_SPLUNK_ENTERPRISE_IMAGE}"
append_context "${context_file}" "kuttl_operator_image" "${KUTTL_SPLUNK_OPERATOR_IMAGE}"
append_context "${context_file}" "kuttl_enterprise_image" "${KUTTL_SPLUNK_ENTERPRISE_IMAGE}"

log_step "tests:helm-kuttl:start"
kubectl kuttl test --config "${CI_PROJECT_DIR}/kuttl/kuttl-test-helm.yaml" --report xml 2>&1 | tee -a "${kuttl_log}"
log_step "tests:helm-kuttl:complete"

if [ -f "${CI_PROJECT_DIR}/kuttl-report.xml" ]; then
  cp "${CI_PROJECT_DIR}/kuttl-report.xml" "${helm_junit}"
elif [ -f "${CI_PROJECT_DIR}/TEST-kuttl-report.xml" ]; then
  cp "${CI_PROJECT_DIR}/TEST-kuttl-report.xml" "${helm_junit}"
else
  first_xml="$(find "${CI_PROJECT_DIR}/kuttl-artifacts" -maxdepth 2 -type f -name '*.xml' 2>/dev/null | head -1 || true)"
  if [ -n "${first_xml}" ] && [ -f "${first_xml}" ]; then
    cp "${first_xml}" "${helm_junit}"
  fi
fi
