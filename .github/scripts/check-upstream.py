#!/usr/bin/env python3
"""Check upstream releases and create an issue when a newer version exists.

Runs on a schedule in GitHub Actions.  Reads `.github/upstreams.json` for the
per-addon upstream definitions and compares each upstream version with the
`version` field in `<addon>/config.yaml` (format: `<upstream>.<addon-revision>`).
Creates one issue per addon when the upstream has moved on.

Issue dedupe: an open issue labelled `upstream-update` whose title starts with
`[upstream] <addon>:` suppresses a new issue for that addon.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
MANIFEST = REPO_ROOT / ".github" / "upstreams.json"
LABEL = "upstream-update"
ISSUE_TITLE_PREFIX = "[upstream]"

TOKEN = os.environ.get("GITHUB_TOKEN", "")
GITHUB_REPOSITORY = os.environ.get("GITHUB_REPOSITORY", "Khronos31/hassio-addons")
GITHUB_API = os.environ.get("GITHUB_API_URL", "https://api.github.com")

JST = timezone(timedelta(hours=9))


def api(path: str) -> dict | list:
    url = f"{GITHUB_API}{path}"
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    if TOKEN:
        req.add_header("Authorization", f"Bearer {TOKEN}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def current_upstream(addon: str, parts: int) -> tuple[int, ...]:
    config = REPO_ROOT / addon / "config.yaml"
    text = config.read_text(encoding="utf-8")
    match = re.search(r'^version:\s*"([^"]+)"', text, flags=re.MULTILINE)
    if not match:
        raise RuntimeError(f"{addon}/config.yaml: version not found")
    version = match.group(1)
    nums = tuple(int(n) for n in re.findall(r"\d+", version))
    if len(nums) < parts:
        raise RuntimeError(f"{addon}: version {version!r} has fewer than {parts} parts")
    return nums[:parts]


def latest_upstream(entry: dict) -> str:
    repo = entry["repo"]
    source = entry["source"]
    if source == "release":
        data = api(f"/repos/{repo}/releases/latest")
        tag = str(data.get("tag_name", ""))
    elif source == "tag":
        data = api(f"/repos/{repo}/tags?per_page=1")
        tag = str(data[0]["name"])
    elif source == "branch":
        branch = entry["branch"]
        data = api(f"/repos/{repo}/branches/{branch}")
        sha = str(data["commit"]["sha"])
        commit = api(f"/repos/{repo}/commits/{sha}")
        iso = str(commit["commit"]["committer"]["date"])
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(JST)
        return dt.strftime("%y%m%d")
    else:
        raise RuntimeError(f"unknown source: {source}")

    strip = entry.get("strip", "")
    if strip and tag.startswith(strip):
        tag = tag[len(strip):]
    return tag


def version_tuple(version: str) -> tuple[int, ...]:
    nums = tuple(int(n) for n in re.findall(r"\d+", version))
    if not nums:
        raise RuntimeError(f"version {version!r} has no numeric parts")
    return nums


def find_open_issue(addon: str) -> bool:
    data = api(f"/repos/{GITHUB_REPOSITORY}/issues?labels={LABEL}&state=open&per_page=100")
    prefix = f"{ISSUE_TITLE_PREFIX} {addon}:"
    return any(str(issue.get("title", "")).startswith(prefix) for issue in data)


def create_issue(addon: str, repo: str, current: str, latest: str) -> None:
    title = f"{ISSUE_TITLE_PREFIX} {addon}: {repo} {latest}"
    body = (
        f"上流 {repo} が {latest} をリリースしました。\n\n"
        f"- 現在の同梱: {current}\n"
        f"- 新しい同梱: {latest}\n\n"
        "対応: Dockerfile の同梱バージョンを更新し、"
        "`<addon>/config.yaml` の `version` を `<上流>.<改訂>` 形式で更新してください。\n"
        "コード変更が必要な場合は別途検討してください。"
    )
    payload = json.dumps({"title": title, "body": body, "labels": [LABEL]}).encode("utf-8")
    req = urllib.request.Request(
        f"{GITHUB_API}/repos/{GITHUB_REPOSITORY}/issues",
        data=payload,
        method="POST",
        headers={
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "Authorization": f"Bearer {TOKEN}",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        issue = json.loads(resp.read().decode("utf-8"))
    print(f"created issue #{issue['number']}: {title}")


def main() -> int:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    failed = False
    for addon, entry in manifest.items():
        try:
            parts = int(entry["parts"])
            current = current_upstream(addon, parts)
            latest_str = latest_upstream(entry)
            latest = version_tuple(latest_str)
            print(f"{addon}: current={'.'.join(map(str, current))} latest={latest_str}")
            if latest > current:
                if find_open_issue(addon):
                    print(f"{addon}: open issue already exists, skip")
                    continue
                create_issue(addon, entry["repo"], ".".join(map(str, current)), latest_str)
        except urllib.error.HTTPError as exc:
            print(f"{addon}: HTTP {exc.code} {exc.reason}", file=sys.stderr)
            failed = True
        except Exception as exc:  # noqa: BLE001 - keep the workflow going
            print(f"{addon}: {exc}", file=sys.stderr)
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
