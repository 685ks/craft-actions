#!/usr/bin/env python3
"""Writes update-feed.json: what an app needs to update itself from a release.

    update_feed.py DIR --app-id ID --display-name NAME --version V --tag vV --repository OWNER/REPO
                   [--prerelease true|false] [--date ISO8601]

The feed lists every package in DIR (by the asset name grammar in asset_names.py), grouped by
platform token, with its size and SHA-256. Apps fetch
    https://github.com/OWNER/REPO/releases/latest/download/update-feed.json
(which always serves the newest stable release), compare "version" with their own, pick the entry
for their platform and package kind, download "url" and check "sha256" before installing. The feed
is itself listed in SHA256SUMS.txt, so a signed checksum list covers it.

Schema (version 1):
{
  "schema": 1,
  "id": "photocraft",
  "name": "PhotoCraft",
  "version": "0.5.0",
  "tag": "v0.5.0",
  "prerelease": false,
  "date": "2026-10-20T12:00:00Z",
  "release_url": "https://github.com/OWNER/REPO/releases/tag/v0.5.0",
  "checksums_url": ".../SHA256SUMS.txt",
  "signature_url": ".../SHA256SUMS.txt.minisig" or null,
  "platforms": {
    "windows-x64": [{"kind": "msi", "name": "...", "size": 123, "sha256": "...", "url": "..."}, ...],
    ...
  }
}

Python 3.8+, standard library only.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import sys
from pathlib import Path
from urllib.parse import quote

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asset_names  # noqa: E402


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def build(directory: Path, app_id: str, name: str, version: str, tag: str, repository: str, prerelease: bool,
          date: str, signed: bool) -> dict:
    base = f"https://github.com/{repository}/releases/download/{quote(tag)}/"
    platforms: dict[str, list[dict]] = {}
    for path in sorted(p for p in directory.iterdir() if p.is_file()):
        parsed = asset_names.parse(path.name, [app_id])
        if parsed is None:
            continue
        platforms.setdefault(parsed.token, []).append(
            {
                "kind": parsed.kind,
                "name": path.name,
                "size": path.stat().st_size,
                "sha256": sha256(path),
                "url": base + quote(path.name),
            }
        )
    return {
        "schema": 1,
        "id": app_id,
        "name": name,
        "version": version,
        "tag": tag,
        "prerelease": prerelease,
        "date": date,
        "release_url": f"https://github.com/{repository}/releases/tag/{quote(tag)}",
        "checksums_url": base + "SHA256SUMS.txt",
        "signature_url": base + "SHA256SUMS.txt.minisig" if signed else None,
        "platforms": dict(sorted(platforms.items())),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir", type=Path)
    ap.add_argument("--app-id", required=True)
    ap.add_argument("--display-name", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--repository", required=True)
    ap.add_argument("--prerelease", default="false")
    ap.add_argument("--signed", default="false", help="whether SHA256SUMS.txt.minisig will be published")
    ap.add_argument("--date", default=None, help="ISO 8601 UTC time (default: now)")
    args = ap.parse_args()

    date = args.date or dt.datetime.now(dt.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")
    feed = build(args.dir, args.app_id, args.display_name, args.version, args.tag, args.repository,
                 args.prerelease == "true", date, args.signed == "true")
    if not feed["platforms"]:
        print("::error::no packages to list in update-feed.json")
        return 1
    out = args.dir / "update-feed.json"
    out.write_text(json.dumps(feed, indent=2) + "\n", encoding="utf-8")
    print(out.read_text(encoding="utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
