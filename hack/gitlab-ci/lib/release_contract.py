from __future__ import annotations

import json
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_dotenv(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def first_non_empty(*values: str | None, default: str = "") -> str:
    for value in values:
        if value is not None and str(value).strip():
            return str(value).strip()
    return default


def bool_env(value: str | None, default: bool = False) -> bool:
    if value is None or value == "":
        return default
    return value.strip().lower() in {"1", "true", "yes", "y"}


def read_makefile_version(project_dir: Path) -> str:
    makefile = project_dir / "Makefile"
    for raw_line in makefile.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line.startswith("VERSION") and "?=" in line:
            return line.split("?=", 1)[1].strip()
    raise RuntimeError("Unable to resolve VERSION from Makefile")


def infer_enterprise_version(image_ref: str, env: dict[str, str]) -> str:
    if env.get("SPLUNK_VERSION"):
        return env["SPLUNK_VERSION"]
    if env.get("STAGING_ENTERPRISE_VERSION"):
        return env["STAGING_ENTERPRISE_VERSION"]
    if ":" in image_ref:
        return image_ref.rsplit(":", 1)[1]
    return "unknown"


@dataclass
class ReleaseContext:
    manifest: dict[str, object]
    output_dir: Path


def build_release_context(project_dir: Path, output_dir: Path) -> ReleaseContext:
    env = dict(os.environ)
    dotenv = read_dotenv(project_dir / ".env")
    cycle_contract = read_dotenv(project_dir / "release-process" / "cycle-template.env")

    operator_version = first_non_empty(
        env.get("SOK_BASELINE_TAG"),
        cycle_contract.get("SOK_BASELINE_TAG"),
        env.get("STAGING_RELEASE_VERSION"),
        dotenv.get("VERSION"),
        default=read_makefile_version(project_dir),
    )
    enterprise_image = first_non_empty(
        env.get("SPLUNK_ENTERPRISE_RELEASE_IMAGE"),
        env.get("SPLUNK_ENTERPRISE_IMAGE"),
        env.get("STAGING_SPLUNK_ENTERPRISE_IMAGE"),
        cycle_contract.get("SPLUNK_ENTERPRISE_IMAGE"),
        dotenv.get("RELATED_IMAGE_SPLUNK_ENTERPRISE"),
        default="unknown",
    )
    pipeline_mode = env.get("REHEARSAL_PIPELINE_MODE", "full")
    release_required = bool_env(
        first_non_empty(
            env.get("SOK_RELEASE_REQUIRED"),
            cycle_contract.get("PRODUCT_RELEASE_REQUIRED"),
            default="false",
        ),
        default=False,
    )
    explicit_lane = first_non_empty(env.get("SOK_LANE"), cycle_contract.get("REQUESTED_LANE"), default="")
    if explicit_lane == "auto":
        explicit_lane = ""
    if explicit_lane:
        effective_lane = explicit_lane
        selection_reason = "explicit-sok-lane"
    elif pipeline_mode == "release_train" or release_required:
        effective_lane = "product-release"
        selection_reason = "release-train-or-release-required"
    else:
        effective_lane = "qualification"
        selection_reason = "default-qualification"

    release_candidate_version = first_non_empty(
        env.get("STAGING_RELEASE_CANDIDATE_VERSION"),
        cycle_contract.get("RELEASE_CANDIDATE_VERSION"),
        default="1",
    )
    target_release_version = first_non_empty(
        env.get("STAGING_RELEASE_VERSION"),
        env.get("PRODUCT_RELEASE_VERSION"),
        cycle_contract.get("PRODUCT_RELEASE_VERSION"),
        default=operator_version,
    )
    qualification_profiles = first_non_empty(
        env.get("SOK_QUALIFICATION_PROFILES"),
        cycle_contract.get("QUALIFICATION_PROFILES"),
        default="smoke,upgrade,latest3,helm,arch-matrix",
    )
    manifest = {
        "schema_version": "v1alpha1",
        "generated_at_utc": utc_now(),
        "gitlab": {
            "project_path": env.get("CI_PROJECT_PATH", "unknown"),
            "pipeline_id": env.get("CI_PIPELINE_ID", "unknown"),
            "pipeline_url": env.get("CI_PIPELINE_URL", "unknown"),
            "job_id": env.get("CI_JOB_ID", "unknown"),
            "job_url": env.get("CI_JOB_URL", "unknown"),
            "pipeline_source": env.get("CI_PIPELINE_SOURCE", "unknown"),
            "pipeline_mode": pipeline_mode,
            "ref_name": env.get("CI_COMMIT_REF_NAME", "unknown"),
            "commit_sha": env.get("CI_COMMIT_SHA", "unknown"),
        },
        "source": {
            "trigger_source": first_non_empty(
                env.get("SOK_TRIGGER_SOURCE"),
                cycle_contract.get("TRIGGER_SOURCE"),
                env.get("CI_PIPELINE_SOURCE"),
                default="manual-rehearsal",
            ),
            "trigger_reason": first_non_empty(env.get("SOK_TRIGGER_REASON"), default="release-qualification-rehearsal"),
            "cycle_id": first_non_empty(env.get("SOK_CYCLE_ID"), cycle_contract.get("CYCLE_ID"), default="unversioned-cycle"),
            "planned_start_date": first_non_empty(cycle_contract.get("PLANNED_START_DATE"), default="unplanned"),
            "branch_cut_date": first_non_empty(cycle_contract.get("BRANCH_CUT_DATE"), default="unknown"),
        },
        "lane": {
            "selected": effective_lane,
            "selection_reason": selection_reason,
            "release_required": release_required,
            "public_publication_enabled": False,
        },
        "splunk": {
            "branch": first_non_empty(
                env.get("SPLUNK_BRANCH"),
                env.get("RELEASE_COMMIT_REF_NAME"),
                cycle_contract.get("SPLUNK_RELEASE_BRANCH"),
                default="unknown",
            ),
            "version": first_non_empty(
                env.get("SPLUNK_VERSION"),
                env.get("STAGING_ENTERPRISE_VERSION"),
                cycle_contract.get("SPLUNK_RELEASE_VERSION"),
                default=infer_enterprise_version(enterprise_image, env),
            ),
            "hash": first_non_empty(
                env.get("SPLUNK_HASH"),
                env.get("RELEASE_COMMIT_SHA_MAIN"),
                cycle_contract.get("SPLUNK_RELEASE_SHA"),
                default="unknown",
            ),
            "major": first_non_empty(env.get("SPLUNK_MAJOR"), default="unknown"),
            "enterprise_image": enterprise_image,
            "enterprise_image_digest": first_non_empty(
                env.get("SPLUNK_ENTERPRISE_IMAGE_DIGEST"),
                cycle_contract.get("SPLUNK_ENTERPRISE_IMAGE_DIGEST"),
                default="unknown",
            ),
            "architecture": first_non_empty(env.get("ARCHITECTURE"), default="amd64"),
            "platform": first_non_empty(env.get("PLATFORM"), default="linux/amd64"),
        },
        "sok": {
            "baseline_branch": first_non_empty(
                env.get("SOK_BASELINE_BRANCH"),
                cycle_contract.get("SOK_BASELINE_BRANCH"),
                default="main",
            ),
            "develop_branch": first_non_empty(env.get("SOK_DEVELOP_BRANCH"), default="develop"),
            "baseline_version": operator_version,
            "target_release_version": target_release_version,
            "release_candidate_version": release_candidate_version,
            "release_branch": first_non_empty(
                env.get("SOK_RELEASE_BRANCH"),
                cycle_contract.get("PRODUCT_RELEASE_BRANCH"),
                default=(f"release/{target_release_version}" if effective_lane == "product-release" else ""),
            ),
        },
        "qualification": {
            "profile": first_non_empty(
                env.get("SOK_QUALIFICATION_PROFILE"),
                cycle_contract.get("QUALIFICATION_PROFILE"),
                env.get("STAGING_INT_TEST_PROFILE"),
                default="smoke",
            ),
            "helm_profile": first_non_empty(
                env.get("SOK_HELM_PROFILE"),
                cycle_contract.get("HELM_PROFILE"),
                env.get("STAGING_HELM_TEST_PROFILE"),
                default="smoke",
            ),
            "profiles": [value.strip() for value in qualification_profiles.split(",") if value.strip()],
            "integration_focus": first_non_empty(env.get("STAGING_INT_TEST_FOCUS"), default="managersecret"),
            "required_jobs": [
                "release-manifest-resolve-rehearsal",
                "lane-select-rehearsal",
                "build-test-push-rehearsal",
                "build-test-push-trivy-scan",
                "int-test-workflow-rehearsal",
                "helm-test-workflow-rehearsal",
                "qualification-report-rehearsal",
                "compatibility-publish-rehearsal",
            ],
        },
        "release": {
            "release_repository": first_non_empty(env.get("STAGING_RELEASE_REPOSITORY"), default="unset"),
            "release_bucket": first_non_empty(env.get("STAGING_RELEASE_BUCKET"), default="unset"),
            "release_notes_target": first_non_empty(env.get("STAGING_RELEASE_NOTES_TARGET"), default="unset"),
            "bundle_registry": first_non_empty(env.get("STAGING_BUNDLE_REGISTRY"), default="unset"),
        },
        "governance": {
            "approvals_required": 1 if effective_lane == "product-release" else 0,
            "review_required": True,
            "decision_repo": "sok/decision-records",
            "linked_splrel": first_non_empty(cycle_contract.get("LINKED_SPLREL"), default="unlinked"),
            "linked_rdmp": first_non_empty(cycle_contract.get("LINKED_RDMP"), default="unlinked"),
            "cycle_owner": first_non_empty(cycle_contract.get("CYCLE_OWNER"), default="unassigned"),
        },
    }
    return ReleaseContext(manifest=manifest, output_dir=output_dir)


def write_json(path: Path, payload: dict[str, object]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_dotenv(path: Path, manifest: dict[str, object]) -> None:
    lane = manifest["lane"]
    splunk = manifest["splunk"]
    qualification = manifest["qualification"]
    sok = manifest["sok"]
    release = manifest["release"]
    lines = [
        f"SOK_EFFECTIVE_LANE={lane['selected']}",
        f"SOK_LANE_SELECTION_REASON={lane['selection_reason']}",
        f"SOK_RELEASE_REQUIRED={'true' if lane['release_required'] else 'false'}",
        f"SOK_PUBLIC_PUBLICATION_ENABLED={'true' if lane['public_publication_enabled'] else 'false'}",
        f"SOK_BASELINE_BRANCH={sok['baseline_branch']}",
        f"SOK_BASELINE_VERSION={sok['baseline_version']}",
        f"SOK_TARGET_RELEASE_VERSION={sok['target_release_version']}",
        f"SOK_RELEASE_CANDIDATE_VERSION={sok['release_candidate_version']}",
        f"SOK_RELEASE_BRANCH={sok['release_branch']}",
        f"SOK_SPLUNK_BRANCH={splunk['branch']}",
        f"SOK_SPLUNK_VERSION={splunk['version']}",
        f"SOK_ENTERPRISE_IMAGE={splunk['enterprise_image']}",
        f"SOK_QUALIFICATION_PROFILE={qualification['profile']}",
        f"SOK_HELM_PROFILE={qualification['helm_profile']}",
        f"SOK_QUALIFICATION_PROFILES={','.join(qualification['profiles'])}",
        f"SOK_RELEASE_REPOSITORY={release['release_repository']}",
        f"SOK_RELEASE_BUCKET={release['release_bucket']}",
        f"SOK_RELEASE_NOTES_TARGET={release['release_notes_target']}",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
