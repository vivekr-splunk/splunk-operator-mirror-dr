#!/bin/sh
set -eu

# Runtime contract
# - Purpose: package the operator charts and generate a chart repository index as a staging-safe dry run.
# - Inputs: repo chart sources plus Helm version defaults from .env or STAGING_HELM_VERSION.
# - Outputs: packaged chart tgz files, index.yaml, and runtime context under rehearsal/.
# - Guardrails: no external publish, no public GitHub Pages mutation, local artifact generation only.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
chart_output_dir="rehearsal/${WORKFLOW_SLUG}-chart-output"

: > "${context_file}"
mkdir -p "${chart_output_dir}"

load_repo_dotenv "${CI_PROJECT_DIR}/.env"

ci_bin_dir="${CI_PROJECT_DIR}/bin"
ensure_ci_bin_path "${ci_bin_dir}"

export HELM_VERSION="${STAGING_HELM_VERSION:-v3.8.2}"
chart_release_url="${STAGING_CHART_RELEASE_REPOSITORY:-https://example.invalid/splunk-operator-charts}"

install_helm_version "${HELM_VERSION}" "${ci_bin_dir}"

append_context "${context_file}" "helm_version" "${HELM_VERSION}"
append_context "${context_file}" "chart_release_url" "${chart_release_url}"
append_context "${context_file}" "chart_output_dir" "${chart_output_dir}"

helm version

helm package "${CI_PROJECT_DIR}/helm-chart/splunk-operator" --destination "${chart_output_dir}"
helm package "${CI_PROJECT_DIR}/helm-chart/splunk-enterprise" --destination "${chart_output_dir}"
helm repo index "${chart_output_dir}" --url "${chart_release_url}"
