#!/bin/sh
set -eu

# Runtime contract
# - Purpose: execute the GCP integration workflow in a staging-only GitLab rehearsal.
# - Inputs: staging GCP auth, staging Artifact Registry, staging project/zone, and staging enterprise image source.
# - Outputs: runtime context, build log, cluster log, run log, copied pod logs, and JUnit output under rehearsal/.
# - Guardrails: no public release mutation, ephemeral GKE cluster, and explicit cleanup on exit.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/cloud-rehearsal-common.sh"

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
cleanup_log="rehearsal/${WORKFLOW_SLUG}-cleanup.log"
cluster_log="rehearsal/${WORKFLOW_SLUG}-cluster.log"
build_log="rehearsal/${WORKFLOW_SLUG}-build.log"
run_log="rehearsal/${WORKFLOW_SLUG}-run.log"
pod_log_root="rehearsal/${WORKFLOW_SLUG}-pod-logs"
integration_junit="rehearsal/${WORKFLOW_SLUG}-inttest-junit.xml"
gcp_key_file="$(mktemp /tmp/${WORKFLOW_SLUG}-gcp-key.XXXXXX.json)"
gcp_oidc_token_file="$(mktemp /tmp/${WORKFLOW_SLUG}-gcp-token.XXXXXX.jwt)"
gcp_oidc_cred_file="$(mktemp /tmp/${WORKFLOW_SLUG}-gcp-cred.XXXXXX.json)"
gke_kubeconfig_file="$(mktemp /tmp/${WORKFLOW_SLUG}-kubeconfig.XXXXXX)"
cluster_mode="ephemeral-gke"

cleanup_and_exit() {
  rc="$1"
  cleanup_rc=0

  trap - EXIT INT TERM
  set +e

  log_step "cleanup:start" | tee -a "${cleanup_log}" >/dev/null
  capture_test_logs "${CI_PROJECT_DIR}/test" "${pod_log_root}"
  capture_junit_artifact "${CI_PROJECT_DIR}/inttest-junit.xml" "${integration_junit}"

  log_step "cleanup:make-cleanup" | tee -a "${cleanup_log}" >/dev/null
  make cleanup >> "${cleanup_log}" 2>&1 || cleanup_rc=1
  if [ "${cluster_mode}" = "ephemeral-gke" ]; then
    log_step "cleanup:cluster-down" | tee -a "${cleanup_log}" >/dev/null
    make cluster-down >> "${cleanup_log}" 2>&1 || cleanup_rc=1
  else
    log_step "cleanup:cluster-down skipped mode=${cluster_mode}" | tee -a "${cleanup_log}" >/dev/null
  fi
  log_step "cleanup:complete cleanup_rc=${cleanup_rc}" | tee -a "${cleanup_log}" >/dev/null

  rm -f "${gcp_key_file}"
  rm -f "${gcp_oidc_token_file}"
  rm -f "${gcp_oidc_cred_file}"
  rm -f "${gke_kubeconfig_file}"

  if [ "${rc}" -ne 0 ]; then
    exit "${rc}"
  fi

  if [ "${cleanup_rc}" -ne 0 ]; then
    exit "${cleanup_rc}"
  fi

  exit 0
}

trap 'cleanup_and_exit $?' EXIT INT TERM

prepare_runtime_artifacts "${context_file}" "${cleanup_log}" "${cluster_log}" "${build_log}" "${run_log}" "${pod_log_root}"
load_repo_dotenv "${CI_PROJECT_DIR}/.env"
load_optional_release_controller_env "${CI_PROJECT_DIR}/rehearsal/release-controller/release-cycle.env"
resolve_enterprise_source_image
ensure_jq
ensure_gcloud_cli
require_commands bash gcloud docker make kubectl go jq base64
require_envs \
  STAGING_GCP_ARTIFACT_REGISTRY \
  STAGING_GCP_PROJECT_ID

gcp_auth_mode="service-account-key"
if [ -n "${STAGING_GCP_SERVICE_ACCOUNT_KEY:-}" ]; then
  gcp_auth_mode="service-account-key"
elif gcp_oidc_ready; then
  gcp_auth_mode="oidc"
else
  require_envs STAGING_GCP_SERVICE_ACCOUNT_KEY
fi
if [ "${gcp_auth_mode}" = "service-account-key" ]; then
  require_envs STAGING_GCP_SERVICE_ACCOUNT_KEY
  materialize_json_secret "${STAGING_GCP_SERVICE_ACCOUNT_KEY}" "${gcp_key_file}"
fi

if [ -n "${STAGING_GKE_KUBECONFIG:-}" ]; then
  cluster_mode="existing-gke"
  materialize_file_secret "${STAGING_GKE_KUBECONFIG}" "${gke_kubeconfig_file}"
  export KUBECONFIG="${gke_kubeconfig_file}"
else
  require_envs STAGING_GCP_REGION STAGING_GCP_ZONE
fi

operator_registry="${STAGING_GCP_ARTIFACT_REGISTRY}"
operator_image="${operator_registry}/splunk/splunk-operator:${CI_COMMIT_SHA}"
enterprise_source_image="${RESOLVED_SPLUNK_ENTERPRISE_IMAGE_NO_DOCKER_IO}"
cluster_name="gke-${CI_JOB_ID}"
test_focus="${STAGING_GCP_TEST_FOCUS:-s1_gcp_sanity}"
test_to_skip="${STAGING_GCP_TEST_TO_SKIP:-^(?:[^s]+|s(?:$|[^m]|m(?:$|[^o]|o(?:$|[^k]|k(?:$|[^e])))))*$}"
test_timeout="${STAGING_GCP_TEST_TIMEOUT:-10h}"

export CLUSTER_PROVIDER="gcp"
export TEST_CLUSTER_PLATFORM="gcp"
export TEST_CLUSTER_NAME="${cluster_name}"
export CLUSTER_NAME="${cluster_name}"
export CLUSTER_WORKERS="${STAGING_GCP_CLUSTER_WORKERS:-5}"
export CLUSTER_NODES="${STAGING_GCP_CLUSTER_NODES:-2}"
export CLUSTER_WIDE="${STAGING_GCP_CLUSTER_WIDE:-true}"
export DEPLOYMENT_TYPE="${STAGING_GCP_DEPLOYMENT_TYPE:-manifest}"
export GCP_PROJECT_ID="${STAGING_GCP_PROJECT_ID}"
export GCP_REGION="${STAGING_GCP_REGION:-us-west2}"
export GCP_ZONE="${STAGING_GCP_ZONE:-us-west2-a}"
export AWS_S3_REGION="${STAGING_GCP_REGION:-us-west2}"
export GCP_NETWORK="${STAGING_GCP_NETWORK:-default}"
export GCP_SUBNETWORK="${STAGING_GCP_SUBNETWORK:-default}"
export GCP_ARTIFACT_REGISTRY="${STAGING_GCP_ARTIFACT_REGISTRY}"
export GCP_CONTAINER_REGISTRY_LOGIN_SERVER="${STAGING_GCP_ARTIFACT_REGISTRY}"
export PRIVATE_REGISTRY="${STAGING_GCP_ARTIFACT_REGISTRY}"
export SPLUNK_OPERATOR_IMAGE="${operator_image}"
export SPLUNK_ENTERPRISE_IMAGE="${enterprise_source_image}"
export TEST_FOCUS="${test_focus}"
export TEST_TO_SKIP="${test_to_skip}"
export TEST_TIMEOUT="${test_timeout}"
export TEST_BUCKET="${STAGING_TEST_BUCKET:-${STAGING_GCP_TEST_CONTAINER:-}}"
export TEST_INDEXES_S3_BUCKET="${STAGING_TEST_INDEXES_S3_BUCKET:-${STAGING_GCP_INDEXES_CONTAINER:-}}"
export INDEXES_S3_BUCKET="${TEST_INDEXES_S3_BUCKET}"
export GCP_STORAGE_ACCOUNT="${STAGING_GCP_STORAGE_ACCOUNT:-}"
export GCP_STORAGE_ACCOUNT_KEY="${STAGING_GCP_STORAGE_ACCOUNT_KEY:-}"
export GCP_TEST_CONTAINER="${STAGING_GCP_TEST_CONTAINER:-${TEST_BUCKET}}"
export GCP_INDEXES_CONTAINER="${STAGING_GCP_INDEXES_CONTAINER:-${TEST_INDEXES_S3_BUCKET}}"
export GCP_SERVICE_ACCOUNT_ENABLED="${STAGING_GCP_SERVICE_ACCOUNT_ENABLED:-false}"
export GCP_ENTERPRISE_LICENSE_LOCATION="${STAGING_GCP_ENTERPRISE_LICENSE_LOCATION:-test_licenses}"
export ENTERPRISE_LICENSE_LOCATION="${STAGING_GCP_ENTERPRISE_LICENSE_LOCATION:-test_licenses}"
export COMMIT_HASH="${CI_COMMIT_SHORT_SHA:-${CI_COMMIT_SHA}}"
export GITLAB_MIGRATION_WORKFLOW="gcp"

log_step "gcp:auth:start" | tee -a "${run_log}" >/dev/null
if [ "${gcp_auth_mode}" = "oidc" ]; then
  gcp_login_oidc "${gcp_oidc_token_file}" "${gcp_oidc_cred_file}" >> "${run_log}" 2>&1
else
  gcloud auth activate-service-account --key-file="${gcp_key_file}" >> "${run_log}" 2>&1
fi
gcloud config set project "${GCP_PROJECT_ID}" >> "${run_log}" 2>&1
gcloud auth configure-docker "$(printf '%s' "${GCP_ARTIFACT_REGISTRY}" | cut -d/ -f1)" --quiet >> "${run_log}" 2>&1
log_step "gcp:auth:complete" | tee -a "${run_log}" >/dev/null

log_step "gcp:registry-enterprise-image:start" | tee -a "${run_log}" >/dev/null
PRIVATE_SPLUNK_ENTERPRISE_IMAGE="$(stage_enterprise_image_in_private_registry)"
export SPLUNK_ENTERPRISE_IMAGE="${PRIVATE_SPLUNK_ENTERPRISE_IMAGE}"
append_context "${context_file}" "private_splunk_enterprise_image" "${PRIVATE_SPLUNK_ENTERPRISE_IMAGE}"
log_step "gcp:registry-enterprise-image:complete ${PRIVATE_SPLUNK_ENTERPRISE_IMAGE}" | tee -a "${run_log}" >/dev/null

append_context "${context_file}" "workflow" "${WORKFLOW_SLUG}"
append_context "${context_file}" "cluster_mode" "${cluster_mode}"
append_context "${context_file}" "cluster_provider" "${CLUSTER_PROVIDER}"
append_context "${context_file}" "test_cluster_name" "${TEST_CLUSTER_NAME}"
append_context "${context_file}" "cluster_workers" "${CLUSTER_WORKERS}"
append_context "${context_file}" "cluster_nodes" "${CLUSTER_NODES}"
append_context "${context_file}" "cluster_wide" "${CLUSTER_WIDE}"
append_context "${context_file}" "deployment_type" "${DEPLOYMENT_TYPE}"
append_context "${context_file}" "operator_image" "${operator_image}"
append_context "${context_file}" "enterprise_source_image" "${enterprise_source_image}"
append_context "${context_file}" "source_mode" "${RESOLVED_SOK_SOURCE_MODE}"
append_context "${context_file}" "trigger_kind" "${RESOLVED_SOK_TRIGGER_KIND}"
append_context "${context_file}" "enterprise_image_source" "${RESOLVED_SPLUNK_ENTERPRISE_IMAGE_SOURCE}"
append_context "${context_file}" "gcp_project_id" "${GCP_PROJECT_ID}"
append_context "${context_file}" "gcp_region" "${GCP_REGION}"
append_context "${context_file}" "gcp_zone" "${GCP_ZONE}"
append_context "${context_file}" "gcp_auth_mode" "${gcp_auth_mode}"
append_context "${context_file}" "test_focus" "${TEST_FOCUS}"
append_context "${context_file}" "test_to_skip" "${TEST_TO_SKIP}"
append_context "${context_file}" "test_timeout" "${TEST_TIMEOUT}"

log_step "gcp:build:start image=${operator_image}" | tee -a "${build_log}" >/dev/null
make docker-buildx IMG="${operator_image}" >> "${build_log}" 2>&1
log_step "gcp:build:complete" | tee -a "${build_log}" >/dev/null

if [ "${cluster_mode}" = "ephemeral-gke" ]; then
  log_step "gcp:cluster-up:start ${TEST_CLUSTER_NAME}" | tee -a "${cluster_log}" >/dev/null
  make cluster-up 2>&1 | tee -a "${cluster_log}"
  log_step "gcp:cluster-up:complete" | tee -a "${cluster_log}" >/dev/null
else
  log_step "gcp:cluster-up:skipped mode=${cluster_mode}" | tee -a "${cluster_log}" >/dev/null
fi
kubectl get nodes -o wide 2>&1 | tee -a "${cluster_log}"
kubectl get pods -A 2>&1 | tee -a "${cluster_log}"

log_step "gcp:deploy-operator:start" | tee -a "${run_log}" >/dev/null
bash "${CI_PROJECT_DIR}/test/deploy-operator.sh" "${operator_image}" "${PRIVATE_SPLUNK_ENTERPRISE_IMAGE}" >> "${run_log}" 2>&1
log_step "gcp:deploy-operator:complete" | tee -a "${run_log}" >/dev/null

log_step "gcp:trigger-tests:start focus=${TEST_FOCUS}" | tee -a "${run_log}" >/dev/null
bash "${CI_PROJECT_DIR}/test/trigger-tests.sh" "${operator_image}" "${PRIVATE_SPLUNK_ENTERPRISE_IMAGE}" >> "${run_log}" 2>&1
log_step "gcp:trigger-tests:complete" | tee -a "${run_log}" >/dev/null

capture_test_logs "${CI_PROJECT_DIR}/test" "${pod_log_root}"
capture_junit_artifact "${CI_PROJECT_DIR}/inttest-junit.xml" "${integration_junit}"
log_step "gcp:workflow:complete" | tee -a "${run_log}" >/dev/null
