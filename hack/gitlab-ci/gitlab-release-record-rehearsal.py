#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def bool_env(name: str, default: bool = False) -> bool:
    value = os.getenv(name, "")
    if not value:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def api_headers() -> dict[str, str]:
    private_token = os.getenv("STAGING_GITLAB_API_TOKEN", "").strip()
    if private_token:
        return {"PRIVATE-TOKEN": private_token}
    job_token = os.getenv("CI_JOB_TOKEN", "").strip()
    if job_token:
        return {"JOB-TOKEN": job_token}
    raise RuntimeError("Missing STAGING_GITLAB_API_TOKEN or CI_JOB_TOKEN for GitLab API access")


def api_request_json(method: str, url: str, payload: dict | None = None) -> dict | list:
    headers = api_headers()
    data = None
    if payload is not None:
        headers = {**headers, "Content-Type": "application/json"}
        data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, method=method, headers=headers, data=data)
    with urllib.request.urlopen(request) as response:
        body = response.read()
        if not body:
            return {}
        return json.loads(body)


def api_upload_file(url: str, path: Path) -> int:
    headers = api_headers()
    request = urllib.request.Request(url, method="PUT", headers=headers, data=path.read_bytes())
    with urllib.request.urlopen(request) as response:
        response.read()
        return response.status


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def load_optional_json(path: Path) -> dict | None:
    if not path.exists():
        return None
    return load_json(path)


def load_optional_text(path: Path) -> str | None:
    if not path.exists():
        return None
    return path.read_text(encoding="utf-8")


def release_tag_name(project_path: str, release_version: str, rc_version: str, pipeline_id: str) -> str:
    explicit = os.getenv("SOK_GITLAB_RELEASE_TAG", "").strip()
    if explicit:
        return explicit
    if project_path.endswith("splunk-operator-rehearsal"):
        return f"v{release_version}-rc{rc_version}-rehearsal-{pipeline_id}"
    return f"v{release_version}"


def release_name(project_path: str, release_version: str, rc_version: str, pipeline_id: str) -> str:
    explicit = os.getenv("SOK_GITLAB_RELEASE_NAME", "").strip()
    if explicit:
        return explicit
    if project_path.endswith("splunk-operator-rehearsal"):
        return f"Splunk Operator {release_version} RC{rc_version} rehearsal {pipeline_id}"
    return f"Splunk Operator {release_version}"


def package_version_from_tag(tag_name: str) -> str:
    explicit = os.getenv("SOK_GITLAB_RELEASE_PACKAGE_VERSION", "").strip()
    if explicit:
        return explicit
    return tag_name.removeprefix("v")


def release_download_url(project_url: str, tag_name: str, direct_asset_path: str) -> str:
    encoded_tag = urllib.parse.quote(tag_name, safe="")
    normalized_path = direct_asset_path if direct_asset_path.startswith("/") else f"/{direct_asset_path}"
    return f"{project_url}/-/releases/{encoded_tag}/downloads{normalized_path}"


def collect_assets(
    project_dir: Path,
    controller_dir: Path,
    package_base_url: str,
    project_url: str,
    tag_name: str,
) -> list[dict[str, str]]:
    assets: list[dict[str, str]] = []
    chart_record = load_optional_json(controller_dir / "chart-publication-record.json") or {}

    for item in chart_record.get("compatibility_assets", []):
        path = project_dir / item["path"]
        if not path.exists():
            continue
        name = path.name
        assets.append(
            {
                "name": name,
                "label": name,
                "path": str(path.relative_to(project_dir)),
                "upload_url": f"{package_base_url}/{urllib.parse.quote(name)}",
                "package_url": f"{package_base_url}/{urllib.parse.quote(name)}",
                "public_url": release_download_url(project_url, tag_name, f"/compatibility/{name}"),
                "link_type": "package",
                "direct_asset_path": f"/compatibility/{name}",
            }
        )

    extra_candidates = [
        ("draft-release-notes.md", project_dir / "rehearsal" / "pre-release-workflow-output" / "draft-release-notes.md", "runbook", "/notes/draft-release-notes.md"),
        ("release-manifest.env", project_dir / "rehearsal" / "automated-release-workflow-output" / "release-manifest.env", "other", "/manifests/release-manifest.env"),
        ("compatibility-publish-plan.md", controller_dir / "compatibility-publish-plan.md", "other", "/reports/compatibility-publish-plan.md"),
        ("chart-publication-record.md", controller_dir / "chart-publication-record.md", "other", "/reports/chart-publication-record.md"),
        ("qualification-report.md", controller_dir / "qualification-report.md", "other", "/reports/qualification-report.md"),
    ]
    for label, path, link_type, direct_asset_path in extra_candidates:
        if not path.exists():
            continue
        assets.append(
            {
                "name": path.name,
                "label": label,
                "path": str(path.relative_to(project_dir)),
                "upload_url": f"{package_base_url}/{urllib.parse.quote(path.name)}",
                "package_url": f"{package_base_url}/{urllib.parse.quote(path.name)}",
                "public_url": release_download_url(project_url, tag_name, direct_asset_path),
                "link_type": link_type,
                "direct_asset_path": direct_asset_path,
            }
        )
    return assets


def build_description(
    manifest: dict,
    compatibility: dict | None,
    chart_record: dict | None,
    assets: list[dict[str, str]],
    draft_notes: str | None,
) -> str:
    lines = [
        f"# Splunk Operator {manifest['sok']['target_release_version']}",
        "",
        f"- lane: `{manifest['lane']['selected']}`",
        f"- cycle: `{manifest['source']['cycle_id']}`",
        f"- source mode: `{manifest['source']['source_mode']}`",
        f"- release branch: `{manifest['sok']['release_branch'] or 'not-required'}`",
        f"- commit: `{manifest['gitlab']['commit_sha']}`",
        f"- Splunk version: `{manifest['splunk']['version']}`",
        f"- Enterprise image: `{manifest['splunk']['enterprise_image']}`",
    ]
    if compatibility:
        lines.extend(
            [
                "",
                "## Compatibility",
                "",
                f"- disposition: `{compatibility.get('disposition', 'pending')}`",
                f"- reason: {compatibility.get('disposition_reason', 'pending')}",
            ]
        )
    if chart_record:
        oci_refs = chart_record.get("oci_refs", {})
        lines.extend(
            [
                "",
                "## OCI Charts",
                "",
                f"- internal splunk-operator: `{oci_refs.get('splunk_operator', 'unset')}`",
                f"- internal splunk-enterprise: `{oci_refs.get('splunk_enterprise', 'unset')}`",
                f"- official splunk-operator target: `{oci_refs.get('official_splunk_operator', 'unset')}`",
                f"- official splunk-enterprise target: `{oci_refs.get('official_splunk_enterprise', 'unset')}`",
            ]
        )
    if assets:
        lines.extend(["", "## Stable Release Assets", ""])
        for asset in assets:
            lines.append(f"- [{asset['label']}]({asset['public_url']})")
    if draft_notes:
        lines.extend(["", "## Draft Release Notes", "", draft_notes.strip()])
    return "\n".join(lines).strip() + "\n"


def upsert_release(project_id: str, api_url: str, tag_name: str, name: str, ref: str, description: str) -> dict:
    encoded_tag = urllib.parse.quote(tag_name, safe="")
    release_url = f"{api_url}/projects/{project_id}/releases/{encoded_tag}"
    try:
        api_request_json("GET", release_url)
        return api_request_json("PUT", release_url, {"name": name, "description": description})
    except urllib.error.HTTPError as exc:
        if exc.code != 404:
            raise
    return api_request_json(
        "POST",
        f"{api_url}/projects/{project_id}/releases",
        {
            "name": name,
            "tag_name": tag_name,
            "ref": ref,
            "description": description,
        },
    )


def upsert_release_links(project_id: str, api_url: str, tag_name: str, assets: list[dict[str, str]]) -> list[dict]:
    encoded_tag = urllib.parse.quote(tag_name, safe="")
    links_url = f"{api_url}/projects/{project_id}/releases/{encoded_tag}/assets/links"
    existing = api_request_json("GET", links_url)
    by_name = {item["name"]: item for item in existing} if isinstance(existing, list) else {}
    results: list[dict] = []
    for asset in assets:
        payload = {
            "name": asset["label"],
            "url": asset["package_url"],
            "link_type": asset["link_type"],
            "direct_asset_path": asset["direct_asset_path"],
        }
        current = by_name.get(asset["label"])
        if current:
            link_id = current["id"]
            result = api_request_json("PUT", f"{links_url}/{link_id}", payload)
        else:
            result = api_request_json("POST", links_url, payload)
        results.append(result)
    return results


def main() -> int:
    project_dir = Path.cwd()
    controller_dir = project_dir / "rehearsal" / "release-controller"
    controller_dir.mkdir(parents=True, exist_ok=True)

    manifest = load_json(controller_dir / "release-cycle-manifest.json")
    compatibility = load_optional_json(controller_dir / "compatibility-record.json")
    chart_record = load_optional_json(controller_dir / "chart-publication-record.json")
    draft_notes = load_optional_text(project_dir / "rehearsal" / "pre-release-workflow-output" / "draft-release-notes.md")

    api_url = os.getenv("CI_API_V4_URL", "https://cd.splunkdev.com/api/v4")
    project_id = os.environ["CI_PROJECT_ID"]
    project_url = os.getenv("CI_PROJECT_URL", "")
    pipeline_id = os.getenv("CI_PIPELINE_ID", "unknown")
    project_path = os.getenv("CI_PROJECT_PATH", "unknown")
    release_version = manifest["sok"]["target_release_version"]
    rc_version = manifest["sok"]["release_candidate_version"]
    tag_name = release_tag_name(project_path, release_version, rc_version, pipeline_id)
    name = release_name(project_path, release_version, rc_version, pipeline_id)
    package_name = os.getenv("SOK_GITLAB_RELEASE_PACKAGE_NAME", "sok-release-assets")
    package_version = package_version_from_tag(tag_name)
    package_base_url = (
        f"{api_url}/projects/{project_id}/packages/generic/"
        f"{urllib.parse.quote(package_name, safe='')}/"
        f"{urllib.parse.quote(package_version, safe='')}"
    )
    assets = collect_assets(project_dir, controller_dir, package_base_url, project_url, tag_name)
    execute = bool_env("STAGING_EXECUTE_GITLAB_RELEASE_RECORD", default=False)
    description = build_description(manifest, compatibility, chart_record, assets, draft_notes)

    plan = {
        "schema_version": "v1alpha1",
        "execute_release_record": execute,
        "project_path": project_path,
        "tag_name": tag_name,
        "release_name": name,
        "package_name": package_name,
        "package_version": package_version,
        "package_base_url": package_base_url,
        "release_url": f"{project_url}/-/releases/{urllib.parse.quote(tag_name, safe='')}" if project_url else "",
        "assets": assets,
        "release_record_note": "Use Generic Package Registry-backed URLs for stable release assets, then attach them to the GitLab Release record.",
    }
    (controller_dir / "gitlab-release-record-plan.json").write_text(
        json.dumps(plan, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (controller_dir / "gitlab-release-record-plan.md").write_text(
        "\n".join(
            [
                "# GitLab Release Record Plan",
                "",
                f"- execute_release_record: {execute}",
                f"- tag_name: {tag_name}",
                f"- release_name: {name}",
                f"- package_name: {package_name}",
                f"- package_version: {package_version}",
                f"- package_base_url: {package_base_url}",
                "",
                "## Assets",
                *[
                    f"- {asset['label']}: {asset['public_url']}"
                    for asset in assets
                ],
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    result = {
        "schema_version": "v1alpha1",
        "execution_status": "plan-only",
        "tag_name": tag_name,
        "release_url": plan["release_url"],
        "uploaded_assets": [],
        "release_links": [],
    }

    if execute:
        uploaded_assets: list[dict[str, str | int]] = []
        for asset in assets:
            status = api_upload_file(asset["upload_url"], project_dir / asset["path"])
            uploaded_assets.append(
                {
                    "name": asset["label"],
                    "status": status,
                    "package_url": asset["package_url"],
                    "release_asset_url": asset["public_url"],
                }
            )
        release = upsert_release(
            project_id=project_id,
            api_url=api_url,
            tag_name=tag_name,
            name=name,
            ref=manifest["gitlab"]["commit_sha"],
            description=description,
        )
        release_links = upsert_release_links(project_id, api_url, tag_name, assets)
        result.update(
            {
                "execution_status": "executed",
                "uploaded_assets": uploaded_assets,
                "release_links": release_links,
                "release_url": release.get("url")
                or f"{project_url}/-/releases/{urllib.parse.quote(tag_name, safe='')}",
            }
        )

    (controller_dir / "gitlab-release-record-result.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (controller_dir / "gitlab-release-record-result.md").write_text(
        "\n".join(
            [
                "# GitLab Release Record Result",
                "",
                f"- execution_status: {result['execution_status']}",
                f"- tag_name: {tag_name}",
                f"- release_url: {result['release_url'] or 'pending'}",
                "",
                "## Uploaded Assets",
                *[
                    f"- {item['name']}: {item['release_asset_url']} ({item['status']})"
                    for item in result["uploaded_assets"]
                ],
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    print(controller_dir / "gitlab-release-record-plan.md")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, urllib.error.URLError, urllib.error.HTTPError) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
