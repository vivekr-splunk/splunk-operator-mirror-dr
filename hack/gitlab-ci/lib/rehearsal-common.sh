#!/bin/sh

append_context() {
  context_file="$1"
  key="$2"
  value="$3"
  printf '%s=%s\n' "$key" "$value" >> "$context_file"
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
