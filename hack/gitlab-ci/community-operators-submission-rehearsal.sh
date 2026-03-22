#!/bin/sh
set -eu

# Runtime contract
# - Purpose: prepare the community-operators catalog submission pack for the current SOK release.
# - Inputs: release version, community-operators package metadata, and current upstream ci.yaml contract.
# - Outputs: PR-ready plan and metadata summary under rehearsal/.
# - Guardrails: no external PR creation during rehearsal.

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/operator-catalog-submission-common.sh"

catalog_submission_init

package_name="${STAGING_COMMUNITY_OPERATOR_PACKAGE_NAME:-splunk}"
target_repo="${STAGING_COMMUNITY_OPERATOR_REPO:-k8s-operatorhub/community-operators}"
ci_yaml_path="${STAGING_COMMUNITY_OPERATOR_CI_YAML_PATH:-operators/${package_name}/ci.yaml}"
bundle_directory="${STAGING_COMMUNITY_OPERATOR_BUNDLE_DIR:-operators/${package_name}/${release_version}}"
reviewers="${STAGING_COMMUNITY_OPERATOR_REVIEWERS:-vivekr-splunk,rlieberman-splunk,kasiakoziol,patrykw-splunk,Igor-splunk}"
update_graph="${STAGING_COMMUNITY_OPERATOR_UPDATE_GRAPH:-replaces-mode}"
openshift_versions="${STAGING_COMMUNITY_OPERATOR_OPENSHIFT_VERSIONS:-v4.11-v4.20}"
default_channel="${STAGING_COMMUNITY_OPERATOR_DEFAULT_CHANNEL:-stable}"

append_context "${context_file}" "target_repo" "${target_repo}"
append_context "${context_file}" "package_name" "${package_name}"
append_context "${context_file}" "release_version" "${release_version}"
append_context "${context_file}" "release_candidate_version" "${release_candidate_version}"
append_context "${context_file}" "ci_yaml_path" "${ci_yaml_path}"
append_context "${context_file}" "bundle_directory" "${bundle_directory}"
append_context "${context_file}" "reviewers" "${reviewers}"
append_context "${context_file}" "update_graph" "${update_graph}"
append_context "${context_file}" "openshift_versions" "${openshift_versions}"
append_context "${context_file}" "default_channel" "${default_channel}"

cat > "${submission_file}" <<EOF
# Community Operators Submission Plan

- target repo: ${target_repo}
- package: ${package_name}
- release version: ${release_version}
- release candidate ordinal: ${release_candidate_version}
- ci.yaml path: ${ci_yaml_path}
- bundle directory: ${bundle_directory}
- current update graph: ${update_graph}
- current reviewers: ${reviewers}
- current channel: ${default_channel}
- current OpenShift support annotation: ${openshift_versions}

## Current upstream contract

The live community-operators entry already exists at:

- \`${target_repo}/${bundle_directory}\`
- package name: \`${package_name}\`
- \`${ci_yaml_path}\` currently uses \`${update_graph}\`
- current reviewers list should stay aligned unless maintainers review a change explicitly

## Release-stage work

1. Render the new bundle payload into \`${bundle_directory}\`.
2. Keep the package annotation as \`${package_name}\`.
3. Preserve the current stable channel contract unless the reviewed release decision changes it.
4. Validate the bundle before PR creation:
   - \`operator-sdk bundle validate --select-optional name=operatorhub .\`
   - optional \`operator-sdk scorecard\`
5. Confirm \`com.redhat.openshift.versions\` covers the latest supported OpenShift release before opening the PR.
6. Keep community metadata aligned with the current reviewers and update-graph policy.

## Rehearsal guardrails

- This job does not create external PRs.
- This job does not mutate the community-operators repo.
- Any reviewer or update-graph changes should be reviewed explicitly rather than inferred in the pipeline.
EOF

write_catalog_common_summary "community-operators" "${target_repo}" "${package_name}" "${bundle_directory}"
