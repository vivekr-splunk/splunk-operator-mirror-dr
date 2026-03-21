#!/bin/sh
set -eu

# Runtime contract
# - Purpose: build variant operator images for staging-only distroless and ARM workflow families.
# - Inputs: staging AWS credentials, staging ECR repository, base image selection, platform list, and optional tag suffix.
# - Outputs: image reference and digest artifacts under rehearsal/.
# - Guardrails: staging-only publication, no DockerHub mutation, and explicit observability for every buildx run.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

aws_oidc_token_file="$(mktemp /tmp/${WORKFLOW_SLUG}-aws-oidc.XXXXXX.jwt)"
trap 'rm -f "${aws_oidc_token_file}"' EXIT INT TERM

aws_auth_mode="static-key"
if aws_oidc_ready; then
  aws_auth_mode="oidc"
else
  export AWS_ACCESS_KEY_ID="${STAGING_AWS_ACCESS_KEY_ID}"
  export AWS_SECRET_ACCESS_KEY="${STAGING_AWS_SECRET_ACCESS_KEY}"
fi

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
build_log="rehearsal/${WORKFLOW_SLUG}-build.log"
: > "${context_file}"
: > "${build_log}"

resolve_staging_image_repository "${STAGING_ECR_REPOSITORY}" "splunk/splunk-operator"
ECR_REGISTRY="${RESOLVED_ECR_REGISTRY}"
IMAGE_REPOSITORY="${RESOLVED_IMAGE_REPOSITORY}"

resolve_ecr_region "${STAGING_AWS_DEFAULT_REGION:-}" "${ECR_REGISTRY}"
ECR_REGION="${RESOLVED_ECR_REGION}"

if [ -z "${ECR_REGION}" ]; then
  echo "Unable to determine ECR region from STAGING_AWS_DEFAULT_REGION or the staging registry host" >&2
  exit 1
fi

BUILD_MODE="${BUILD_MODE:-buildx}"
BUILD_PLATFORMS="${BUILD_PLATFORMS:-linux/amd64,linux/arm64}"
BASE_IMAGE="${BASE_IMAGE:-registry.access.redhat.com/ubi8/ubi-minimal}"
BASE_IMAGE_VERSION="${BASE_IMAGE_VERSION:-8.10-1755105495}"
IMAGE_TAG_SUFFIX="${IMAGE_TAG_SUFFIX:-}"
DOCKERFILE="Dockerfile"
if echo "${BASE_IMAGE}" | grep -q "distroless"; then
  DOCKERFILE="Dockerfile.distroless"
fi

export AWS_DEFAULT_REGION="${ECR_REGION}"
export AWS_REGION="${ECR_REGION}"
export IMAGE_TAG="${CI_COMMIT_SHA}${IMAGE_TAG_SUFFIX}"
export IMAGE_REF="${IMAGE_REPOSITORY}:${IMAGE_TAG}"
export REPOSITORY_NAME="${IMAGE_REPOSITORY#${ECR_REGISTRY}/}"

append_context "${context_file}" "build_mode" "${BUILD_MODE}"
append_context "${context_file}" "ecr_registry_present" "true"
append_context "${context_file}" "image_repository_mode" "${RESOLVED_IMAGE_REPOSITORY_MODE}"
append_context "${context_file}" "ecr_region_source" "${RESOLVED_ECR_REGION_SOURCE}"
append_context "${context_file}" "build_platforms" "${BUILD_PLATFORMS}"
append_context "${context_file}" "dockerfile" "${DOCKERFILE}"
append_context "${context_file}" "base_image" "${BASE_IMAGE}"
append_context "${context_file}" "base_image_version" "${BASE_IMAGE_VERSION}"
append_context "${context_file}" "aws_auth_mode" "${aws_auth_mode}"
append_context "${context_file}" "image_tag" "${IMAGE_TAG}"
append_context "${context_file}" "image_ref" "${IMAGE_REF}"

printf '%s\n' "${IMAGE_REF}" > "rehearsal/${WORKFLOW_SLUG}-image-ref.txt"

if [ "${BUILD_MODE}" != "buildx" ]; then
  echo "Unsupported BUILD_MODE=${BUILD_MODE}; use buildx for distroless and ARM workflows" >&2
  exit 1
fi

echo "Using staging ECR host derived from STAGING_ECR_REPOSITORY"
docker version
if [ "${aws_auth_mode}" = "oidc" ]; then
  aws_prepare_oidc_env "${aws_oidc_token_file}"
fi
aws ecr get-login-password --region "${ECR_REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

{
  docker buildx create --name project-v3-builder --use || true
  docker buildx use project-v3-builder
  docker buildx build --push --platform="${BUILD_PLATFORMS}" \
    --build-arg BASE_IMAGE="${BASE_IMAGE}" \
    --build-arg BASE_IMAGE_VERSION="${BASE_IMAGE_VERSION}" \
    --tag "${IMAGE_REF}" -f "${CI_PROJECT_DIR}/${DOCKERFILE}" "${CI_PROJECT_DIR}"
} 2>&1 | tee "${build_log}"

aws ecr describe-images \
  --region "${ECR_REGION}" \
  --repository-name "${REPOSITORY_NAME}" \
  --image-ids imageTag="${IMAGE_TAG}" \
  --query 'imageDetails[0].imageDigest' \
  --output text > "rehearsal/${WORKFLOW_SLUG}-digest.txt"
