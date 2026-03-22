#!/bin/sh

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

catalog_submission_init() {
  context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
  output_dir="rehearsal/${WORKFLOW_SLUG}-output"
  submission_file="${output_dir}/submission-plan.md"
  summary_file="${output_dir}/summary.txt"

  mkdir -p "rehearsal" "${output_dir}"
  : > "${context_file}"

  load_repo_dotenv "${CI_PROJECT_DIR}/.env"
  load_optional_release_controller_env "${CI_PROJECT_DIR}/rehearsal/release-controller/release-cycle.env"

  current_version="$(awk '/^VERSION[[:space:]]*\?/ {print $3; exit}' "${CI_PROJECT_DIR}/Makefile")"
  release_version="${SOK_TARGET_RELEASE_VERSION:-${current_version}}"
  release_candidate_version="${SOK_RELEASE_CANDIDATE_VERSION:-unset}"

  export context_file output_dir submission_file summary_file
  export current_version release_version release_candidate_version
}

write_catalog_common_summary() {
  target_kind="$1"
  target_repo="$2"
  package_name="$3"
  bundle_directory="$4"

  cat > "${summary_file}" <<EOF
Prepared the ${target_kind} submission plan.

- package_name: ${package_name}
- version: ${release_version}
- target_repo: ${target_repo}
- bundle_directory: ${bundle_directory}
- submission_file: ${submission_file}
EOF
}
