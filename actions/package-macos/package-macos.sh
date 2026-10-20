#!/usr/bin/env bash
# Universal binary -> <DisplayName>.app -> <id>-<version>-macos-universal.dmg, signed and notarized
# when the secrets are present. Runs in the app directory; inputs come from the environment.
set -euo pipefail

: "${APP_ID:?}" "${DISPLAY_NAME:?}" "${BUNDLE_ID:?}" "${VERSION:?}" "${NUMERIC_VERSION:?}" "${BIN:?}"
: "${BINARY_ARM64:?}" "${BINARY_X86_64:?}" "${ICON_PNG:?}" "${OUT_DIR:?}"

base="$APP_ID-$VERSION-macos-universal"
work="${RUNNER_TEMP:?}/craft-macos"
rm -rf "$work"
mkdir -p "$work" "$OUT_DIR"
out="$(cd "$OUT_DIR" && pwd)"
keychain=""

cleanup() {
  if [ -n "$keychain" ]; then
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
  fi
  rm -f "$work/certificate.p12"
}
trap cleanup EXIT

# ---- universal binary -------------------------------------------------------------------------------
lipo -create -output "$work/$BIN" "$BINARY_ARM64" "$BINARY_X86_64"
archs="$(lipo -archs "$work/$BIN")"
echo "architectures: $archs"
case "$archs" in *x86_64*arm64* | *arm64*x86_64*) ;; *)
  echo "::error::the universal binary holds '$archs', expected x86_64 and arm64"
  exit 1
  ;;
esac

# ---- the .app bundle --------------------------------------------------------------------------------
app="$work/$DISPLAY_NAME.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 0755 "$work/$BIN" "$app/Contents/MacOS/$BIN"

if [ -n "${ICON_ICNS:-}" ]; then
  cp "$ICON_ICNS" "$app/Contents/Resources/AppIcon.icns"
else
  iconset="$work/AppIcon.iconset"
  mkdir -p "$iconset"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$ICON_PNG" --out "$iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$ICON_PNG" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$iconset"
fi

# Info.plist through plistlib, which does the XML escaping. "<DisplayName>Version" carries the full
# version (with any pre-release suffix): the Craft launcher reads it before CFBundleShortVersionString.
python3 - "$app/Contents/Info.plist" <<'PY'
import os, plistlib, sys
e = os.environ
info = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": e["DISPLAY_NAME"],
    "CFBundleName": e["DISPLAY_NAME"],
    "CFBundleExecutable": e["BIN"],
    "CFBundleIdentifier": e["BUNDLE_ID"],
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": e["NUMERIC_VERSION"],
    "CFBundleVersion": e["NUMERIC_VERSION"],
    "CFBundleIconFile": "AppIcon",
    "LSMinimumSystemVersion": e.get("MIN_SYSTEM") or "11.0",
    "NSHighResolutionCapable": True,
    "NSSupportsAutomaticGraphicsSwitching": True,
    e["DISPLAY_NAME"] + "Version": e["VERSION"],
}
with open(sys.argv[1], "wb") as f:
    plistlib.dump(info, f)
PY
plutil -lint "$app/Contents/Info.plist"
printf 'APPL????' >"$app/Contents/PkgInfo"

# ---- signing ------------------------------------------------------------------------------------------
identity="-"
if [ -n "${MACOS_CERTIFICATE:-}" ]; then
  keychain="$work/signing.keychain-db"
  kc_password="$(openssl rand -hex 24)"
  (umask 077 && printf '%s' "$MACOS_CERTIFICATE" | base64 --decode >"$work/certificate.p12")
  security create-keychain -p "$kc_password" "$keychain"
  security set-keychain-settings -lut 3600 "$keychain"
  security unlock-keychain -p "$kc_password" "$keychain"
  security import "$work/certificate.p12" -k "$keychain" -P "${MACOS_CERTIFICATE_PASSWORD:-}" -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kc_password" "$keychain" >/dev/null
  # Put the new keychain first in the search list so codesign finds the identity.
  existing=()
  while IFS= read -r k; do
    k="${k//\"/}"
    k="${k#"${k%%[![:space:]]*}"}"
    [ -n "$k" ] && existing+=("$k")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s "$keychain" "${existing[@]}"
  identity="$(security find-identity -v -p codesigning "$keychain" | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
  if [ -z "$identity" ]; then
    echo "::error::MACOS_CERTIFICATE holds no 'Developer ID Application' identity"
    exit 1
  fi
  echo "signing with: $identity"
  codesign --force --timestamp --options runtime --keychain "$keychain" --sign "$identity" "$app/Contents/MacOS/$BIN"
  codesign --force --timestamp --options runtime --keychain "$keychain" --sign "$identity" "$app"
else
  echo "::notice::MACOS_CERTIFICATE is not set: the app is signed ad hoc and not notarized"
  codesign --force --sign - "$app/Contents/MacOS/$BIN"
  codesign --force --sign - "$app"
fi
codesign --verify --strict --verbose=2 "$app"

# ---- DMG ------------------------------------------------------------------------------------------------
stage="$work/dmg"
mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
dmg="$out/$base.dmg"
rm -f "$dmg"
# hdiutil sometimes fails with "Resource busy" on hosted runners; try a few times.
for attempt in 1 2 3 4 5; do
  if hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"; then
    break
  fi
  if [ "$attempt" = 5 ]; then
    echo "::error::hdiutil create failed"
    exit 1
  fi
  sleep $((attempt * 5))
done
if [ "$identity" != "-" ]; then
  codesign --force --timestamp --keychain "$keychain" --sign "$identity" "$dmg"
fi

# ---- notarization ----------------------------------------------------------------------------------------
if [ "$identity" != "-" ] && [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
  echo "notarizing $base.dmg"
  result="$(xcrun notarytool submit "$dmg" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" --wait --timeout 60m --output-format json)"
  echo "$result"
  status="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
  if [ "$status" != "Accepted" ]; then
    id="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
    if [ -n "$id" ]; then
      xcrun notarytool log "$id" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" || true
    fi
    echo "::error::notarization ended as '$status'"
    exit 1
  fi
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
elif [ "$identity" != "-" ]; then
  echo "::warning::signed but not notarized: set APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD to notarize"
fi

hdiutil verify "$dmg"
ls -l "$out"
