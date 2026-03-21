#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


def api_headers() -> dict[str, str]:
    private_token = os.getenv("STAGING_GITLAB_API_TOKEN", "").strip()
    if private_token:
        return {"PRIVATE-TOKEN": private_token}
    job_token = os.getenv("CI_JOB_TOKEN", "").strip()
    if job_token:
        return {"JOB-TOKEN": job_token}
    raise RuntimeError("Missing STAGING_GITLAB_API_TOKEN or CI_JOB_TOKEN for GitLab API access")


def api_get_json(url: str) -> list[dict]:
    request = urllib.request.Request(url, headers=api_headers())
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def slack_post(payload: dict) -> dict:
    token = os.environ["STAGING_SLACK_TOKEN"]
    request = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json; charset=utf-8",
        },
        method="POST",
    )
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def choose_channel() -> str:
    if os.getenv("CI_PIPELINE_SOURCE") == "schedule":
        return os.getenv("STAGING_SLACK_SCHEDULE_CHANNEL", os.environ["STAGING_SLACK_CHANNEL"])
    return os.environ["STAGING_SLACK_CHANNEL"]


def gather_failed_jobs() -> list[dict]:
    project_id = os.environ["CI_PROJECT_ID"]
    pipeline_id = os.environ["CI_PIPELINE_ID"]
    api_url = os.getenv("CI_API_V4_URL", "https://cd.splunkdev.com/api/v4")
    jobs = api_get_json(f"{api_url}/projects/{project_id}/pipelines/{pipeline_id}/jobs?per_page=100")
    return [
        {
            "id": job["id"],
            "name": job["name"],
            "status": job["status"],
            "stage": job["stage"],
            "web_url": job["web_url"],
        }
        for job in jobs
        if job.get("status") == "failed" and not job.get("allow_failure", False)
    ]


def build_payload(channel: str, failed_jobs: list[dict]) -> dict:
    project = os.getenv("CI_PROJECT_PATH", "unknown-project")
    pipeline_url = os.getenv("CI_PIPELINE_URL", "unknown")
    ref_name = os.getenv("CI_COMMIT_REF_NAME", "unknown")
    pipeline_mode = os.getenv("REHEARSAL_PIPELINE_MODE", "full")
    source = os.getenv("CI_PIPELINE_SOURCE", "unknown")
    sha = os.getenv("CI_COMMIT_SHA", "unknown")[:8]

    status_label = "FAILED" if failed_jobs else "SUCCESS"
    intro = (
        f"*SOK GitLab rehearsal notification*\n"
        f"- Project: `{project}`\n"
        f"- Ref: `{ref_name}` `{sha}`\n"
        f"- Source: `{source}`\n"
        f"- Mode: `{pipeline_mode}`\n"
        f"- Pipeline: {pipeline_url}\n"
        f"- Status: *{status_label}*"
    )

    blocks: list[dict] = [
        {"type": "section", "text": {"type": "mrkdwn", "text": intro}},
    ]

    if failed_jobs:
        failed_lines = "\n".join(
            f"- `{job['stage']}/{job['name']}`: <{job['web_url']}|job {job['id']}>"
            for job in failed_jobs[:15]
        )
        blocks.append(
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": f"*Failed jobs*\n{failed_lines}",
                },
            }
        )
    else:
        blocks.append(
            {
                "type": "section",
                "text": {"type": "mrkdwn", "text": "No failed non-allow-failure jobs were detected when the notification ran."},
            }
        )

    return {"channel": channel, "blocks": blocks}


def main() -> int:
    work_slug = os.getenv("WORKFLOW_SLUG", "slack-notify")
    rehearsal_dir = Path("rehearsal")
    rehearsal_dir.mkdir(exist_ok=True)

    payload_file = rehearsal_dir / f"{work_slug}-payload.json"
    summary_file = rehearsal_dir / f"{work_slug}-summary.txt"
    failures_file = rehearsal_dir / f"{work_slug}-failed-jobs.json"

    failed_jobs = gather_failed_jobs()
    channel = choose_channel()
    payload = build_payload(channel, failed_jobs)

    payload_file.write_text(json.dumps(payload, indent=2))
    failures_file.write_text(json.dumps(failed_jobs, indent=2))
    summary_file.write_text(
        "\n".join(
            [
                f"channel={channel}",
                f"failed_job_count={len(failed_jobs)}",
                f"pipeline_source={os.getenv('CI_PIPELINE_SOURCE', 'unknown')}",
                f"pipeline_mode={os.getenv('REHEARSAL_PIPELINE_MODE', 'full')}",
            ]
        )
        + "\n"
    )

    result = slack_post(payload)
    summary_file.write_text(summary_file.read_text() + f"slack_ok={result.get('ok', False)}\n")
    if not result.get("ok", False):
        raise RuntimeError(f"Slack post failed: {result}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, urllib.error.URLError) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
