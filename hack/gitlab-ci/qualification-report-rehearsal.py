#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path


def aliases_for_slug(slug: str) -> list[str]:
    aliases = [slug]
    if slug.endswith("-workflow"):
        aliases.append(f"{slug[:-len('-workflow')]}-rehearsal")
    aliases.append(f"{slug}-rehearsal")
    deduped: list[str] = []
    for alias in aliases:
        if alias not in deduped:
            deduped.append(alias)
    return deduped


def load_job_artifacts(rehearsal_dir: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for mode_file in sorted(rehearsal_dir.glob("*-mode.txt")):
        slug = mode_file.name[: -len("-mode.txt")]
        rows.append(
            {
                "slug": slug,
                "mode": mode_file.read_text(encoding="utf-8").strip() or "unknown",
                "status": (rehearsal_dir / f"{slug}-status.txt").read_text(encoding="utf-8").strip()
                if (rehearsal_dir / f"{slug}-status.txt").exists()
                else "",
            }
        )
    return rows


def main() -> int:
    rehearsal_dir = Path.cwd() / "rehearsal"
    output_dir = rehearsal_dir / "release-controller"
    output_dir.mkdir(parents=True, exist_ok=True)

    manifest = json.loads((output_dir / "release-cycle-manifest.json").read_text(encoding="utf-8"))
    lane_selection = json.loads((output_dir / "lane-selection.json").read_text(encoding="utf-8"))
    jobs = load_job_artifacts(rehearsal_dir)
    evidence_job_names = [
        job
        for job in lane_selection.get("next_jobs", [])
        if job not in {"qualification-report-rehearsal", "compatibility-publish-rehearsal"}
    ]
    jobs_by_alias: dict[str, dict[str, str]] = {}
    for job in jobs:
        for alias in aliases_for_slug(job["slug"]):
            jobs_by_alias.setdefault(alias, job)
    observed_jobs = [jobs_by_alias[name] for name in evidence_job_names if name in jobs_by_alias]

    blocked = [job["slug"] for job in observed_jobs if job["mode"] == "blocked-missing-vars"]
    plan_only = [job["slug"] for job in observed_jobs if job["mode"] == "plan-only"]
    executed = [job["slug"] for job in observed_jobs if job["mode"] == "executed-runtime"]
    missing = [job for job in evidence_job_names if job not in jobs_by_alias]

    override = os.environ.get("SOK_QUALIFICATION_DISPOSITION", "").strip()
    if override:
        disposition = override
        disposition_reason = "explicit-override"
    elif lane_selection["selected_lane"] == "product-release":
        disposition = "new SOK release required"
        disposition_reason = "product-release lane selected"
    elif missing:
        disposition = "qualified with caveats"
        disposition_reason = "missing evidence jobs"
    elif blocked or plan_only:
        disposition = "qualified with caveats"
        disposition_reason = "partial or blocked evidence"
    else:
        disposition = "qualified with current SOK"
        disposition_reason = "all selected evidence jobs executed"

    compatibility = {
        "schema_version": "v1alpha1",
        "cycle_id": manifest["source"]["cycle_id"],
        "generated_at_utc": manifest["generated_at_utc"],
        "baseline_version": manifest["sok"]["baseline_version"],
        "splunk_version": manifest["splunk"]["version"],
        "splunk_branch": manifest["splunk"]["branch"],
        "selected_lane": lane_selection["selected_lane"],
        "disposition": disposition,
        "disposition_reason": disposition_reason,
        "release_required": lane_selection["release_required"],
        "executed_jobs": executed,
        "plan_only_jobs": plan_only,
        "blocked_jobs": blocked,
        "missing_jobs": missing,
    }
    qualification_manifest = {
        "schema_version": "v1alpha1",
        "cycle_id": manifest["source"]["cycle_id"],
        "selected_lane": lane_selection["selected_lane"],
        "baseline_version": manifest["sok"]["baseline_version"],
        "splunk_version": manifest["splunk"]["version"],
        "splunk_branch": manifest["splunk"]["branch"],
        "qualification_profile": manifest["qualification"]["profile"],
        "helm_profile": manifest["qualification"]["helm_profile"],
        "qualification_profiles": manifest["qualification"].get("profiles", []),
        "required_jobs": manifest["qualification"]["required_jobs"],
    }
    compatibility_decision = {
        "schema_version": "v1alpha1",
        "cycle_id": manifest["source"]["cycle_id"],
        "selected_lane": lane_selection["selected_lane"],
        "disposition": disposition,
        "disposition_reason": disposition_reason,
        "release_required": lane_selection["release_required"],
    }
    blocker_summary = {
        "schema_version": "v1alpha1",
        "cycle_id": manifest["source"]["cycle_id"],
        "bucket_counts": {
            "infra": 0,
            "test": len(blocked) + len(missing),
            "sok": 0,
            "splunk": 0,
        },
        "blocked_jobs": blocked,
        "missing_jobs": missing,
    }
    (output_dir / "qualification-manifest.json").write_text(
        json.dumps(qualification_manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (output_dir / "compatibility-decision.json").write_text(
        json.dumps(compatibility_decision, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (output_dir / "blocker-summary.json").write_text(
        json.dumps(blocker_summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (output_dir / "compatibility-record.json").write_text(
        json.dumps(compatibility, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (output_dir / "qualification-report.md").write_text(
        "\n".join(
            [
                "# Qualification Report",
                "",
                f"- selected_lane: {lane_selection['selected_lane']}",
                f"- disposition: {disposition}",
                f"- disposition_reason: {disposition_reason}",
                f"- baseline_version: {manifest['sok']['baseline_version']}",
                f"- splunk_version: {manifest['splunk']['version']}",
                f"- qualification_profile: {manifest['qualification']['profile']}",
                f"- helm_profile: {manifest['qualification']['helm_profile']}",
                f"- cycle_id: {manifest['source']['cycle_id']}",
                f"- linked_splrel: {manifest['governance']['linked_splrel']}",
                f"- linked_rdmp: {manifest['governance']['linked_rdmp']}",
                "",
                "## Executed Jobs",
                *([f"- {job}" for job in executed] or ["- none"]),
                "",
                "## Plan Only Jobs",
                *([f"- {job}" for job in plan_only] or ["- none"]),
                "",
                "## Blocked Jobs",
                *([f"- {job}" for job in blocked] or ["- none"]),
                "",
                "## Missing Jobs",
                *([f"- {job}" for job in missing] or ["- none"]),
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    print(output_dir / "qualification-report.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
