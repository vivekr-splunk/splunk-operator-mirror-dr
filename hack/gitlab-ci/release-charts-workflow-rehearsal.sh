#!/bin/sh
set -eu

# Runtime contract
# - Purpose: package the operator charts, publish them to the internal OCI target when auth is available, and validate installability from the pushed OCI refs.
# - Inputs: repo chart sources, Helm version defaults from .env or STAGING_HELM_VERSION, and optional internal chart registry credentials.
# - Outputs: packaged chart tgz files, OCI publication evidence, validation artifacts, optional compatibility index, and runtime context under rehearsal/.
# - Guardrails: internal publication only; no public GitHub Pages mutation and no external chart publication from rehearsal.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
chart_output_dir="rehearsal/${WORKFLOW_SLUG}-chart-output"
publication_plan="rehearsal/${WORKFLOW_SLUG}-publication-plan.md"
oci_refs_file="rehearsal/${WORKFLOW_SLUG}-oci-refs.md"
validation_dir="rehearsal/${WORKFLOW_SLUG}-validation"
publication_state_file="rehearsal/${WORKFLOW_SLUG}-publication-state.txt"
compatibility_state_file="rehearsal/${WORKFLOW_SLUG}-compatibility-state.txt"

mkdir -p "rehearsal" "${chart_output_dir}" "${validation_dir}"
: > "${context_file}"
mkdir -p "${chart_output_dir}"

load_repo_dotenv "${CI_PROJECT_DIR}/.env"
load_optional_release_controller_env "${CI_PROJECT_DIR}/rehearsal/release-controller/release-cycle.env"

ci_bin_dir="${CI_PROJECT_DIR}/bin"
ensure_ci_bin_path "${ci_bin_dir}"

export HELM_VERSION="${STAGING_HELM_VERSION:-v3.8.2}"
chart_release_target="${STAGING_CHART_RELEASE_REPOSITORY:-oci://docker.repo.splunkdev.net/helm/splunk-operator}"
official_chart_release_target="${OFFICIAL_CHART_RELEASE_REPOSITORY:-unset}"
legacy_index_required="${STAGING_CHART_LEGACY_INDEX_REQUIRED:-false}"
legacy_index_url="${STAGING_CHART_LEGACY_INDEX_URL:-}"
chart_registry_username="${STAGING_CHART_RELEASE_USERNAME:-}"
chart_registry_password="${STAGING_CHART_RELEASE_PASSWORD:-}"

install_helm_version "${HELM_VERSION}" "${ci_bin_dir}"

append_context "${context_file}" "helm_version" "${HELM_VERSION}"
append_context "${context_file}" "release_branch" "${SOK_RELEASE_BRANCH:-}"
append_context "${context_file}" "chart_release_target" "${chart_release_target}"
append_context "${context_file}" "official_chart_release_target" "${official_chart_release_target}"
append_context "${context_file}" "legacy_index_required" "${legacy_index_required}"
append_context "${context_file}" "chart_output_dir" "${chart_output_dir}"

helm version

helm lint "${CI_PROJECT_DIR}/helm-chart/splunk-operator"
helm lint "${CI_PROJECT_DIR}/helm-chart/splunk-enterprise"

helm package "${CI_PROJECT_DIR}/helm-chart/splunk-operator" --destination "${chart_output_dir}"
helm package "${CI_PROJECT_DIR}/helm-chart/splunk-enterprise" --destination "${chart_output_dir}"

operator_chart_archive="$(find "${chart_output_dir}" -maxdepth 1 -name 'splunk-operator-*.tgz' | head -n 1)"
enterprise_chart_archive="$(find "${chart_output_dir}" -maxdepth 1 -name 'splunk-enterprise-*.tgz' | head -n 1)"

require_file "${operator_chart_archive}" "packaged splunk-operator chart"
require_file "${enterprise_chart_archive}" "packaged splunk-enterprise chart"

operator_chart_version="$(basename "${operator_chart_archive}" | sed 's/^splunk-operator-//; s/\.tgz$//')"
enterprise_chart_version="$(basename "${enterprise_chart_archive}" | sed 's/^splunk-enterprise-//; s/\.tgz$//')"

append_context "${context_file}" "operator_chart_version" "${operator_chart_version}"
append_context "${context_file}" "enterprise_chart_version" "${enterprise_chart_version}"

publication_status="packaged-only"
internal_publish_validated="false"
legacy_index_generated="false"
internal_auth_mode="none"

if printf '%s' "${chart_release_target}" | grep -q '^oci://'; then
  normalized_internal_chart_base="$(normalize_chart_repository_base "${chart_release_target}")"
  internal_operator_chart_ref="$(chart_repository_ref "${normalized_internal_chart_base}" "splunk-operator")"
  internal_enterprise_chart_ref="$(chart_repository_ref "${normalized_internal_chart_base}" "splunk-enterprise")"

  official_chart_base="unset"
  official_operator_chart_ref="unset"
  official_enterprise_chart_ref="unset"
  if printf '%s' "${official_chart_release_target}" | grep -q '^oci://'; then
    official_chart_base="$(normalize_chart_repository_base "${official_chart_release_target}")"
    official_operator_chart_ref="$(chart_repository_ref "${official_chart_base}" "splunk-operator")"
    official_enterprise_chart_ref="$(chart_repository_ref "${official_chart_base}" "splunk-enterprise")"
  fi

  append_context "${context_file}" "normalized_internal_chart_base" "${normalized_internal_chart_base}"
  append_context "${context_file}" "internal_operator_chart_ref" "${internal_operator_chart_ref}"
  append_context "${context_file}" "internal_enterprise_chart_ref" "${internal_enterprise_chart_ref}"
  append_context "${context_file}" "official_operator_chart_ref" "${official_operator_chart_ref}"
  append_context "${context_file}" "official_enterprise_chart_ref" "${official_enterprise_chart_ref}"

  cat > "${oci_refs_file}" <<EOF
# OCI Helm Publication References

- internal_chart_base: ${normalized_internal_chart_base}
- chart: splunk-operator
  - push_target: ${normalized_internal_chart_base}
  - pull_ref: ${internal_operator_chart_ref}
  - version: ${operator_chart_version}
  - publish_command: helm push ${operator_chart_archive} ${normalized_internal_chart_base}
  - validate_pull_command: helm pull ${internal_operator_chart_ref} --version ${operator_chart_version}
- chart: splunk-enterprise
  - push_target: ${normalized_internal_chart_base}
  - pull_ref: ${internal_enterprise_chart_ref}
  - version: ${enterprise_chart_version}
  - publish_command: helm push ${enterprise_chart_archive} ${normalized_internal_chart_base}
  - validate_pull_command: helm pull ${internal_enterprise_chart_ref} --version ${enterprise_chart_version}
- official_chart_base: ${official_chart_base}
- official_splunk_operator_chart_ref: ${official_operator_chart_ref}
- official_splunk_enterprise_chart_ref: ${official_enterprise_chart_ref}
EOF

  if [ -n "${chart_registry_username}" ] && [ -n "${chart_registry_password}" ]; then
    internal_auth_mode="explicit-credentials"
    helm_registry_login_with_password "${normalized_internal_chart_base}" "${chart_registry_username}" "${chart_registry_password}"

    helm push "${operator_chart_archive}" "${normalized_internal_chart_base}"
    helm push "${enterprise_chart_archive}" "${normalized_internal_chart_base}"

    helm show chart "${internal_operator_chart_ref}" --version "${operator_chart_version}" > "${validation_dir}/splunk-operator-chart.yaml"
    helm show chart "${internal_enterprise_chart_ref}" --version "${enterprise_chart_version}" > "${validation_dir}/splunk-enterprise-chart.yaml"

    helm pull "${internal_operator_chart_ref}" --version "${operator_chart_version}" --destination "${validation_dir}"
    helm pull "${internal_enterprise_chart_ref}" --version "${enterprise_chart_version}" --destination "${validation_dir}"

    helm template splunk-operator-staged "${validation_dir}/splunk-operator-${operator_chart_version}.tgz" \
      > "${validation_dir}/splunk-operator-rendered.yaml"
    helm template splunk-enterprise-staged "${validation_dir}/splunk-enterprise-${enterprise_chart_version}.tgz" \
      --set splunk-operator.enabled=false \
      --set s1.enabled=true \
      > "${validation_dir}/splunk-enterprise-rendered.yaml"

    publication_status="published-and-validated"
    internal_publish_validated="true"
  else
    publication_status="auth-pending"
  fi
else
  if [ -n "${legacy_index_url}" ]; then
    helm repo index "${chart_output_dir}" --url "${legacy_index_url}"
  else
    helm repo index "${chart_output_dir}"
  fi
  publication_status="legacy-index-only"
  legacy_index_generated="true"
fi

if bool_is_true "${legacy_index_required}" && [ "${legacy_index_generated}" != "true" ]; then
  if [ -n "${legacy_index_url}" ]; then
    helm repo index "${chart_output_dir}" --url "${legacy_index_url}"
  else
    helm repo index "${chart_output_dir}"
  fi
  legacy_index_generated="true"
fi

printf '%s\n' "${publication_status}" > "${publication_state_file}"
cat > "${compatibility_state_file}" <<EOF
legacy_index_required=${legacy_index_required}
legacy_index_generated=${legacy_index_generated}
official_chart_release_target=${official_chart_release_target}
internal_auth_mode=${internal_auth_mode}
EOF

cat > "${publication_plan}" <<EOF
# Helm Chart Publication And Certification Plan

- staging_chart_target: ${chart_release_target}
- official_chart_target: ${official_chart_release_target}
- chart_output_dir: ${chart_output_dir}
- publication_status: ${publication_status}
- internal_publish_validated: ${internal_publish_validated}
- legacy_index_required: ${legacy_index_required}
- legacy_index_generated: ${legacy_index_generated}
- internal_auth_mode: ${internal_auth_mode}

## Internal publication

1. Package and lint both Helm charts in GitLab.
2. Publish them to the internal OCI chart repository when chart registry credentials are present.
3. Validate installability by pulling the published OCI charts and rendering them locally.
4. Generate a legacy \`index.yaml\` only when a compatibility consumer still requires non-OCI chart layout.
5. Keep GitHub Pages read-only until the official publication phase is approved.

## Official external publication

1. The official GA OCI destination is configured separately through \`OFFICIAL_CHART_RELEASE_REPOSITORY\`.
2. Rehearsal does not publish externally, but it records the exact external target that the approved release lane will use.
3. Public publication remains downstream of release approval and outside the current rehearsal job.

## Certification and ecosystem verification

1. Run chart verification against the staged chart repository before official publication.
2. Preserve the chart package, OCI publication plan, and verifier outputs as release evidence.
3. Update public Helm and Artifact Hub metadata only after the canonical GitLab release succeeds.
4. Treat \`docs/index.yaml\`, \`docs/cr.yaml\`, and \`docs/artifacthub-repo.yml\` as legacy compatibility consumers until the public OCI publication path fully replaces them.
EOF
