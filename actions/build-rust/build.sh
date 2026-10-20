#!/usr/bin/env bash
# cargo build --release for one binary and target. Runs in the app directory.
set -euo pipefail

export CARGO_TERM_COLOR=always
tmp="${RUNNER_TEMP:?}"
# Git Bash on Windows: a D:/a/_temp style path works for both cargo and bash.
if command -v cygpath >/dev/null 2>&1; then tmp="$(cygpath -m "$tmp")"; fi
export CARGO_TARGET_DIR="$tmp/craft-target"
export CARGO_INCREMENTAL=0

args=(build --release --package "$PACKAGE" --bin "$BIN" --target "$TARGET")
root="$(cargo locate-project --workspace --message-format plain)"
if command -v cygpath >/dev/null 2>&1; then root="$(cygpath -m "$root")"; fi
if [ -f "$(dirname "$root")/Cargo.lock" ]; then
  args+=(--locked)
else
  echo "::warning::no Cargo.lock next to $root: building without --locked"
fi
if [ -n "${FEATURES// /}" ]; then
  args+=(--features "$FEATURES")
fi

# The package's own version should be the release version; say so when it isn't.
pkg_version="$(cargo metadata --format-version 1 --no-deps | jq -r --arg p "$PACKAGE" '[.packages[] | select(.name == $p) | .version][0] // ""')"
if [ -z "$pkg_version" ]; then
  echo "::error::no package named $PACKAGE in this workspace"
  exit 1
fi
if [ "$pkg_version" != "$CRAFT_RELEASE_VERSION" ]; then
  echo "::warning::$PACKAGE is version $pkg_version in Cargo.toml but is released as $CRAFT_RELEASE_VERSION"
fi

echo "cargo ${args[*]}"
cargo "${args[@]}"

exe=""
case "$TARGET" in *windows*) exe=".exe" ;; esac
binary="$CARGO_TARGET_DIR/$TARGET/release/$BIN$exe"
if [ ! -f "$binary" ]; then
  echo "::error::cargo did not produce $binary"
  exit 1
fi
ls -l "$binary"
echo "binary=$binary" >>"$GITHUB_OUTPUT"
