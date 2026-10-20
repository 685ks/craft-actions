#!/usr/bin/env bash
# Installs the app's toolchain and targets. Runs in the app directory; TARGETS is space-separated.
set -euo pipefail

if ! command -v rustup >/dev/null 2>&1; then
  echo "::error::rustup is not on PATH (every GitHub-hosted runner has it)"
  exit 1
fi
rustup set profile minimal

dir="$PWD"
toolchain_file=""
while :; do
  for f in rust-toolchain.toml rust-toolchain; do
    if [ -f "$dir/$f" ]; then toolchain_file="$dir/$f"; break 2; fi
  done
  parent="$(dirname "$dir")"
  [ "$parent" = "$dir" ] && break
  [ -n "${GITHUB_WORKSPACE:-}" ] && [ "$dir" = "$GITHUB_WORKSPACE" ] && break
  dir="$parent"
done

if [ -n "$toolchain_file" ]; then
  echo "using the toolchain from $toolchain_file"
  # rustup >= 1.28 installs the toolchain file's toolchain on demand; older ones need `rustup show`.
  rustup toolchain install 2>/dev/null || rustup show active-toolchain >/dev/null
else
  rustup toolchain install stable --no-self-update
  rustup default stable
fi

read -r -a targets <<<"${TARGETS:-}"
if [ "${#targets[@]}" -gt 0 ]; then
  rustup target add "${targets[@]}"
fi
rustc --version --verbose
cargo --version
