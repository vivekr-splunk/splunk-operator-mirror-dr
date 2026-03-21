#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from lib.release_contract import build_release_context, write_dotenv, write_json


def main() -> int:
    project_dir = Path.cwd()
    output_dir = project_dir / "rehearsal" / "release-controller"
    output_dir.mkdir(parents=True, exist_ok=True)

    context = build_release_context(project_dir, output_dir)
    manifest_path = output_dir / "release-cycle-manifest.json"
    dotenv_path = output_dir / "release-cycle.env"
    summary_path = output_dir / "release-cycle-summary.md"

    write_json(manifest_path, context.manifest)
    write_dotenv(dotenv_path, context.manifest)

    lane = context.manifest["lane"]
    splunk = context.manifest["splunk"]
    sok = context.manifest["sok"]
    qualification = context.manifest["qualification"]
    release = context.manifest["release"]

    summary_path.write_text(
        "\n".join(
            [
                "# Release Cycle Manifest",
                "",
                f"- lane: {lane['selected']}",
                f"- selection_reason: {lane['selection_reason']}",
                f"- release_required: {lane['release_required']}",
                f"- cycle_file: {context.manifest['source']['cycle_file']}",
                f"- cycle_file_source: {context.manifest['source']['cycle_file_source']}",
                f"- source_mode: {context.manifest['source']['source_mode']}",
                f"- trigger_kind: {context.manifest['source']['trigger_kind']}",
                f"- splunk_branch: {splunk['branch']}",
                f"- splunk_version: {splunk['version']}",
                f"- enterprise_image: {splunk['enterprise_image']}",
                f"- enterprise_image_source: {splunk['enterprise_image_source']}",
                f"- baseline_version: {sok['baseline_version']}",
                f"- target_release_version: {sok['target_release_version']}",
                f"- release_branch: {sok['release_branch'] or 'not-required'}",
                f"- qualification_profile: {qualification['profile']}",
                f"- helm_profile: {qualification['helm_profile']}",
                f"- release_repository: {release['release_repository']}",
                f"- release_bucket: {release['release_bucket']}",
                f"- release_notes_target: {release['release_notes_target']}",
                f"- cycle_id: {context.manifest['source']['cycle_id']}",
                f"- planned_start_date: {context.manifest['source']['planned_start_date']}",
                f"- branch_cut_date: {context.manifest['source']['branch_cut_date']}",
                f"- linked_splrel: {context.manifest['governance']['linked_splrel']}",
                f"- linked_rdmp: {context.manifest['governance']['linked_rdmp']}",
                f"- cycle_owner: {context.manifest['governance']['cycle_owner']}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    print(manifest_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
