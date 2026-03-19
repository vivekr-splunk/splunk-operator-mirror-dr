#!/bin/sh
set -eu

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

export AWS_ACCESS_KEY_ID="${STAGING_AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${STAGING_AWS_SECRET_ACCESS_KEY}"
context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
: > "${context_file}"

require_file "rehearsal/build-test-push-workflow-image-ref.txt" "build image reference artifact"
export IMAGE_REF="$(cat rehearsal/build-test-push-workflow-image-ref.txt)"
export ECR_REGISTRY="${IMAGE_REF%%/*}"

resolve_ecr_region "${STAGING_AWS_DEFAULT_REGION:-}" "${ECR_REGISTRY}"
AWS_DEFAULT_REGION="${RESOLVED_ECR_REGION}"

if [ -z "${AWS_DEFAULT_REGION}" ]; then
  echo "Unable to determine ECR region for Trivy scan" >&2
  exit 1
fi

export AWS_REGION="${AWS_DEFAULT_REGION}"
export ECR_PASSWORD="$(aws ecr get-login-password --region "${AWS_DEFAULT_REGION}")"

append_context "${context_file}" "input_artifact" "rehearsal/build-test-push-workflow-image-ref.txt"
append_context "${context_file}" "ecr_registry_present" "true"
append_context "${context_file}" "ecr_region_source" "${RESOLVED_ECR_REGION_SOURCE}"

printf '%s\n' "${IMAGE_REF}" > "rehearsal/${WORKFLOW_SLUG}-image-ref.txt"

trivy image \
  --username AWS \
  --password "${ECR_PASSWORD}" \
  --severity CRITICAL \
  --ignore-unfixed \
  --format sarif \
  --output "rehearsal/${WORKFLOW_SLUG}-trivy-results.sarif" \
  "${IMAGE_REF}"

trivy image \
  --username AWS \
  --password "${ECR_PASSWORD}" \
  --severity CRITICAL \
  --ignore-unfixed \
  "${IMAGE_REF}" | tee "rehearsal/${WORKFLOW_SLUG}-trivy-results.txt"
