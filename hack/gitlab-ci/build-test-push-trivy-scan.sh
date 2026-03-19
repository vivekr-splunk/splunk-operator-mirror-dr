#!/bin/sh
set -eu

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

export AWS_ACCESS_KEY_ID="${STAGING_AWS_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${STAGING_AWS_SECRET_ACCESS_KEY}"
context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
: > "${context_file}"
TRIVY_RELEASE="${STAGING_TRIVY_RELEASE:-latest}"

if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash curl jq python3 python3-pip python3-venv tar
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y bash curl jq python3 python3-pip tar
elif command -v yum >/dev/null 2>&1; then
  yum install -y bash curl jq python3 python3-pip tar
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache bash curl jq python3 py3-pip tar
else
  echo "No supported package manager found in base image" >&2
  exit 1
fi

python3 -m venv /tmp/trivy-tools-venv
. /tmp/trivy-tools-venv/bin/activate
pip install --no-cache-dir awscli
trivy_release_api="https://api.github.com/repos/aquasecurity/trivy/releases/latest"
if [ "${TRIVY_RELEASE}" != "latest" ]; then
  trivy_release_tag="${TRIVY_RELEASE#v}"
  trivy_release_api="https://api.github.com/repos/aquasecurity/trivy/releases/tags/v${trivy_release_tag}"
fi

trivy_release_json="$(curl -fsSL \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "${trivy_release_api}")"
TRIVY_TAG="$(printf '%s' "${trivy_release_json}" | jq -r '.tag_name')"
TRIVY_ASSET_URL="$(printf '%s' "${trivy_release_json}" | jq -r '.assets[] | select(.name | endswith("_Linux-64bit.tar.gz")) | .browser_download_url' | head -n 1)"

if [ -z "${TRIVY_TAG}" ] || [ "${TRIVY_TAG}" = "null" ] || [ -z "${TRIVY_ASSET_URL}" ]; then
  echo "Unable to resolve Trivy release asset from ${trivy_release_api}" >&2
  exit 1
fi

curl -fsSL -o /tmp/trivy.tgz "${TRIVY_ASSET_URL}"
tar -xzf /tmp/trivy.tgz -C /tmp trivy
install /tmp/trivy /usr/local/bin/trivy
trivy --version
aws --version

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
append_context "${context_file}" "trivy_release_selector" "${TRIVY_RELEASE}"
append_context "${context_file}" "trivy_tag" "${TRIVY_TAG}"
append_context "${context_file}" "trivy_asset_url" "${TRIVY_ASSET_URL}"

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
