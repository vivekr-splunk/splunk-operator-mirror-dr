#!/bin/sh
set -eu

# Runtime contract
# - Purpose: stage release-candidate operator images in the internal release registry before certification.
# - Inputs: release repository, release-controller version inputs, and staging AWS credentials or AWS OIDC.
# - Outputs: staged standard/distroless image refs and digests under rehearsal/.
# - Guardrails: internal staging registry only; no DockerHub/public release mutation.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

aws_oidc_token_file="$(mktemp /tmp/${WORKFLOW_SLUG}-aws-oidc.XXXXXX.jwt)"
trap 'rm -f "${aws_oidc_token_file}"' EXIT INT TERM

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
output_dir="rehearsal/${WORKFLOW_SLUG}-output"
summary_file="${output_dir}/summary.txt"
build_log="${output_dir}/build.log"
standard_ref_file="${output_dir}/standard-image-ref.txt"
standard_alias_ref_file="${output_dir}/standard-image-alias-ref.txt"
distroless_ref_file="${output_dir}/distroless-image-ref.txt"
distroless_alias_ref_file="${output_dir}/distroless-image-alias-ref.txt"
standard_digest_file="${output_dir}/standard-image-digest.txt"
distroless_digest_file="${output_dir}/distroless-image-digest.txt"

mkdir -p "rehearsal" "${output_dir}"
: > "${context_file}"
: > "${build_log}"

load_repo_dotenv "${CI_PROJECT_DIR}/.env"
load_optional_release_controller_env "${CI_PROJECT_DIR}/rehearsal/release-controller/release-cycle.env"

current_version="$(awk '/^VERSION[[:space:]]*\?/ {print $3; exit}' "${CI_PROJECT_DIR}/Makefile")"
release_version="${SOK_TARGET_RELEASE_VERSION:-${current_version}}"
release_candidate_version="${SOK_RELEASE_CANDIDATE_VERSION:-1}"
release_candidate_tag="${release_version}-RC${release_candidate_version}"
release_candidate_alias_tag="${release_version}-RC"

resolve_staging_image_repository "${STAGING_RELEASE_REPOSITORY}" "splunk/splunk-operator"
ECR_REGISTRY="${RESOLVED_ECR_REGISTRY}"
IMAGE_REPOSITORY="${RESOLVED_IMAGE_REPOSITORY}"

resolve_ecr_region "${STAGING_AWS_DEFAULT_REGION:-}" "${ECR_REGISTRY}"
ECR_REGION="${RESOLVED_ECR_REGION}"

if [ -z "${ECR_REGION}" ]; then
  echo "Unable to determine ECR region from STAGING_AWS_DEFAULT_REGION or the release registry host" >&2
  exit 1
fi

aws_auth_mode="static-key"
if aws_oidc_ready; then
  aws_auth_mode="oidc"
else
  export AWS_ACCESS_KEY_ID="${STAGING_AWS_ACCESS_KEY_ID}"
  export AWS_SECRET_ACCESS_KEY="${STAGING_AWS_SECRET_ACCESS_KEY}"
fi

export AWS_DEFAULT_REGION="${ECR_REGION}"
export AWS_REGION="${ECR_REGION}"
export REPOSITORY_NAME="${IMAGE_REPOSITORY#${ECR_REGISTRY}/}"
export BUILD_PLATFORMS="${STAGING_RELEASE_BUILD_PLATFORMS:-linux/amd64,linux/arm64}"

standard_image="${IMAGE_REPOSITORY}:${release_candidate_tag}"
standard_alias_image="${IMAGE_REPOSITORY}:${release_candidate_alias_tag}"
distroless_image="${IMAGE_REPOSITORY}:${release_candidate_tag}-distroless"
distroless_alias_image="${IMAGE_REPOSITORY}:${release_candidate_alias_tag}-distroless"

append_context "${context_file}" "release_repository" "${IMAGE_REPOSITORY}"
append_context "${context_file}" "release_version" "${release_version}"
append_context "${context_file}" "release_candidate_version" "${release_candidate_version}"
append_context "${context_file}" "release_candidate_tag" "${release_candidate_tag}"
append_context "${context_file}" "release_candidate_alias_tag" "${release_candidate_alias_tag}"
append_context "${context_file}" "build_platforms" "${BUILD_PLATFORMS}"
append_context "${context_file}" "aws_auth_mode" "${aws_auth_mode}"
append_context "${context_file}" "standard_image" "${standard_image}"
append_context "${context_file}" "standard_alias_image" "${standard_alias_image}"
append_context "${context_file}" "distroless_image" "${distroless_image}"
append_context "${context_file}" "distroless_alias_image" "${distroless_alias_image}"

printf '%s\n' "${standard_alias_image}" > "rehearsal/${WORKFLOW_SLUG}-image-ref.txt"

echo "Using staging release registry derived from STAGING_RELEASE_REPOSITORY"
docker version
if [ "${aws_auth_mode}" = "oidc" ]; then
  aws_prepare_oidc_env "${aws_oidc_token_file}"
fi
aws ecr get-login-password --region "${ECR_REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
docker buildx create --name project-v3-release-builder --use || true
docker buildx use project-v3-release-builder

{
  docker buildx build --push --platform="${BUILD_PLATFORMS}" \
    --build-arg BASE_IMAGE="registry.access.redhat.com/ubi8/ubi-minimal" \
    --build-arg BASE_IMAGE_VERSION="8.10-1755105495" \
    --tag "${standard_image}" \
    --tag "${standard_alias_image}" \
    -f "${CI_PROJECT_DIR}/Dockerfile" "${CI_PROJECT_DIR}"

  docker buildx build --push --platform="${BUILD_PLATFORMS}" \
    --build-arg BASE_IMAGE="gcr.io/distroless/static-debian12" \
    --build-arg BASE_IMAGE_VERSION="latest" \
    --tag "${distroless_image}" \
    --tag "${distroless_alias_image}" \
    -f "${CI_PROJECT_DIR}/Dockerfile.distroless" "${CI_PROJECT_DIR}"
} 2>&1 | tee "${build_log}"

aws ecr describe-images \
  --region "${ECR_REGION}" \
  --repository-name "${REPOSITORY_NAME}" \
  --image-ids imageTag="${release_candidate_alias_tag}" \
  --query 'imageDetails[0].imageDigest' \
  --output text > "${standard_digest_file}"
aws ecr describe-images \
  --region "${ECR_REGION}" \
  --repository-name "${REPOSITORY_NAME}" \
  --image-ids imageTag="${release_candidate_alias_tag}-distroless" \
  --query 'imageDetails[0].imageDigest' \
  --output text > "${distroless_digest_file}"

printf '%s\n' "${standard_image}" > "${standard_ref_file}"
printf '%s\n' "${standard_alias_image}" > "${standard_alias_ref_file}"
printf '%s\n' "${distroless_image}" > "${distroless_ref_file}"
printf '%s\n' "${distroless_alias_image}" > "${distroless_alias_ref_file}"
cp "${standard_digest_file}" "rehearsal/${WORKFLOW_SLUG}-digest.txt"

cat > "${summary_file}" <<EOF
Staged release-candidate images in the internal release repository.

- release_version: ${release_version}
- release_candidate_version: ${release_candidate_version}
- release_candidate_tag: ${release_candidate_tag}
- release_candidate_alias_tag: ${release_candidate_alias_tag}
- release_repository: ${IMAGE_REPOSITORY}
- standard_image: ${standard_image}
- standard_alias_image: ${standard_alias_image}
- distroless_image: ${distroless_image}
- distroless_alias_image: ${distroless_alias_image}
- standard_digest_file: ${standard_digest_file}
- distroless_digest_file: ${distroless_digest_file}
EOF
