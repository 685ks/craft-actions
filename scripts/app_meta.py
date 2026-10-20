#!/usr/bin/env python3
"""Validates the release inputs and reads packaging/app.toml; writes the results as step outputs.

Inputs come from the environment (never from the command line, so nothing is interpolated into a
shell): APP_ID, DISPLAY_NAME, BUNDLE_ID, VERSION, PACKAGE, BIN, FEATURES, PUBLISH, PRERELEASE,
APP_DIR (the app's directory, holding packaging/app.toml), REPOSITORY (owner/repo), OWNER.

Outputs (written to $GITHUB_OUTPUT, or printed when it is unset):
  version, tag, prerelease, numeric-version, msi-version, description, categories, icon-png,
  icon-icns, icon-ico, license, homepage, maintainer, publisher, upgrade-code, features

Python 3.11+ (tomllib).
"""

from __future__ import annotations

import os
import re
import struct
import sys
import tomllib
import uuid
from pathlib import Path, PurePosixPath

APP_ID = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
BUNDLE_ID = re.compile(r"^[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)+$")
CARGO_NAME = re.compile(r"^[A-Za-z0-9_-]+$")
FEATURES = re.compile(r"^[A-Za-z0-9_/,+ .:-]*$")
CATEGORY = re.compile(r"^[A-Za-z0-9-]+$")
# semver 2.0.0 without build metadata ("+..." does not belong in file names or package versions).
_NUM = r"(?:0|[1-9][0-9]*)"
_PRE_ID = r"(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
VERSION = re.compile(rf"^({_NUM})\.({_NUM})\.({_NUM})(?:-{_PRE_ID}(?:\.{_PRE_ID})*)?$")
UPGRADE_CODE = re.compile(r"^\{?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}?$")

errors: list[str] = []


def error(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    print(f"::warning::{msg}")


def single_line(name: str, value: str, max_len: int = 200) -> str:
    if not value or any(c in value for c in "\r\n\0") or len(value) > max_len:
        error(f"{name} must be one non-empty line of at most {max_len} characters, got {value!r}")
    return value


def png_size(path: Path) -> tuple[int, int] | None:
    with path.open("rb") as f:
        head = f.read(24)
    if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", head[16:24])


def rel_file(app_dir: Path, key: str, value: object, required: bool) -> str:
    """A path in app.toml: relative to the app directory, inside it, and present."""
    if value is None or value == "":
        if required:
            error(f"packaging/app.toml: {key} is required")
        return ""
    if not isinstance(value, str):
        error(f"packaging/app.toml: {key} must be a string")
        return ""
    p = PurePosixPath(value)
    if p.is_absolute() or ".." in p.parts or "\\" in value:
        error(f"packaging/app.toml: {key} must be a relative path inside the app directory, got {value!r}")
        return ""
    if not (app_dir / value).is_file():
        error(f"packaging/app.toml: {key} = {value!r} does not exist")
        return ""
    return value


def main() -> int:
    env = os.environ
    app_id = env.get("APP_ID", "")
    display_name = env.get("DISPLAY_NAME", "")
    bundle_id = env.get("BUNDLE_ID", "")
    version = env.get("VERSION", "").strip()
    package = env.get("PACKAGE", "")
    bin_name = env.get("BIN", "")
    features = env.get("FEATURES", "").strip()
    publish = env.get("PUBLISH", "false") == "true"
    prerelease_in = env.get("PRERELEASE", "false") == "true"
    app_dir = Path(env.get("APP_DIR", "."))
    repository = env.get("REPOSITORY", "")
    owner = env.get("OWNER", repository.split("/")[0] if repository else "")

    if not APP_ID.match(app_id) or len(app_id) > 64:
        error(f"app-id must be lowercase letters, digits and single dashes (e.g. photocraft), got {app_id!r}")
    single_line("display-name", display_name, 64)
    if re.search(r'[/\\:*?"<>|]', display_name) or display_name != display_name.strip():
        error(f"display-name is used as a file name (<display-name>.app) and must not contain / \\ : * ? \" < > | "
              f"or surrounding spaces, got {display_name!r}")
    if not BUNDLE_ID.match(bundle_id):
        error(f"bundle-id must be a reverse-DNS name such as app.freedev.ainz.ks.PhotoCraft, got {bundle_id!r}")
    if version.startswith(("v", "V")):
        version = version[1:]
    m = VERSION.match(version)
    if not m:
        error(f"version must be a semantic version such as 1.2.3 or 1.2.3-rc.1 (no build metadata), got {version!r}")
    for key, value in (("package", package), ("bin", bin_name)):
        if not CARGO_NAME.match(value):
            error(f"{key} must be a cargo package/binary name, got {value!r}")
    if not FEATURES.match(features):
        error(f"features must be a comma- or space-separated list of cargo features, got {features!r}")

    toml_path = app_dir / "packaging" / "app.toml"
    meta: dict = {}
    if not toml_path.is_file():
        error(f"{toml_path} is missing: every app ships packaging/app.toml (see the craft-actions README)")
    else:
        try:
            meta = tomllib.loads(toml_path.read_text(encoding="utf-8"))
        except (tomllib.TOMLDecodeError, UnicodeDecodeError) as e:
            error(f"{toml_path}: {e}")

    for key, given in (("id", app_id), ("display_name", display_name), ("bundle_id", bundle_id)):
        if key in meta and meta[key] != given:
            warn(f"packaging/app.toml {key} = {meta[key]!r} differs from the workflow input {given!r}; using the input")

    description = single_line("packaging/app.toml description", str(meta.get("description", "")), 300)
    categories = meta.get("categories", [])
    if not isinstance(categories, list) or not categories or not all(isinstance(c, str) and CATEGORY.match(c) for c in categories):
        error(f"packaging/app.toml categories must be a non-empty list of freedesktop categories, got {categories!r}")
        categories = []
    license_ = single_line("packaging/app.toml license", str(meta.get("license", "")), 100)
    icon_png = rel_file(app_dir, "icon_png", meta.get("icon_png"), True)
    icon_icns = rel_file(app_dir, "icon_icns", meta.get("icon_icns"), False)
    icon_ico = rel_file(app_dir, "icon_ico", meta.get("icon_ico"), False)
    if icon_png:
        size = png_size(app_dir / icon_png)
        if size is None:
            error(f"packaging/app.toml icon_png = {icon_png!r} is not a PNG file")
        elif size[0] != size[1] or size[0] < 256:
            error(f"packaging/app.toml icon_png must be a square PNG of at least 256 px (512+ recommended), got {size[0]}x{size[1]}")
        elif size[0] < 512:
            warn(f"icon_png is {size[0]}x{size[1]}; 512x512 or larger is recommended")

    homepage = single_line("homepage", str(meta.get("homepage", f"https://github.com/{repository}")))
    maintainer = single_line("maintainer", str(meta.get("maintainer", f"{owner} <{owner}@users.noreply.github.com>")))
    publisher = single_line("publisher", str(meta.get("publisher", owner)), 100)
    upgrade_code = str(meta.get("windows_upgrade_code", "")) or str(uuid.uuid5(uuid.NAMESPACE_DNS, bundle_id or "x")).upper()
    if not UPGRADE_CODE.match(upgrade_code):
        error(f"packaging/app.toml windows_upgrade_code must be a GUID, got {upgrade_code!r}")
    upgrade_code = upgrade_code.strip("{}").upper()

    numeric = msi = ""
    is_pre = False
    if m:
        major, minor, patch = (int(x) for x in m.groups())
        numeric = f"{major}.{minor}.{patch}"
        is_pre = "-" in version
        if major > 255 or minor > 255 or patch > 65535:
            error(f"version {version} cannot be a Windows Installer version (major and minor <= 255, patch <= 65535)")
        msi = numeric
        if is_pre:
            warn(f"Windows Installer versions are numeric: the MSI of {version} reports {msi}")
    prerelease = prerelease_in or is_pre
    if is_pre and not prerelease_in:
        warn(f"{version} is a pre-release version: the GitHub Release is marked as a pre-release")
    if publish:
        print(f"publishing v{version}" + (" as a pre-release" if prerelease else ""))

    if errors:
        for e in errors:
            print(f"::error::{e}")
        return 1

    outputs = {
        "version": version,
        "tag": f"v{version}",
        "prerelease": "true" if prerelease else "false",
        "numeric-version": numeric,
        "msi-version": msi,
        "description": description,
        "categories": "".join(f"{c};" for c in categories),
        "icon-png": icon_png,
        "icon-icns": icon_icns,
        "icon-ico": icon_ico,
        "license": license_,
        "homepage": homepage,
        "maintainer": maintainer,
        "publisher": publisher,
        "upgrade-code": upgrade_code,
        "features": features,
    }
    out = env.get("GITHUB_OUTPUT")
    lines = [f"{k}={v}" for k, v in outputs.items()]
    if out:
        with open(out, "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    for line in lines:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
