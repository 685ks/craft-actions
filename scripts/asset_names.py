#!/usr/bin/env python3
"""Release asset names: the grammar the Craft launcher reads, and a checker for a release folder.

Every package a release ships is named

    <app-id>-<version>-<os>-<arch>[-portable].<ext>

for example ``photocraft-0.5.0-windows-x64.msi`` or ``photocraft-0.2.0-rc.1-linux-aarch64.AppImage``.
``parse()`` reads a name the same way the launcher does (crates/core/src/platform.rs,
``parse_asset_name`` in 685ks/craft-launcher): strip a known package suffix, strip ``<app-id>-``, then
split the rest from the right into version, os and arch (os and arch never contain ``-``; versions
may). The version must be a semantic version that starts with a digit.

Everything else a release carries (checksums, signatures, the SBOM, the update feed, zsync files) must
*not* read as a package, so the launcher never offers it as a download.

Usage:
    asset_names.py check DIR --app-id ID --version VERSION [--expect-full]

Runs on Python 3.8+ with the standard library only.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import NamedTuple, Optional, Sequence

# Package kinds in the order the launcher tries their suffixes. "-portable.zip" must come before any
# plain ".zip" (there is none), and ".tar.gz" before anything ending in ".gz".
KINDS: Sequence[tuple[str, str]] = (
    ("portable-zip", "-portable.zip"),
    ("tar.gz", ".tar.gz"),
    ("msi", ".msi"),
    ("dmg", ".dmg"),
    ("appimage", ".AppImage"),
    ("deb", ".deb"),
    ("rpm", ".rpm"),
    ("arch-pkg", ".pkg.tar.zst"),
    ("flatpak", ".flatpak"),
)

# semver 2.0.0, as the `semver` crate parses it (build metadata allowed).
_NUM = r"(?:0|[1-9][0-9]*)"
_PRE_ID = r"(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
_BUILD_ID = r"[0-9A-Za-z-]+"
SEMVER = re.compile(rf"^{_NUM}\.{_NUM}\.{_NUM}(?:-{_PRE_ID}(?:\.{_PRE_ID})*)?(?:\+{_BUILD_ID}(?:\.{_BUILD_ID})*)?$")

# What the release workflow builds, per platform token. Tokens are the launcher's.
EXPECTED = {
    "windows-x64": ("msi", "portable-zip"),
    "linux-x86_64": ("appimage", "tar.gz", "deb", "rpm"),
    "linux-aarch64": ("appimage", "tar.gz", "deb", "rpm"),
}

# Files that are allowed in a release but are not packages.
AUX_FIXED = {"SHA256SUMS.txt", "SHA256SUMS.txt.minisig", "update-feed.json"}


class AssetName(NamedTuple):
    stem: str
    version: str
    token: str
    kind: str


def version_ok(text: str) -> bool:
    """The launcher's version check for asset names: semver (an optional leading v is accepted by
    the launcher's parser, but asset versions must start with a digit) of at most 64 characters."""
    return 0 < len(text) <= 64 and text[0].isdigit() and SEMVER.match(text) is not None


def parse(name: str, stems: Sequence[str]) -> Optional[AssetName]:
    """Reads ``<stem>-<version>-<os>-<arch>[-portable].<ext>``; ``None`` for anything else."""
    for kind, suffix in KINDS:
        if name.endswith(suffix):
            base = name[: -len(suffix)]
            break
    else:
        return None
    for stem in stems:
        if not base.startswith(stem + "-"):
            continue
        rest = base[len(stem) + 1 :]
        parts = rest.rsplit("-", 2)
        if len(parts) != 3:
            return None
        version, os_, arch = parts
        if not version_ok(version):
            continue
        return AssetName(stem, version, f"{os_}-{arch}", kind)
    return None


def asset_name(app_id: str, version: str, token: str, kind: str) -> str:
    """The name the release workflow gives a package."""
    suffix = dict(KINDS)[kind]
    return f"{app_id}-{version}-{token}{suffix}"


def is_aux(name: str, app_id: str, version: str) -> bool:
    if name in AUX_FIXED:
        return True
    if name == f"{app_id}-{version}-sbom.cdx.json":
        return True
    if name.endswith(".AppImage.zsync"):
        return True
    return False


def check(names: Sequence[str], app_id: str, version: str, expect_full: bool) -> list[str]:
    """Problems with a release's file names; empty when they are all right."""
    problems = []
    seen: dict[str, set[str]] = {}
    for name in sorted(names):
        parsed = parse(name, [app_id])
        if is_aux(name, app_id, version):
            if parsed is not None:
                problems.append(f"{name}: an auxiliary file must not read as a package, but reads as {parsed}")
            continue
        if parsed is None:
            problems.append(f"{name}: not a package name the launcher can read (<id>-<version>-<os>-<arch>[-portable].<ext>)")
            continue
        if parsed.version != version:
            problems.append(f"{name}: version {parsed.version!r} is not the release version {version!r}")
        if parsed.token not in EXPECTED:
            problems.append(f"{name}: platform {parsed.token!r} is not one of {sorted(EXPECTED)}")
            continue
        if parsed.kind not in EXPECTED[parsed.token]:
            problems.append(f"{name}: {parsed.kind} is not a package this release builds for {parsed.token}")
        if asset_name(app_id, version, parsed.token, parsed.kind) != name:
            problems.append(f"{name}: does not round-trip to the canonical name")
        seen.setdefault(parsed.token, set()).add(parsed.kind)
    if expect_full:
        for token, kinds in EXPECTED.items():
            for kind in kinds:
                if kind not in seen.get(token, set()):
                    problems.append(f"missing {asset_name(app_id, version, token, kind)}")
    return problems


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check", help="check every file name in a release folder")
    c.add_argument("dir", type=Path)
    c.add_argument("--app-id", required=True)
    c.add_argument("--version", required=True)
    c.add_argument("--expect-full", action="store_true", help="also require every package of every platform")
    args = ap.parse_args(argv)

    names = [p.name for p in args.dir.iterdir() if p.is_file()]
    if not names:
        print(f"::error::{args.dir} holds no files")
        return 1
    problems = check(names, args.app_id, args.version, args.expect_full)
    for name in sorted(names):
        parsed = parse(name, [args.app_id])
        print(f"  {name}: {parsed.token + ' ' + parsed.kind if parsed else 'not a package'}")
    for p in problems:
        print(f"::error::{p}")
    if problems:
        return 1
    print(f"{len(names)} file names are as the launcher expects")
    return 0


if __name__ == "__main__":
    sys.exit(main())
