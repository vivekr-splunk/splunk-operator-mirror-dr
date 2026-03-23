#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path


def main() -> int:
    output_dir = Path.cwd() / "rehearsal" / "release-controller"
    manifest_path = output_dir / "release-cycle-manifest.json"
    selection_json = output_dir / "lane-selection.json"
    selection_env = output_dir / "lane-selection.env"
    selection_md = output_dir / "lane-selection.md"

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    lane = manifest["lane"]["selected"]
    release_required = bool(manifest["lane"]["release_required"])
    if lane == "product-release":
        next_jobs = [
            "pre-release-workflow-rehearsal",
            "automated-release-workflow-rehearsal",
            "release-image-stage-rehearsal",
            "fips-smoke-release-rehearsal",
            "fips-int-test-release-rehearsal",
            "psr-release-qualification-rehearsal",
            "psr-release-qualification-dispatch",
            "psr-release-qualification-collect",
            "release-charts-workflow-rehearsal",
            "bundle-push-post-release-rehearsal",
            "preflight-certification-rehearsal",
            "docker-splunk-preflight-certification-rehearsal",
            "certified-operators-submission-rehearsal",
            "community-operators-submission-rehearsal",
            "release-branch-to-main-rehearsal",
        ]
        approval_gate = "rc-to-ga-promotion"
    else:
        next_jobs = [
            "build-test-push-rehearsal",
            "build-test-push-trivy-scan",
            "int-test-workflow-rehearsal",
            "helm-test-workflow-rehearsal",
            "qualification-report-rehearsal",
            "compatibility-publish-rehearsal",
        ]
        approval_gate = "qualification-disposition-review"

    selection = {
        "selected_lane": lane,
        "selection_reason": manifest["lane"]["selection_reason"],
        "release_required": release_required,
        "release_branch": manifest["sok"]["release_branch"],
        "approval_gate": approval_gate,
        "next_jobs": next_jobs,
    }
    selection_json.write_text(json.dumps(selection, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    selection_env.write_text(
        "\n".join(
            [
                f"SOK_SELECTED_LANE={lane}",
                f"SOK_LANE_SELECTION_REASON={manifest['lane']['selection_reason']}",
                f"SOK_RELEASE_REQUIRED={'true' if release_required else 'false'}",
                f"SOK_RELEASE_BRANCH={manifest['sok']['release_branch']}",
                f"SOK_APPROVAL_GATE={approval_gate}",
                f"SOK_NEXT_JOBS={','.join(next_jobs)}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    selection_md.write_text(
        "\n".join(
            [
                "# Lane Selection",
                "",
                f"- selected_lane: {lane}",
                f"- selection_reason: {manifest['lane']['selection_reason']}",
                f"- release_required: {release_required}",
                f"- release_branch: {manifest['sok']['release_branch'] or 'not-required'}",
                f"- approval_gate: {approval_gate}",
                "- next_jobs:",
                *[f"  - {job}" for job in next_jobs],
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    print(selection_json)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
