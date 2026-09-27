#!/usr/bin/env python3
"""Compare bundled upstream versions with upstream releases; open Issues when newer.

The layout differs from Mayflower (addons instead of packages), but the logic
follows tools/upstream-watch/check.py in Khronos31/Mayflower:

* gather only non-draft, non-prerelease releases/tags and take the max version
* skip prerelease-looking tags (rc / alpha / beta / preview / pre / dev)
* dedupe Issues by an HTML marker stored in the Issue body
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
MANIFEST = ROOT / ".github" / "upstreams.json"
LABEL = "upstream-update"
REPO = "Khronos31/hassio-addons"
MARKER_TMPL = "<!-- upstream-check:addon={addon}:ver={ver} -->"
JST = timezone(timedelta(hours=9))


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True, check=False)


def is_prerelease(ver: str) -> bool:
    return bool(
        re.search(r"(?i)(?:rc|alpha|beta|preview|pre|dev)\d*", ver)
        or re.search(r"(?i)\d(?:a|b)\d+$", ver)
    )


def parse_version_parts(v: str) -> tuple:
    v = v.strip().lstrip("v")
    parts = re.split(r"[.\-+_]", v)
    out = []
    for part in parts:
        if part.isdigit():
            out.append((0, int(part)))
            continue
        match = re.match(r"(\d+)([A-Za-z].*)?$", part)
        if match:
            out.append((0, int(match.group(1))))
            if match.group(2):
                out.append((1, match.group(2)))
        else:
            out.append((1, part))
    return tuple(out)


def name_to_ver(name: str, strip: str) -> str | None:
    ver = name.strip()
    if strip and ver.startswith(strip):
        ver = ver[len(strip):]
    if is_prerelease(ver):
        return None
    # Must look like a version (reject debug_release / wincolor-0.1.6 etc.)
    if not re.fullmatch(r"\d+(?:\.\d+)+(?:[A-Za-z]+\d*)?", ver):
        return None
    return ver


def latest_upstream(entry: dict) -> str | None:
    repo = entry["repo"]
    source = entry["source"]
    candidates: list[str] = []

    if source == "release":
        cp = run([
            "gh", "api", f"repos/{repo}/releases?per_page=40", "--jq",
            ".[] | select(.draft==false and .prerelease==false) | .tag_name",
        ])
        if cp.returncode == 0:
            for name in cp.stdout.splitlines():
                ver = name_to_ver(name, entry.get("strip", "v"))
                if ver:
                    candidates.append(ver)
    elif source == "tag":
        cp = run(["gh", "api", f"repos/{repo}/tags?per_page=100", "--jq", ".[].name"])
        if cp.returncode == 0:
            for name in cp.stdout.splitlines():
                ver = name_to_ver(name, entry.get("strip", ""))
                if ver:
                    candidates.append(ver)
    elif source == "branch":
        branch = entry["branch"]
        cp = run(["gh", "api", f"repos/{repo}/branches/{branch}", "--jq", ".commit.sha"])
        sha = cp.stdout.strip()
        if cp.returncode != 0 or not sha:
            return None
        cp = run(["gh", "api", f"repos/{repo}/commits/{sha}", "--jq", ".commit.committer.date"])
        iso = cp.stdout.strip()
        if cp.returncode != 0 or not iso:
            return None
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(JST)
        return dt.strftime("%y%m%d")
    else:
        print(f"unknown source: {source}", file=sys.stderr)
        return None

    if not candidates:
        print(f"warn: {repo}: no matching stable release/tag", file=sys.stderr)
        return None
    return max(candidates, key=parse_version_parts)


def current_upstream(addon: str, parts: int) -> str:
    config = ROOT / addon / "config.yaml"
    match = re.search(
        r'^version:\s*"([^"]+)"', config.read_text(encoding="utf-8"), flags=re.MULTILINE
    )
    if not match:
        raise RuntimeError(f"{addon}/config.yaml: version not found")
    version = match.group(1)
    nums = re.findall(r"\d+", version)
    if len(nums) < parts:
        raise RuntimeError(f"{addon}: version {version!r} has fewer than {parts} parts")
    return ".".join(nums[:parts])


def is_newer(upstream: str, current: str) -> bool:
    try:
        return parse_version_parts(upstream) > parse_version_parts(current)
    except Exception:
        return upstream != current


def find_existing_issue(addon: str, ver: str) -> int | None:
    marker = MARKER_TMPL.format(addon=addon, ver=ver)
    cp = run([
        "gh", "issue", "list", "--repo", REPO, "--state", "all",
        "--search", f"upstream-check {addon} in:body",
        "--json", "number,title,body", "--limit", "50",
    ])
    if cp.returncode != 0:
        print(f"warn: issue list failed: {cp.stderr.strip()}", file=sys.stderr)
        return None
    for issue in json.loads(cp.stdout or "[]"):
        if marker in (issue.get("body") or ""):
            return issue["number"]
    return None


def create_issue(addon: str, repo: str, current: str, latest: str) -> None:
    title = f"[upstream] {addon}: {repo} {latest}"
    marker = MARKER_TMPL.format(addon=addon, ver=latest)
    body = (
        f"上流 {repo} が {latest} をリリースしました。\n\n"
        f"- 現在の同梱: {current}\n"
        f"- 新しい同梱: {latest}\n\n"
        "対応: Dockerfile の同梱バージョンを更新し、"
        "`<addon>/config.yaml` の `version` を `<上流>.<改訂>` 形式で更新してください。\n"
        "コード変更が必要な場合は別途検討してください。\n\n"
        f"{marker}"
    )
    cp = run([
        "gh", "issue", "create", "--repo", REPO,
        "--title", title, "--body", body, "--label", LABEL,
    ])
    if cp.returncode != 0:
        print(f"warn: issue create failed: {cp.stderr.strip()}", file=sys.stderr)
        return
    print(f"created issue: {cp.stdout.strip()}")


def main() -> int:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    failed = False
    for addon, entry in manifest.items():
        try:
            parts = int(entry["parts"])
            current = current_upstream(addon, parts)
            latest = latest_upstream(entry)
            if latest is None:
                failed = True
                continue
            print(f"{addon}: current={current} latest={latest}")
            if is_newer(latest, current):
                if find_existing_issue(addon, latest) is not None:
                    print(f"{addon}: issue for {latest} already exists, skip")
                    continue
                create_issue(addon, entry["repo"], current, latest)
        except Exception as exc:  # noqa: BLE001 - keep the workflow going
            print(f"{addon}: {exc}", file=sys.stderr)
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
