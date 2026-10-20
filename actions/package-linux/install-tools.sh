#!/usr/bin/env bash
# Downloads appimagetool, the AppImage type 2 runtime and nfpm for ARCH, verifies each against the
# SHA-256 pinned below, and exports their paths (APPIMAGETOOL, APPIMAGE_RUNTIME, NFPM) via
# $GITHUB_ENV. To update a tool, change its version and both checksums together (the sums are the
# "digest" GitHub shows for each release asset).
set -euo pipefail

APPIMAGETOOL_VERSION=1.9.1
RUNTIME_VERSION=20251108
NFPM_VERSION=2.47.0

case "${ARCH:?}" in
  x86_64)
    appimagetool_sha=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
    runtime_sha=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d
    nfpm_asset="nfpm_${NFPM_VERSION}_Linux_x86_64.tar.gz"
    nfpm_sha=0660ca602b2d2d2ae4781a06c692b3eeb9d437ffea05b831d76e41f4a3188783
    ;;
  aarch64)
    appimagetool_sha=f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158
    runtime_sha=00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444
    nfpm_asset="nfpm_${NFPM_VERSION}_Linux_arm64.tar.gz"
    nfpm_sha=1c0f5f2999b9a974bfb04fdb0cc3306096de530ac5dbb25d739cc5f5219c919c
    ;;
  *)
    echo "::error::unsupported Linux architecture $ARCH (x86_64 or aarch64)"
    exit 1
    ;;
esac
if [ "$(uname -m)" != "$ARCH" ]; then
  echo "::error::packaging for $ARCH on a $(uname -m) runner: use a native runner"
  exit 1
fi

tools="${RUNNER_TEMP:?}/craft-linux-tools"
rm -rf "$tools"
mkdir -p "$tools"

fetch() { # url sha256 destination
  curl -fsSL --retry 5 --retry-all-errors --proto '=https' --tlsv1.2 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c -
}

fetch "https://github.com/AppImage/appimagetool/releases/download/${APPIMAGETOOL_VERSION}/appimagetool-${ARCH}.AppImage" \
  "$appimagetool_sha" "$tools/appimagetool.AppImage"
fetch "https://github.com/AppImage/type2-runtime/releases/download/${RUNTIME_VERSION}/runtime-${ARCH}" \
  "$runtime_sha" "$tools/runtime"
fetch "https://github.com/goreleaser/nfpm/releases/download/v${NFPM_VERSION}/${nfpm_asset}" \
  "$nfpm_sha" "$tools/nfpm.tar.gz"

# appimagetool is itself an AppImage; extract it so it runs without FUSE.
(cd "$tools" && chmod +x appimagetool.AppImage && ./appimagetool.AppImage --appimage-extract >/dev/null && mv squashfs-root appimagetool)
tar -xzf "$tools/nfpm.tar.gz" -C "$tools" nfpm
"$tools/nfpm" --version | head -n 3
"$tools/appimagetool/AppRun" --version 2>&1 | head -n 1 || true

{
  echo "APPIMAGETOOL=$tools/appimagetool/AppRun"
  echo "APPIMAGE_RUNTIME=$tools/runtime"
  echo "NFPM=$tools/nfpm"
} >>"$GITHUB_ENV"
