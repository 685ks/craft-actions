#!/usr/bin/env bash
# cargo-cyclonedx over the app's workspace; keeps the BOM of the released package. Runs in the app
# directory.
set -euo pipefail

CYCLONEDX_VERSION=0.5.9
CYCLONEDX_SHA256=fb8dbee9f182173e062a64a387b21a0badc6fab8b2abf9294973f012972bf6d8 # x86_64-unknown-linux-gnu

if [ "$(uname -s)-$(uname -m)" != "Linux-x86_64" ]; then
  echo "::error::the sbom action runs on Linux x86_64 runners"
  exit 1
fi
tools="${RUNNER_TEMP:?}/craft-sbom-tools"
rm -rf "$tools"
mkdir -p "$tools" "$OUT_DIR"
out="$(cd "$OUT_DIR" && pwd)"
archive="$tools/cargo-cyclonedx.tar.xz"
curl -fsSL --retry 5 --retry-all-errors --proto '=https' --tlsv1.2 -o "$archive" \
  "https://github.com/CycloneDX/cyclonedx-rust-cargo/releases/download/cargo-cyclonedx-${CYCLONEDX_VERSION}/cargo-cyclonedx-x86_64-unknown-linux-gnu.tar.xz"
echo "$CYCLONEDX_SHA256  $archive" | sha256sum -c -
tar -xJf "$archive" -C "$tools" --strip-components=1
export PATH="$tools:$PATH"
cargo-cyclonedx --version || cargo cyclonedx --version

manifest="$(cargo metadata --format-version 1 --no-deps | jq -r --arg p "$PACKAGE" '[.packages[] | select(.name == $p) | .manifest_path][0] // ""')"
if [ -z "$manifest" ]; then
  echo "::error::no package named $PACKAGE in this workspace"
  exit 1
fi

args=(cyclonedx --format json --spec-version 1.5 --all --override-filename craft-sbom --target all)
if [ -n "${FEATURES// /}" ]; then
  args+=(--features "$FEATURES")
fi
cargo "${args[@]}"
bom="$(dirname "$manifest")/craft-sbom.json"
if [ ! -f "$bom" ]; then
  echo "::error::cargo-cyclonedx wrote no $bom"
  find . -name 'craft-sbom*.json' -print
  exit 1
fi
dest="$out/$APP_ID-$VERSION-sbom.cdx.json"
jq . "$bom" >"$dest"
find . -name 'craft-sbom.json' -delete
jq -r '"\(.bomFormat) \(.specVersion): \(.components | length) components"' "$dest"
