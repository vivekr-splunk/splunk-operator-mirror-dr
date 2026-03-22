#!/usr/bin/env python3
from __future__ import annotations

import html
import json
import os
import shutil
from pathlib import Path

from lib.status_contract import build_pages_cycle_prefix, load_job_artifacts, load_optional_json, load_optional_text


RAW_FILES = [
    "release-cycle-manifest.json",
    "release-cycle-summary.md",
    "release-cycle.env",
    "lane-selection.json",
    "lane-selection.md",
    "qualification-manifest.json",
    "qualification-report.md",
    "compatibility-record.json",
    "compatibility-decision.json",
    "compatibility-publish-plan.json",
    "compatibility-publish-plan.md",
    "blocker-summary.json",
    "psr-qualification-verdict.json",
    "psr-qualification-verdict.md",
]


def infer_status_label(
    selected_lane: str,
    compatibility: dict | None,
    failed_jobs: list[dict[str, str]],
) -> str:
    if failed_jobs:
        return "blocked"
    if compatibility:
        disposition = compatibility.get("disposition", "in progress")
        if disposition == "qualified with current SOK":
            return "qualified"
        if disposition == "qualified with caveats":
            return "qualified-with-caveats"
        if disposition == "new SOK release required":
            return "release-required"
        return disposition
    if selected_lane == "product-release":
        return "product-release-in-progress"
    return "qualification-in-progress"


def copy_raw_files(controller_dir: Path, raw_dir: Path) -> list[str]:
    raw_dir.mkdir(parents=True, exist_ok=True)
    copied: list[str] = []
    for file_name in RAW_FILES:
        source = controller_dir / file_name
        if source.exists():
            shutil.copy2(source, raw_dir / file_name)
            copied.append(file_name)
    return copied


def build_summary(rehearsal_dir: Path, controller_dir: Path) -> dict[str, object]:
    manifest = json.loads((controller_dir / "release-cycle-manifest.json").read_text(encoding="utf-8"))
    lane_selection = json.loads((controller_dir / "lane-selection.json").read_text(encoding="utf-8"))
    compatibility = load_optional_json(controller_dir / "compatibility-record.json")
    publish_plan = load_optional_json(controller_dir / "compatibility-publish-plan.json")
    blocker_summary = load_optional_json(controller_dir / "blocker-summary.json")
    psr_verdict = load_optional_json(controller_dir / "psr-qualification-verdict.json")
    qualification_report = load_optional_text(controller_dir / "qualification-report.md")

    jobs = load_job_artifacts(rehearsal_dir)
    failed_jobs = [job for job in jobs if job["mode"] in {"blocked-missing-vars"}]

    summary = {
        "schema_version": "v1alpha1",
        "generated_at_utc": manifest["generated_at_utc"],
        "project": os.getenv("CI_PROJECT_PATH", "unknown-project"),
        "pipeline": {
            "id": os.getenv("CI_PIPELINE_ID", "unknown"),
            "url": os.getenv("CI_PIPELINE_URL", "unknown"),
            "source": os.getenv("CI_PIPELINE_SOURCE", "unknown"),
            "mode": os.getenv("REHEARSAL_PIPELINE_MODE", "full"),
            "ref_name": os.getenv("CI_COMMIT_REF_NAME", "unknown"),
            "commit_sha": os.getenv("CI_COMMIT_SHA", "unknown"),
        },
        "cycle": {
            "id": manifest["source"]["cycle_id"],
            "file": manifest["source"]["cycle_file"],
            "file_source": manifest["source"]["cycle_file_source"],
            "planned_start_date": manifest["source"]["planned_start_date"],
            "branch_cut_date": manifest["source"]["branch_cut_date"],
            "linked_splrel": manifest["governance"]["linked_splrel"],
            "linked_rdmp": manifest["governance"]["linked_rdmp"],
            "owner": manifest["governance"]["cycle_owner"],
        },
        "lane": {
            "selected": lane_selection["selected_lane"],
            "selection_reason": lane_selection["selection_reason"],
            "release_required": lane_selection["release_required"],
            "approval_gate": lane_selection["approval_gate"],
        },
        "splunk": manifest["splunk"],
        "sok": manifest["sok"],
        "qualification": manifest["qualification"],
        "status": {
            "label": infer_status_label(lane_selection["selected_lane"], compatibility if isinstance(compatibility, dict) else None, failed_jobs),
            "disposition": compatibility.get("disposition", "in progress") if isinstance(compatibility, dict) else "in progress",
            "disposition_reason": compatibility.get("disposition_reason", "qualification-report pending")
            if isinstance(compatibility, dict)
            else "qualification-report pending",
            "next_action": publish_plan.get("next_action", "await-controller-output") if isinstance(publish_plan, dict) else "await-controller-output",
        },
        "jobs": jobs,
        "evidence": {
            "executed_jobs": compatibility.get("executed_jobs", []) if isinstance(compatibility, dict) else [],
            "plan_only_jobs": compatibility.get("plan_only_jobs", []) if isinstance(compatibility, dict) else [],
            "blocked_jobs": compatibility.get("blocked_jobs", []) if isinstance(compatibility, dict) else [],
            "missing_jobs": compatibility.get("missing_jobs", []) if isinstance(compatibility, dict) else [],
        },
        "blockers": blocker_summary if isinstance(blocker_summary, dict) else None,
        "psr_verdict": psr_verdict if isinstance(psr_verdict, dict) else None,
        "raw_files": [],
        "qualification_report_excerpt": (
            "\n".join(qualification_report.splitlines()[:24]) if qualification_report else None
        ),
    }
    return summary


def write_json(path: Path, payload: dict[str, object]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_text(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def derive_root_pages_url(cycle_url: str, cycle_prefix: str) -> str:
    if not cycle_url:
        return ""
    suffix = f"/{cycle_prefix}/"
    if cycle_url.endswith(suffix):
        return cycle_url[: -len(suffix)] or "/"
    suffix_no_trailing = f"/{cycle_prefix}"
    if cycle_url.endswith(suffix_no_trailing):
        return cycle_url[: -len(suffix_no_trailing)] or "/"
    return cycle_url


def render_list(items: list[str]) -> str:
    if not items:
        return "<li>none</li>"
    return "\n".join(f"<li><code>{html.escape(item)}</code></li>" for item in items)


def render_jobs_table(jobs: list[dict[str, str]]) -> str:
    if not jobs:
        return ""
    rows = []
    for job in sorted(jobs, key=lambda item: item["slug"]):
        rows.append(
            "<tr>"
            f"<td><code>{html.escape(job['slug'])}</code></td>"
            f"<td>{html.escape(job['mode'])}</td>"
            f"<td><pre>{html.escape(job['status'])}</pre></td>"
            "</tr>"
        )
    return (
        "<table><thead><tr><th>Workflow</th><th>Mode</th><th>Status Summary</th></tr></thead><tbody>"
        + "".join(rows)
        + "</tbody></table>"
    )


def render_evidence_section(evidence: dict[str, list[str]]) -> str:
    return "\n".join(
        [
            "<div class=\"grid\">",
            f"<div class=\"card\"><div class=\"label\">Executed Jobs</div><div class=\"value\"><ul>{render_list(evidence.get('executed_jobs', []))}</ul></div></div>",
            f"<div class=\"card\"><div class=\"label\">Plan Only Jobs</div><div class=\"value\"><ul>{render_list(evidence.get('plan_only_jobs', []))}</ul></div></div>",
            f"<div class=\"card\"><div class=\"label\">Blocked Jobs</div><div class=\"value\"><ul>{render_list(evidence.get('blocked_jobs', []))}</ul></div></div>",
            f"<div class=\"card\"><div class=\"label\">Missing Jobs</div><div class=\"value\"><ul>{render_list(evidence.get('missing_jobs', []))}</ul></div></div>",
            "</div>",
        ]
    )


def render_markdown(summary: dict[str, object]) -> str:
    cycle = summary["cycle"]
    lane = summary["lane"]
    splunk = summary["splunk"]
    sok = summary["sok"]
    status = summary["status"]
    pipeline = summary["pipeline"]
    pages = summary.get("pages", {})
    blockers = summary.get("blockers") or {}
    blocker_counts = blockers.get("bucket_counts", {}) if isinstance(blockers, dict) else {}
    psr_verdict = summary.get("psr_verdict") or {}

    lines = [
        "# SOK Release And Qualification Status",
        "",
        f"- label: `{status['label']}`",
        f"- lane: `{lane['selected']}`",
        f"- cycle: `{cycle['id']}`",
        f"- disposition: `{status['disposition']}`",
        f"- next action: `{status['next_action']}`",
        f"- pipeline: [{pipeline['id']}]({pipeline['url']})",
        f"- ref: `{pipeline['ref_name']}`",
        f"- commit: `{str(pipeline['commit_sha'])[:12]}`",
        f"- Splunk version: `{splunk['version']}`",
        f"- SOK baseline: `{sok['baseline_version']}`",
        f"- target release: `{sok['target_release_version']}`",
        f"- release candidate: `{sok['release_candidate_version']}`",
        "",
        "## Pages",
        "",
        f"- variant: `{pages.get('variant', 'unknown')}`",
        f"- current dashboard: {pages.get('current_url', 'unavailable')}",
        f"- cycle page: {pages.get('cycle_url', 'unavailable')}",
        f"- cycle prefix: `{pages.get('cycle_prefix', 'unknown')}`",
        "",
        "## Blockers",
        "",
        f"- infra: `{blocker_counts.get('infra', 0)}`",
        f"- test: `{blocker_counts.get('test', 0)}`",
        f"- sok: `{blocker_counts.get('sok', 0)}`",
        f"- splunk: `{blocker_counts.get('splunk', 0)}`",
        f"- disposition reason: {status['disposition_reason']}",
        "",
        "## PSR",
        "",
        f"- verdict: `{psr_verdict.get('verdict', 'none')}`",
        f"- pipeline: {psr_verdict.get('downstream_pipeline_url', 'unavailable')}",
    ]
    return "\n".join(lines) + "\n"


def write_html(path: Path, summary: dict[str, object]) -> None:
    cycle = summary["cycle"]
    lane = summary["lane"]
    splunk = summary["splunk"]
    sok = summary["sok"]
    status = summary["status"]
    pipeline = summary["pipeline"]
    pages = summary.get("pages", {})
    blockers = summary.get("blockers") or {}
    blocker_counts = blockers.get("bucket_counts", {}) if isinstance(blockers, dict) else {}
    psr_verdict = summary.get("psr_verdict") or {}
    raw_files = summary["raw_files"]
    evidence = summary.get("evidence", {})
    psr_pipeline_link = (
        f'<a href="{html.escape(str(psr_verdict.get("downstream_pipeline_url")))}">downstream</a>'
        if psr_verdict.get("downstream_pipeline_url")
        else "unavailable"
    )
    raw_files_markup = "\n".join(
        f'<li><a href="{html.escape("data/" + item)}"><code>{html.escape("data/" + item)}</code></a></li>' for item in raw_files
    ) or "<li>none</li>"
    current_dashboard_link = (
        f'<a href="{html.escape(str(pages.get("current_url")))}">{html.escape(str(pages.get("current_url")))}</a>'
        if pages.get("current_url")
        else "unavailable"
    )
    cycle_dashboard_link = (
        f'<a href="{html.escape(str(pages.get("cycle_url")))}">{html.escape(str(pages.get("cycle_url")))}</a>'
        if pages.get("cycle_url")
        else "unavailable"
    )
    pages_description = (
        "This root deployment always shows the latest successful release or qualification cycle."
        if pages.get("variant") == "current"
        else "This deployment preserves one specific release or qualification cycle at a stable path."
    )

    html_text = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SOK Release And Qualification Status</title>
  <style>
    :root {{
      --bg: #f4f1ea;
      --ink: #1f2430;
      --muted: #5f6a7d;
      --card: #fffdf8;
      --line: #d8d1c2;
      --accent: #0a6e6e;
    }}
    body {{ font-family: Georgia, 'Times New Roman', serif; background: var(--bg); color: var(--ink); margin: 0; }}
    main {{ max-width: 1100px; margin: 0 auto; padding: 32px 24px 60px; }}
    h1, h2 {{ margin: 0 0 12px; }}
    p, li {{ line-height: 1.5; }}
    .hero {{ margin-bottom: 28px; }}
    .eyebrow {{ color: var(--accent); text-transform: uppercase; letter-spacing: .08em; font-size: 12px; margin-bottom: 10px; }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 14px; margin: 20px 0 28px; }}
    .card {{ background: var(--card); border: 1px solid var(--line); padding: 16px; border-radius: 12px; }}
    .label {{ color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .06em; }}
    .value {{ margin-top: 8px; font-size: 18px; }}
    code {{ font-family: 'SFMono-Regular', Menlo, monospace; font-size: 0.95em; }}
    pre {{ white-space: pre-wrap; word-break: break-word; margin: 0; font-family: 'SFMono-Regular', Menlo, monospace; font-size: 12px; }}
    section {{ margin-top: 28px; }}
    table {{ width: 100%; border-collapse: collapse; background: var(--card); border: 1px solid var(--line); }}
    th, td {{ text-align: left; vertical-align: top; padding: 10px 12px; border-bottom: 1px solid var(--line); }}
    th {{ background: #efe9db; }}
    a {{ color: var(--accent); }}
  </style>
</head>
<body>
<main>
  <div class="hero">
    <div class="eyebrow">SOK Release And Qualification Status</div>
    <h1>{html.escape(str(status['label']))}</h1>
    <p>This page is generated automatically from the GitLab controller outputs in <code>sok/splunk-operator</code>. {html.escape(pages_description)}</p>
  </div>

  <div class="grid">
    <div class="card"><div class="label">Cycle</div><div class="value"><code>{html.escape(str(cycle['id']))}</code></div></div>
    <div class="card"><div class="label">Lane</div><div class="value">{html.escape(str(lane['selected']))}</div></div>
    <div class="card"><div class="label">Disposition</div><div class="value">{html.escape(str(status['disposition']))}</div></div>
    <div class="card"><div class="label">Next Action</div><div class="value">{html.escape(str(status['next_action']))}</div></div>
    <div class="card"><div class="label">Splunk Version</div><div class="value">{html.escape(str(splunk['version']))}</div></div>
    <div class="card"><div class="label">SOK Baseline</div><div class="value">{html.escape(str(sok['baseline_version']))}</div></div>
  </div>

  <section>
    <h2>Pipeline Context</h2>
    <ul>
      <li>Project: <code>{html.escape(str(summary['project']))}</code></li>
      <li>Pipeline: <a href="{html.escape(str(pipeline['url']))}">{html.escape(str(pipeline['id']))}</a></li>
      <li>Source: <code>{html.escape(str(pipeline['source']))}</code></li>
      <li>Mode: <code>{html.escape(str(pipeline['mode']))}</code></li>
      <li>Ref: <code>{html.escape(str(pipeline['ref_name']))}</code></li>
      <li>Commit: <code>{html.escape(str(pipeline['commit_sha'])[:12])}</code></li>
      <li>Generated At: <code>{html.escape(str(summary['generated_at_utc']))}</code></li>
    </ul>
  </section>

  <section>
    <h2>Pages Links</h2>
    <ul>
      <li>Current dashboard: {current_dashboard_link}</li>
      <li>Cycle page: {cycle_dashboard_link}</li>
      <li>Cycle prefix: <code>{html.escape(str(pages.get('cycle_prefix', 'unknown')))}</code></li>
    </ul>
  </section>

  <section>
    <h2>Cycle Inputs</h2>
    <ul>
      <li>Cycle file: <code>{html.escape(str(cycle['file']))}</code> ({html.escape(str(cycle['file_source']))})</li>
      <li>Planned start: <code>{html.escape(str(cycle['planned_start_date']))}</code></li>
      <li>Branch cut date: <code>{html.escape(str(cycle['branch_cut_date']))}</code></li>
      <li>Cycle owner: <code>{html.escape(str(cycle['owner']))}</code></li>
      <li>Linked SPLREL: <code>{html.escape(str(cycle['linked_splrel']))}</code></li>
      <li>Linked RDMP: <code>{html.escape(str(cycle['linked_rdmp']))}</code></li>
      <li>Splunk branch: <code>{html.escape(str(splunk['branch']))}</code></li>
      <li>Enterprise image: <code>{html.escape(str(splunk['enterprise_image']))}</code></li>
      <li>Enterprise image source: <code>{html.escape(str(splunk['enterprise_image_source']))}</code></li>
      <li>Target release version: <code>{html.escape(str(sok['target_release_version']))}</code></li>
      <li>Release candidate: <code>{html.escape(str(sok['release_candidate_version']))}</code></li>
      <li>Release branch: <code>{html.escape(str(sok['release_branch'] or 'not-required'))}</code></li>
    </ul>
  </section>

  <section>
    <h2>Blockers And PSR</h2>
    <ul>
      <li>Disposition reason: {html.escape(str(status['disposition_reason']))}</li>
      <li>Infra blockers: <code>{html.escape(str(blocker_counts.get('infra', 0)))}</code></li>
      <li>Test blockers: <code>{html.escape(str(blocker_counts.get('test', 0)))}</code></li>
      <li>SOK blockers: <code>{html.escape(str(blocker_counts.get('sok', 0)))}</code></li>
      <li>Splunk blockers: <code>{html.escape(str(blocker_counts.get('splunk', 0)))}</code></li>
      <li>PSR verdict: <code>{html.escape(str(psr_verdict.get('verdict', 'none')))}</code></li>
      <li>PSR pipeline: {psr_pipeline_link}</li>
    </ul>
  </section>

  <section>
    <h2>Workflow Evidence</h2>
    {render_evidence_section(evidence)}
    {render_jobs_table(summary['jobs'])}
  </section>

  <section>
    <h2>Raw Controller Files</h2>
    <ul>
      {raw_files_markup}
    </ul>
  </section>
</main>
</body>
</html>
"""
    path.write_text(html_text, encoding="utf-8")


def main() -> int:
    project_dir = Path.cwd()
    rehearsal_dir = project_dir / "rehearsal"
    controller_dir = rehearsal_dir / "release-controller"
    public_dir = project_dir / "public"
    raw_dir = public_dir / "data"
    public_dir.mkdir(parents=True, exist_ok=True)

    summary = build_summary(rehearsal_dir, controller_dir)
    raw_files = copy_raw_files(controller_dir, raw_dir)
    summary["raw_files"] = raw_files
    pipeline_mode = os.getenv("REHEARSAL_PIPELINE_MODE", "full")
    pipeline_id = os.getenv("CI_PIPELINE_ID", "unknown")
    pages_variant = os.getenv("SOK_PAGES_VARIANT", "current")
    cycle_prefix = build_pages_cycle_prefix(pipeline_mode, pipeline_id)
    if pages_variant == "current":
        current_url = os.getenv("CI_PAGES_URL", os.getenv("SOK_PAGES_ROOT_URL", ""))
        cycle_url = f"{current_url.rstrip('/')}/{cycle_prefix}/" if current_url else ""
    else:
        cycle_url = os.getenv("CI_PAGES_URL", "")
        current_url = os.getenv("SOK_PAGES_ROOT_URL", "") or derive_root_pages_url(cycle_url, cycle_prefix)
    summary["pages"] = {
        "variant": pages_variant,
        "cycle_prefix": cycle_prefix,
        "current_url": current_url,
        "cycle_url": cycle_url,
    }

    write_json(public_dir / "status.json", summary)
    write_text(public_dir / "status.md", render_markdown(summary))
    write_html(public_dir / "index.html", summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
