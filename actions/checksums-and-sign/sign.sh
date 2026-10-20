#!/usr/bin/env bash
# Signs SHA256SUMS.txt with minisign (see the action's description). Runs in the assets folder.
set -euo pipefail

key_dir="$(mktemp -d "${RUNNER_TEMP:?}/minisign.XXXXXX")"
trap 'rm -rf "$key_dir"' EXIT
comment="$DISPLAY_NAME $TAG"

if [ -z "${RELEASE_SIGNING_KEY:-}" ] && [ "${SELF_TEST:-false}" != "true" ]; then
  echo "::notice::RELEASE_SIGNING_KEY is not set: SHA256SUMS.txt is published unsigned"
  echo "signed=false" >>"$GITHUB_OUTPUT"
  exit 0
fi

if ! command -v minisign >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq --no-install-recommends minisign
fi
minisign -v || true

if [ -n "${RELEASE_SIGNING_KEY:-}" ]; then
  (umask 077 && printf '%s\n' "$RELEASE_SIGNING_KEY" >"$key_dir/minisign.key")
  minisign -S -s "$key_dir/minisign.key" -m SHA256SUMS.txt -x SHA256SUMS.txt.minisig -t "$comment"
  # The public key, recomputed from the secret key: it must be the one built into the launcher.
  if minisign -R -s "$key_dir/minisign.key" -p "$key_dir/minisign.pub" >/dev/null; then
    echo "public key: $(tail -n 1 "$key_dir/minisign.pub")"
    minisign -V -p "$key_dir/minisign.pub" -m SHA256SUMS.txt -x SHA256SUMS.txt.minisig
  else
    echo "::warning::this minisign cannot recompute the public key; the signature was not verified here"
  fi
  grep -qxF "trusted comment: $comment" SHA256SUMS.txt.minisig
  cat SHA256SUMS.txt.minisig
  echo "signed=true" >>"$GITHUB_OUTPUT"
else
  echo "self-test: signing with a throwaway key (the signature is not kept)"
  minisign -G -W -f -p "$key_dir/test.pub" -s "$key_dir/test.key" >/dev/null
  minisign -S -s "$key_dir/test.key" -m SHA256SUMS.txt -x "$key_dir/test.minisig" -t "$comment"
  minisign -V -p "$key_dir/test.pub" -m SHA256SUMS.txt -x "$key_dir/test.minisig"
  grep -qxF "trusted comment: $comment" "$key_dir/test.minisig"
  echo "signed=false" >>"$GITHUB_OUTPUT"
fi
