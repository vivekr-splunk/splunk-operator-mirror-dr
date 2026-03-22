#!/bin/sh
set -eu

# Runtime contract
# - Purpose: prepare the Red Hat certified-operators catalog submission pack for the current SOK release.
# - Inputs: release version, certified-operators package metadata, and current upstream ci.yaml contract.
# - Outputs: PR-ready plan and metadata summary under rehearsal/.
# - Guardrails: no external PR creation or partner-portal mutation during rehearsal.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/operator-catalog-submission-common.sh"

catalog_submission_init

package_name="${STAGING_CERTIFIED_OPERATOR_PACKAGE_NAME:-splunk-operator}"
target_repo="${STAGING_CERTIFIED_OPERATOR_REPO:-redhat-openshift-ecosystem/certified-operators}"
ci_yaml_path="${STAGING_CERTIFIED_OPERATOR_CI_YAML_PATH:-operators/${package_name}/ci.yaml}"
bundle_directory="${STAGING_CERTIFIED_OPERATOR_BUNDLE_DIR:-operators/${package_name}/${release_version}}"
current_cert_project_id="${STAGING_CERTIFIED_OPERATOR_CURRENT_CI_PROJECT_ID:-5f64e4d0b7bfb679a1646a8a}"
target_component_id="${STAGING_PYXIS_CERTIFICATION_PROJECT_OBJECT_ID:-unset}"
openshift_versions="${STAGING_CERTIFIED_OPERATOR_OPENSHIFT_VERSIONS:-v4.11-v4.20}"
default_channel="${STAGING_CERTIFIED_OPERATOR_DEFAULT_CHANNEL:-stable}"

append_context "${context_file}" "target_repo" "${target_repo}"
append_context "${context_file}" "package_name" "${package_name}"
append_context "${context_file}" "release_version" "${release_version}"
append_context "${context_file}" "release_candidate_version" "${release_candidate_version}"
append_context "${context_file}" "ci_yaml_path" "${ci_yaml_path}"
append_context "${context_file}" "bundle_directory" "${bundle_directory}"
append_context "${context_file}" "current_cert_project_id" "${current_cert_project_id}"
append_context "${context_file}" "target_component_id" "${target_component_id}"
append_context "${context_file}" "openshift_versions" "${openshift_versions}"
append_context "${context_file}" "default_channel" "${default_channel}"

cat > "${submission_file}" <<EOF
# Certified Operators Submission Plan

- target repo: ${target_repo}
- package: ${package_name}
- release version: ${release_version}
- release candidate ordinal: ${release_candidate_version}
- ci.yaml path: ${ci_yaml_path}
- bundle directory: ${bundle_directory}
- current upstream cert_project_id: ${current_cert_project_id}
- current channel: ${default_channel}
- current OpenShift support annotation: ${openshift_versions}
- release container certification component id: ${target_component_id}

## Current upstream contract

The live certified-operators entry already exists at:

- \`${target_repo}/${bundle_directory}\`
- package name: \`${package_name}\`
- \`${ci_yaml_path}\` currently pins \`cert_project_id: ${current_cert_project_id}\`

## Release-stage work

1. Render the new bundle payload into \`${bundle_directory}\`.
2. Keep the package annotation as \`${package_name}\`.
3. Preserve the current stable channel contract unless the reviewed release decision changes it.
4. Validate the bundle before PR creation:
   - \`operator-sdk bundle validate --select-optional name=operatorhub .\`
   - scorecard evidence if required by the release checklist
5. Confirm \`com.redhat.openshift.versions\` covers the latest supported OpenShift release before opening the PR.
6. Attach container preflight evidence from:
   - \`preflight-certification-rehearsal\`
   - \`docker-splunk-preflight-certification-rehearsal\`

## Rehearsal guardrails

- This job does not create external PRs.
- This job does not change Partner Connect state.
- If the certified-operators \`ci.yaml\` project binding must change from \`${current_cert_project_id}\`, that should be a reviewed follow-up decision instead of an implicit pipeline mutation.
EOF

write_catalog_common_summary "certified-operators" "${target_repo}" "${package_name}" "${bundle_directory}"
