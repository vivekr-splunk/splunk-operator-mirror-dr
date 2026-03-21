#!/bin/sh
set -eu

# Runtime contract
# - Purpose: execute the Azure integration workflow in a staging-only GitLab rehearsal.
# - Inputs: staging Azure auth, staging ACR, staging resource group, staging storage, and staging enterprise image.
# - Outputs: runtime context, build log, cluster log, run log, copied pod logs, and JUnit output under rehearsal/.
# - Guardrails: no DockerHub/public release mutation, ephemeral AKS cluster, and explicit cleanup on exit.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/cloud-rehearsal-common.sh"

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
cleanup_log="rehearsal/${WORKFLOW_SLUG}-cleanup.log"
cluster_log="rehearsal/${WORKFLOW_SLUG}-cluster.log"
build_log="rehearsal/${WORKFLOW_SLUG}-build.log"
run_log="rehearsal/${WORKFLOW_SLUG}-run.log"
pod_log_dir="rehearsal/${WORKFLOW_SLUG}-pod-logs"
integration_junit="rehearsal/${WORKFLOW_SLUG}-inttest-junit.xml"
azure_creds_file="$(mktemp /tmp/${WORKFLOW_SLUG}-azure-creds.XXXXXX.json)"
aks_kubeconfig_file="$(mktemp /tmp/${WORKFLOW_SLUG}-kubeconfig.XXXXXX)"
cluster_mode="ephemeral-aks"

cleanup_and_exit() {
  rc="$1"
  cleanup_rc=0

  trap - EXIT INT TERM
  set +e

  log_step "cleanup:start" | tee -a "${cleanup_log}" >/dev/null
  capture_test_logs "${CI_PROJECT_DIR}/test" "${pod_log_dir}"
  capture_junit_artifact "${CI_PROJECT_DIR}/inttest-junit.xml" "${integration_junit}"

  log_step "cleanup:make-cleanup" | tee -a "${cleanup_log}" >/dev/null
  make cleanup >> "${cleanup_log}" 2>&1 || cleanup_rc=1
  if [ "${cluster_mode}" = "ephemeral-aks" ]; then
    log_step "cleanup:cluster-down" | tee -a "${cleanup_log}" >/dev/null
    make cluster-down >> "${cleanup_log}" 2>&1 || cleanup_rc=1
  else
    log_step "cleanup:cluster-down skipped mode=${cluster_mode}" | tee -a "${cleanup_log}" >/dev/null
  fi
  log_step "cleanup:complete cleanup_rc=${cleanup_rc}" | tee -a "${cleanup_log}" >/dev/null

  rm -f "${azure_creds_file}"
  rm -f "${aks_kubeconfig_file}"

  if [ "${rc}" -ne 0 ]; then
    exit "${rc}"
  fi

  if [ "${cleanup_rc}" -ne 0 ]; then
    exit "${cleanup_rc}"
  fi

  exit 0
}

trap 'cleanup_and_exit $?' EXIT INT TERM

prepare_runtime_artifacts "${context_file}" "${cleanup_log}" "${cluster_log}" "${build_log}" "${run_log}" "${pod_log_dir}"
ensure_jq
ensure_azure_cli
require_commands bash az docker make kubectl go jq base64
require_envs \
  STAGING_AZURE_ACR_LOGIN_SERVER \
  STAGING_AZURE_STORAGE_ACCOUNT \
  STAGING_AZURE_STORAGE_ACCOUNT_KEY \
  STAGING_AZURE_TEST_CONTAINER \
  STAGING_AZURE_INDEXES_CONTAINER \
  STAGING_SPLUNK_ENTERPRISE_IMAGE
ensure_internal_image_ref "${STAGING_SPLUNK_ENTERPRISE_IMAGE}" "Azure enterprise image"

azure_client_id=""
azure_client_secret=""
azure_tenant_id=""
azure_subscription_id=""
azure_auth_mode="acr-basic"

if azure_oidc_ready; then
  azure_auth_mode="oidc"
elif [ -n "${STAGING_AZURE_CREDENTIALS:-}" ]; then
  azure_auth_mode="service-principal"
fi

if [ -n "${STAGING_AKS_KUBECONFIG:-}" ]; then
  cluster_mode="existing-aks"
  materialize_file_secret "${STAGING_AKS_KUBECONFIG}" "${aks_kubeconfig_file}"
  export KUBECONFIG="${aks_kubeconfig_file}"
else
  require_envs STAGING_AZURE_RESOURCE_GROUP_NAME
  if [ "${azure_auth_mode}" = "service-principal" ]; then
    materialize_json_secret "${STAGING_AZURE_CREDENTIALS}" "${azure_creds_file}"
    azure_client_id="$(jq -r '.clientId // empty' "${azure_creds_file}")"
    azure_client_secret="$(jq -r '.clientSecret // empty' "${azure_creds_file}")"
    azure_tenant_id="$(jq -r '.tenantId // empty' "${azure_creds_file}")"
    azure_subscription_id="$(jq -r '.subscriptionId // empty' "${azure_creds_file}")"

    if [ -z "${azure_client_id}" ] || [ -z "${azure_client_secret}" ] || [ -z "${azure_tenant_id}" ]; then
      echo "Azure credentials payload is missing clientId/clientSecret/tenantId" >&2
      exit 1
    fi
  elif [ "${azure_auth_mode}" = "acr-basic" ]; then
    echo "Ephemeral AKS mode requires GitLab OIDC variables or STAGING_AZURE_CREDENTIALS" >&2
    exit 1
  fi
fi

operator_registry="${STAGING_AZURE_ACR_LOGIN_SERVER}"
operator_image="${operator_registry}/splunk/splunk-operator:${CI_COMMIT_SHA}"
enterprise_image="${STAGING_SPLUNK_ENTERPRISE_IMAGE}"
cluster_name="az${CI_JOB_ID}"
test_focus="${STAGING_AZURE_TEST_FOCUS:-azure_sanity}"
test_to_skip="${STAGING_AZURE_TEST_TO_SKIP:-^(?:[^i]+|i(?:$|[^n]|n(?:$|[^t]|t(?:$|[^e]|e(?:$|[^g]|g(?:$|[^r]|r(?:$|[^a]|a(?:$|[^t]|t(?:$|[^i]|i(?:$|[^o]|o(?:$|[^n])))))))))))*$}"
test_timeout="${STAGING_AZURE_TEST_TIMEOUT:-10h}"

export CLUSTER_PROVIDER="azure"
export TEST_CLUSTER_PLATFORM="azure"
export TEST_CLUSTER_NAME="${cluster_name}"
export CLUSTER_NAME="${cluster_name}"
export CLUSTER_WORKERS="${STAGING_AZURE_CLUSTER_WORKERS:-5}"
export CLUSTER_NODES="${STAGING_AZURE_CLUSTER_NODES:-2}"
export CLUSTER_WIDE="${STAGING_AZURE_CLUSTER_WIDE:-true}"
export DEPLOYMENT_TYPE="${STAGING_AZURE_DEPLOYMENT_TYPE:-manifest}"
export AZURE_CONTAINER_REGISTRY="${STAGING_AZURE_CONTAINER_REGISTRY:-$(printf '%s' "${STAGING_AZURE_ACR_LOGIN_SERVER}" | cut -d. -f1)}"
export AZURE_CONTAINER_REGISTRY_LOGIN_SERVER="${STAGING_AZURE_ACR_LOGIN_SERVER}"
export AZURE_RESOURCE_GROUP="${STAGING_AZURE_RESOURCE_GROUP_NAME:-existing-cluster}"
export AZURE_STORAGE_ACCOUNT="${STAGING_AZURE_STORAGE_ACCOUNT}"
export AZURE_STORAGE_ACCOUNT_KEY="${STAGING_AZURE_STORAGE_ACCOUNT_KEY}"
export AZURE_TEST_CONTAINER="${STAGING_AZURE_TEST_CONTAINER}"
export AZURE_INDEXES_CONTAINER="${STAGING_AZURE_INDEXES_CONTAINER}"
export AZURE_REGION="${STAGING_AZURE_REGION:-westus}"
export AZURE_MANAGED_ID_ENABLED="${STAGING_AZURE_MANAGED_ID_ENABLED:-false}"
export AZURE_ENTERPRISE_LICENSE_PATH="${STAGING_AZURE_ENTERPRISE_LICENSE_PATH:-test_licenses}"
export PRIVATE_REGISTRY="${STAGING_AZURE_ACR_LOGIN_SERVER}"
export SPLUNK_OPERATOR_IMAGE="${operator_image}"
export SPLUNK_ENTERPRISE_IMAGE="${enterprise_image}"
export TEST_FOCUS="${test_focus}"
export TEST_TO_SKIP="${test_to_skip}"
export TEST_TIMEOUT="${test_timeout}"
export COMMIT_HASH="${CI_COMMIT_SHORT_SHA:-${CI_COMMIT_SHA}}"
export GITLAB_MIGRATION_WORKFLOW="azure"
export TEST_CONTAINER="${STAGING_AZURE_TEST_CONTAINER}"
export INDEXES_CONTAINER="${STAGING_AZURE_INDEXES_CONTAINER}"
export REGION="${AZURE_REGION}"
export STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT}"
export STORAGE_ACCOUNT_KEY="${AZURE_STORAGE_ACCOUNT_KEY}"
export ENTERPRISE_LICENSE_LOCATION="${STAGING_AZURE_ENTERPRISE_LICENSE_LOCATION:-test_licenses}"

append_context "${context_file}" "workflow" "${WORKFLOW_SLUG}"
append_context "${context_file}" "cluster_mode" "${cluster_mode}"
append_context "${context_file}" "cluster_provider" "${CLUSTER_PROVIDER}"
append_context "${context_file}" "test_cluster_name" "${TEST_CLUSTER_NAME}"
append_context "${context_file}" "cluster_workers" "${CLUSTER_WORKERS}"
append_context "${context_file}" "cluster_nodes" "${CLUSTER_NODES}"
append_context "${context_file}" "cluster_wide" "${CLUSTER_WIDE}"
append_context "${context_file}" "deployment_type" "${DEPLOYMENT_TYPE}"
append_context "${context_file}" "operator_image" "${operator_image}"
append_context "${context_file}" "enterprise_image" "${enterprise_image}"
append_context "${context_file}" "azure_resource_group" "${AZURE_RESOURCE_GROUP}"
append_context "${context_file}" "azure_container_registry" "${AZURE_CONTAINER_REGISTRY}"
append_context "${context_file}" "azure_region" "${AZURE_REGION}"
append_context "${context_file}" "azure_auth_mode" "${azure_auth_mode}"
append_context "${context_file}" "test_focus" "${TEST_FOCUS}"
append_context "${context_file}" "test_to_skip" "${TEST_TO_SKIP}"
append_context "${context_file}" "test_timeout" "${TEST_TIMEOUT}"

if [ "${azure_auth_mode}" = "oidc" ]; then
  log_step "azure:auth:start mode=oidc" | tee -a "${run_log}" >/dev/null
  azure_login_oidc >> "${run_log}" 2>&1
  log_step "azure:auth:complete" | tee -a "${run_log}" >/dev/null
elif [ "${cluster_mode}" = "ephemeral-aks" ]; then
  log_step "azure:auth:start" | tee -a "${run_log}" >/dev/null
  az login --service-principal \
    --username "${azure_client_id}" \
    --password "${azure_client_secret}" \
    --tenant "${azure_tenant_id}" >> "${run_log}" 2>&1
  if [ -n "${azure_subscription_id}" ]; then
    az account set --subscription "${azure_subscription_id}" >> "${run_log}" 2>&1
  fi
  log_step "azure:auth:complete" | tee -a "${run_log}" >/dev/null
else
  log_step "azure:auth:skipped mode=${cluster_mode}" | tee -a "${run_log}" >/dev/null
fi

log_step "azure:registry-login:start ${operator_registry}" | tee -a "${run_log}" >/dev/null
if [ "${azure_auth_mode}" = "oidc" ] || [ "${azure_auth_mode}" = "service-principal" ]; then
  az acr login --name "${AZURE_CONTAINER_REGISTRY}" >> "${run_log}" 2>&1
else
  require_envs STAGING_AZURE_ACR_DOCKER_USERNAME STAGING_AZURE_ACR_DOCKER_PASSWORD
  printf '%s' "${STAGING_AZURE_ACR_DOCKER_PASSWORD}" | docker login "${operator_registry}" -u "${STAGING_AZURE_ACR_DOCKER_USERNAME}" --password-stdin >> "${run_log}" 2>&1
fi
log_step "azure:registry-login:complete" | tee -a "${run_log}" >/dev/null

log_step "azure:build:start image=${operator_image}" | tee -a "${build_log}" >/dev/null
make docker-buildx IMG="${operator_image}" >> "${build_log}" 2>&1
log_step "azure:build:complete" | tee -a "${build_log}" >/dev/null

if [ "${cluster_mode}" = "ephemeral-aks" ]; then
  log_step "azure:cluster-up:start ${TEST_CLUSTER_NAME}" | tee -a "${cluster_log}" >/dev/null
  make cluster-up 2>&1 | tee -a "${cluster_log}"
  log_step "azure:cluster-up:complete" | tee -a "${cluster_log}" >/dev/null
else
  log_step "azure:cluster-up:skipped mode=${cluster_mode}" | tee -a "${cluster_log}" >/dev/null
fi
kubectl get nodes -o wide 2>&1 | tee -a "${cluster_log}"
kubectl get pods -A 2>&1 | tee -a "${cluster_log}"

log_step "azure:deploy-operator:start" | tee -a "${run_log}" >/dev/null
bash "${CI_PROJECT_DIR}/test/deploy-operator.sh" "${operator_image}" "${enterprise_image}" >> "${run_log}" 2>&1
log_step "azure:deploy-operator:complete" | tee -a "${run_log}" >/dev/null

log_step "azure:trigger-tests:start focus=${TEST_FOCUS}" | tee -a "${run_log}" >/dev/null
bash "${CI_PROJECT_DIR}/test/trigger-tests.sh" "${operator_image}" "${enterprise_image}" >> "${run_log}" 2>&1
log_step "azure:trigger-tests:complete" | tee -a "${run_log}" >/dev/null

capture_test_logs "${CI_PROJECT_DIR}/test" "${pod_log_dir}"
capture_junit_artifact "${CI_PROJECT_DIR}/inttest-junit.xml" "${integration_junit}"
log_step "azure:workflow:complete" | tee -a "${run_log}" >/dev/null
