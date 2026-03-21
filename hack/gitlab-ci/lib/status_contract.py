from __future__ import annotations

import json
from pathlib import Path
from typing import Any


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


def load_optional_json(path: Path) -> dict[str, Any] | list[Any] | None:
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def load_optional_text(path: Path) -> str | None:
    if not path.exists():
        return None
    return path.read_text(encoding="utf-8")
