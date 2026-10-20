#!/usr/bin/env bash
# Packs one Linux binary as AppImage (+ zsync), tar.gz, deb and rpm. Runs in the app directory.
# Inputs come from the environment (see action.yml); tool paths from install-tools.sh.
set -euo pipefail

: "${APP_ID:?}" "${DISPLAY_NAME:?}" "${BUNDLE_ID:?}" "${VERSION:?}" "${BIN:?}" "${BINARY:?}" "${ARCH:?}"
: "${DESCRIPTION:?}" "${CATEGORIES:?}" "${ICON_PNG:?}" "${LICENSE:?}" "${HOMEPAGE:?}" "${MAINTAINER:?}"
: "${REPOSITORY:?}" "${OUT_DIR:?}" "${APPIMAGETOOL:?}" "${APPIMAGE_RUNTIME:?}" "${NFPM:?}"

base="$APP_ID-$VERSION-linux-$ARCH"
work="${RUNNER_TEMP:?}/craft-linux-$ARCH"
rm -rf "$work"
mkdir -p "$work" "$OUT_DIR"
out="$(cd "$OUT_DIR" && pwd)"
app_dir="$PWD"

# Reproducible timestamps: the commit time, unless the caller set one.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || date +%s)}"

# Icon size: hicolor wants the icon under its real size.
size="$(python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(24); print(struct.unpack(">I", d[16:20])[0])' "$ICON_PNG")"
icon_dir="share/icons/hicolor/${size}x${size}/apps"

# ---- the install tree: bin/, share/ (the tarball layout the Craft launcher installs) -------------
tree="$work/$base"
mkdir -p "$tree/bin" "$tree/share/applications" "$tree/$icon_dir" "$tree/share/doc/$APP_ID"
install -m 0755 "$BINARY" "$tree/bin/$BIN"
install -m 0644 "$ICON_PNG" "$tree/$icon_dir/$BUNDLE_ID.png"

desktop="$tree/share/applications/$BUNDLE_ID.desktop"
{
  echo "[Desktop Entry]"
  echo "Type=Application"
  echo "Name=$DISPLAY_NAME"
  echo "Comment=$DESCRIPTION"
  echo "Exec=$BIN %F"
  echo "Icon=$BUNDLE_ID"
  echo "Terminal=false"
  echo "Categories=$CATEGORIES"
  echo "StartupWMClass=$BUNDLE_ID"
} >"$desktop"
chmod 0644 "$desktop"
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$desktop"
fi

docs=()
for f in LICENSE LICENSE-* LICENSE.* COPYING NOTICE NOTICE.* README.md; do
  if [ -f "$f" ]; then
    install -m 0644 "$f" "$tree/share/doc/$APP_ID/"
    docs+=("$f")
  fi
done
if [ "${#docs[@]}" -eq 0 ]; then
  echo "::warning::no LICENSE/NOTICE files found in $app_dir; the packages ship none"
fi

# ---- tar.gz ---------------------------------------------------------------------------------------
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$SOURCE_DATE_EPOCH" \
  -C "$work" -cf - "$base" | gzip -n -9 >"$out/$base.tar.gz"

# ---- AppImage ---------------------------------------------------------------------------------------
appdir="$work/AppDir"
mkdir -p "$appdir/usr"
cp -a "$tree/bin" "$tree/share" "$appdir/usr/"
cp "$desktop" "$appdir/$BUNDLE_ID.desktop"
cp "$ICON_PNG" "$appdir/$BUNDLE_ID.png"
ln -s "$BUNDLE_ID.png" "$appdir/.DirIcon"
cat >"$appdir/AppRun" <<APPRUN
#!/bin/sh
HERE="\$(dirname "\$(readlink -f "\$0")")"
exec "\$HERE/usr/bin/$BIN" "\$@"
APPRUN
chmod 0755 "$appdir/AppRun"

# Update information: AppImageUpdate (and the launcher) find newer builds through the zsync file of
# the latest release.
update_info="gh-releases-zsync|${REPOSITORY%%/*}|${REPOSITORY#*/}|latest|$APP_ID-*-linux-$ARCH.AppImage.zsync"
(
  cd "$out"
  ARCH="$ARCH" VERSION="$VERSION" "$APPIMAGETOOL" --no-appstream --runtime-file "$APPIMAGE_RUNTIME" \
    -u "$update_info" "$appdir" "$base.AppImage"
)
chmod 0755 "$out/$base.AppImage"
if [ ! -f "$out/$base.AppImage.zsync" ]; then
  echo "::warning::appimagetool wrote no $base.AppImage.zsync (is zsyncmake installed?)"
fi

# ---- deb and rpm (nfpm) --------------------------------------------------------------------------------
case "$ARCH" in
  x86_64) goarch=amd64 ;;
  aarch64) goarch=arm64 ;;
esac
export NFPM_TREE="$tree" NFPM_GOARCH="$goarch" NFPM_ICON_DIR="$icon_dir"
python3 - "$work/nfpm.json" <<'PY'
import json, os, sys
from pathlib import Path

e = os.environ
tree = Path(e["NFPM_TREE"])
contents = []
for path in sorted(p for p in tree.rglob("*") if p.is_file()):
    rel = path.relative_to(tree).as_posix()
    contents.append({
        "src": str(path),
        "dst": f"/usr/{rel}",
        "file_info": {"mode": 0o755 if rel.startswith("bin/") else 0o644},
    })
config = {
    "name": e["APP_ID"],
    "arch": e["NFPM_GOARCH"],
    "platform": "linux",
    "version": e["VERSION"],
    "version_schema": "semver",
    "release": "1",
    "section": "misc",
    "priority": "optional",
    "maintainer": e["MAINTAINER"],
    "description": e["DESCRIPTION"],
    "homepage": e["HOMEPAGE"],
    "license": e["LICENSE"],
    "contents": contents,
    "rpm": {"summary": e["DESCRIPTION"], "group": "Applications/Productivity"},
}
# JSON is YAML, so nfpm reads this as its config file; json.dumps does all the quoting.
Path(sys.argv[1]).write_text(json.dumps(config, indent=2))
PY
"$NFPM" package --config "$work/nfpm.json" --packager deb --target "$out/$base.deb"
"$NFPM" package --config "$work/nfpm.json" --packager rpm --target "$out/$base.rpm"

# ---- check what was made ---------------------------------------------------------------------------
for f in "$base.AppImage" "$base.tar.gz" "$base.deb" "$base.rpm"; do
  if [ ! -s "$out/$f" ]; then
    echo "::error::$f was not produced"
    exit 1
  fi
done
if command -v dpkg-deb >/dev/null 2>&1; then
  dpkg-deb --info "$out/$base.deb"
fi
ls -l "$out"
