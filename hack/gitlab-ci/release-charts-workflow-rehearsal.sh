#!/bin/sh
set -eu

# Runtime contract
# - Purpose: package the operator charts and generate a staging-safe OCI-first publication and certification pack.
# - Inputs: repo chart sources plus Helm version defaults from .env or STAGING_HELM_VERSION.
# - Outputs: packaged chart tgz files, OCI publication plan, optional compatibility index, and runtime context under rehearsal/.
# - Guardrails: no external publish, no public GitHub Pages mutation, local artifact generation only.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
chart_output_dir="rehearsal/${WORKFLOW_SLUG}-chart-output"
publication_plan="rehearsal/${WORKFLOW_SLUG}-publication-plan.md"
oci_refs_file="rehearsal/${WORKFLOW_SLUG}-oci-refs.md"

mkdir -p "rehearsal" "${chart_output_dir}"
: > "${context_file}"
mkdir -p "${chart_output_dir}"

load_repo_dotenv "${CI_PROJECT_DIR}/.env"
load_optional_release_controller_env "${CI_PROJECT_DIR}/rehearsal/release-controller/release-cycle.env"

ci_bin_dir="${CI_PROJECT_DIR}/bin"
ensure_ci_bin_path "${ci_bin_dir}"

export HELM_VERSION="${STAGING_HELM_VERSION:-v3.8.2}"
chart_release_target="${STAGING_CHART_RELEASE_REPOSITORY:-oci://docker.repo.splunkdev.net/helm/splunk-operator}"

install_helm_version "${HELM_VERSION}" "${ci_bin_dir}"

append_context "${context_file}" "helm_version" "${HELM_VERSION}"
append_context "${context_file}" "release_branch" "${SOK_RELEASE_BRANCH:-}"
append_context "${context_file}" "chart_release_target" "${chart_release_target}"
append_context "${context_file}" "chart_output_dir" "${chart_output_dir}"

helm version

helm package "${CI_PROJECT_DIR}/helm-chart/splunk-operator" --destination "${chart_output_dir}"
helm package "${CI_PROJECT_DIR}/helm-chart/splunk-enterprise" --destination "${chart_output_dir}"

if printf '%s' "${chart_release_target}" | grep -q '^oci://'; then
  cat > "${oci_refs_file}" <<EOF
# OCI Helm Publication References

- repository: ${chart_release_target}
- chart: splunk-operator
  - publish_command: helm push ${chart_output_dir}/splunk-operator-*.tgz ${chart_release_target}
- chart: splunk-enterprise
  - publish_command: helm push ${chart_output_dir}/splunk-enterprise-*.tgz ${chart_release_target}
EOF
else
  helm repo index "${chart_output_dir}" --url "${chart_release_target}"
fi

cat > "${publication_plan}" <<EOF
# Helm Chart Publication And Certification Plan

- staging_chart_target: ${chart_release_target}
- chart_output_dir: ${chart_output_dir}

## Internal publication

1. Publish packaged charts to an internal OCI chart repository first.
2. Verify installability from that internal OCI location before any external publication.
3. Generate a legacy \`index.yaml\` only when a compatibility consumer still requires non-OCI chart layout.
4. Keep GitHub Pages read-only until the official publication phase is approved.

## Certification and ecosystem verification

1. Run chart verification against the staged chart repository before official publication.
2. Preserve the chart package, OCI publication plan, and verifier outputs as release evidence.
3. Update public Helm and Artifact Hub metadata only after the canonical GitLab release succeeds.
EOF
