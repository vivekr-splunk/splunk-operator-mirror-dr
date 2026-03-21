#!/bin/sh
set -eu

. "${CI_PROJECT_DIR}/hack/gitlab-ci/lib/rehearsal-common.sh"

mkdir -p rehearsal

context_file="rehearsal/${WORKFLOW_SLUG}-runtime-context.txt"
summary_file="rehearsal/${WORKFLOW_SLUG}-summary.txt"
report_file="rehearsal/${WORKFLOW_SLUG}-health.md"
refs_file="rehearsal/${WORKFLOW_SLUG}-ref-compare.tsv"

mirror_repo="${STAGING_GITHUB_MIRROR_REPO:-}"
mirror_compare_refs="${STAGING_GITHUB_MIRROR_COMPARE_REFS:-main,develop}"
mirror_token_present="false"
mirror_url="https://github.com/${mirror_repo}.git"

if [ -n "${STAGING_GITHUB_MIRROR_TOKEN:-}" ]; then
  mirror_token_present="true"
  mirror_url="https://x-access-token:${STAGING_GITHUB_MIRROR_TOKEN}@github.com/${mirror_repo}.git"
fi

: > "${context_file}"
: > "${summary_file}"
: > "${report_file}"
: > "${refs_file}"

append_context "${context_file}" "observed_at_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
append_context "${context_file}" "mirror_repo" "${mirror_repo}"
append_context "${context_file}" "mirror_compare_refs" "${mirror_compare_refs}"
append_context "${context_file}" "mirror_token_present" "${mirror_token_present}"
append_context "${context_file}" "mutation_policy" "read-only"

remote_refs="$(git ls-remote "${mirror_url}")"

old_ifs="${IFS}"
IFS=','
for raw_ref in ${mirror_compare_refs}; do
  ref_name="$(trim_csv_field "${raw_ref}")"
  [ -z "${ref_name}" ] && continue

  local_sha=""
  remote_sha=""
  status="missing-local"

  if git rev-parse --verify "refs/heads/${ref_name}" >/dev/null 2>&1; then
    local_sha="$(git rev-parse "refs/heads/${ref_name}")"
    status="missing-remote"
  fi

  remote_sha="$(printf '%s\n' "${remote_refs}" | awk '$2=="refs/heads/'"${ref_name}"'" {print $1; exit}')"

  if [ -n "${local_sha}" ] && [ -n "${remote_sha}" ]; then
    if [ "${local_sha}" = "${remote_sha}" ]; then
      status="match"
    else
      status="mismatch"
    fi
  fi

  printf '%s\t%s\t%s\t%s\n' "${ref_name}" "${status}" "${local_sha:-missing}" "${remote_sha:-missing}" >> "${refs_file}"
done
IFS="${old_ifs}"

cat > "${report_file}" <<EOF
# GitHub Mirror Health Check

- Mirror repository: \`${mirror_repo}\`
- Compared refs: \`${mirror_compare_refs}\`
- Token present: \`${mirror_token_present}\`
- Mutation policy: read-only

This rehearsal checks read-only branch parity against the configured GitHub repository. It does not push, disable, or mutate any GitHub mirror settings.
EOF

cat > "${summary_file}" <<EOF
mirror_repo=${mirror_repo}
mirror_compare_refs=${mirror_compare_refs}
mirror_token_present=${mirror_token_present}
mutation_policy=read-only
EOF
