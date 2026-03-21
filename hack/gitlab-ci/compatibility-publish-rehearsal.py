#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path


def main() -> int:
    output_dir = Path.cwd() / "rehearsal" / "release-controller"
    output_dir.mkdir(parents=True, exist_ok=True)

    manifest = json.loads((output_dir / "release-cycle-manifest.json").read_text(encoding="utf-8"))
    lane_selection = json.loads((output_dir / "lane-selection.json").read_text(encoding="utf-8"))
    compatibility = json.loads((output_dir / "compatibility-record.json").read_text(encoding="utf-8"))
    blocker_summary = json.loads((output_dir / "blocker-summary.json").read_text(encoding="utf-8"))

    confluence_target = os.environ.get("SOK_COMPATIBILITY_CONFLUENCE_TARGET", "decision-records/migration")
    slack_target = os.environ.get("SOK_COMPATIBILITY_SLACK_TARGET", "sok-release-qualification")
    status_record_target = os.environ.get("SOK_COMPATIBILITY_STATUS_RECORD", "compatibility-matrix")

    publish_plan = {
        "schema_version": "v1alpha1",
        "cycle_id": manifest["source"]["cycle_id"],
        "selected_lane": lane_selection["selected_lane"],
        "disposition": compatibility["disposition"],
        "release_required": compatibility["release_required"],
        "targets": {
            "confluence": confluence_target,
            "slack": slack_target,
            "status_record": status_record_target,
        },
        "blocker_counts": blocker_summary["bucket_counts"],
        "next_action": (
            "open-product-release-lane"
            if compatibility["release_required"]
            else "publish-qualification-compatibility-update"
        ),
    }

    (output_dir / "compatibility-publish-plan.json").write_text(
        json.dumps(publish_plan, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (output_dir / "compatibility-publish-plan.md").write_text(
        "\n".join(
            [
                "# Compatibility Publish Plan",
                "",
                f"- cycle_id: {publish_plan['cycle_id']}",
                f"- selected_lane: {publish_plan['selected_lane']}",
                f"- disposition: {publish_plan['disposition']}",
                f"- release_required: {publish_plan['release_required']}",
                f"- confluence_target: {confluence_target}",
                f"- slack_target: {slack_target}",
                f"- status_record_target: {status_record_target}",
                f"- next_action: {publish_plan['next_action']}",
                "",
                "## Blocker Buckets",
                f"- infra: {blocker_summary['bucket_counts']['infra']}",
                f"- test: {blocker_summary['bucket_counts']['test']}",
                f"- sok: {blocker_summary['bucket_counts']['sok']}",
                f"- splunk: {blocker_summary['bucket_counts']['splunk']}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    print(output_dir / "compatibility-publish-plan.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
