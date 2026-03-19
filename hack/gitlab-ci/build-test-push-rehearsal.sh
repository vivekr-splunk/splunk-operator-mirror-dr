#!/bin/sh
set -eu

export AWS_ACCESS_KEY_ID="${STAGING_AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${STAGING_AWS_SECRET_ACCESS_KEY}"
export ECR_REGION="$(printf '%s' "${STAGING_AWS_DEFAULT_REGION:-}" | tr -d '[:space:]')"
export BASE_IMAGE="registry.access.redhat.com/ubi8/ubi-minimal"
export BASE_IMAGE_VERSION="8.10-1755105495"

case "${STAGING_ECR_REPOSITORY}" in
  */*)
    ECR_REGISTRY="${STAGING_ECR_REPOSITORY%%/*}"
    IMAGE_REPOSITORY="${STAGING_ECR_REPOSITORY}"
    ;;
  *)
    ECR_REGISTRY="${STAGING_ECR_REPOSITORY}"
    IMAGE_REPOSITORY="${STAGING_ECR_REPOSITORY}/splunk/splunk-operator"
    ;;
esac

if [ -z "${ECR_REGION}" ]; then
  ECR_REGION="$(printf '%s' "${ECR_REGISTRY}" | cut -d. -f4)"
fi

if [ -z "${ECR_REGION}" ]; then
  echo "Unable to determine ECR region from STAGING_AWS_DEFAULT_REGION or the staging registry host" >&2
  exit 1
fi

export AWS_DEFAULT_REGION="${ECR_REGION}"
export AWS_REGION="${ECR_REGION}"
export IMAGE_TAG="${CI_COMMIT_SHA}"
export IMAGE_REF="${IMAGE_REPOSITORY}:${IMAGE_TAG}"
export REPOSITORY_NAME="${IMAGE_REPOSITORY#${ECR_REGISTRY}/}"

printf '%s\n' "${IMAGE_REF}" > "rehearsal/${WORKFLOW_SLUG}-image-ref.txt"

echo "Using staging ECR host derived from STAGING_ECR_REPOSITORY"
docker version
aws ecr get-login-password --region "${ECR_REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
DOCKER_BUILDKIT=1 docker build "${CI_PROJECT_DIR}" \
  -f "${CI_PROJECT_DIR}/Dockerfile" \
  -t "${IMAGE_REF}" \
  --build-arg BASE_IMAGE="${BASE_IMAGE}" \
  --build-arg BASE_IMAGE_VERSION="${BASE_IMAGE_VERSION}"
docker push "${IMAGE_REF}"
aws ecr describe-images \
  --region "${ECR_REGION}" \
  --repository-name "${REPOSITORY_NAME}" \
  --image-ids imageTag="${IMAGE_TAG}" \
  --query 'imageDetails[0].imageDigest' \
  --output text > "rehearsal/${WORKFLOW_SLUG}-digest.txt"
