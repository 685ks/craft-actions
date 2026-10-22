# craft-actions

Reusable GitHub Actions workflow that builds, packages, signs and releases a Rust desktop app (the
Craft apps: DeckCraft, PhotoCraft, ...) for Windows, with asset names the
[Arthavan Projects launcher](https://github.com/685ks/craft-launcher) reads.

One call builds:

| Platform | Runner | Assets |
|---|---|---|
| Windows x64 | `windows-2025` | `<id>-<version>-windows-x64.msi` (WiX 5), `<id>-<version>-windows-x64-portable.zip` |

and, over the release, `SHA256SUMS.txt`, `SHA256SUMS.txt.minisig` (when a signing key is set),
`<id>-<version>-sbom.cdx.json` (CycloneDX), `update-feed.json`, and a build provenance attestation;
then it creates or updates the GitHub Release `v<version>` on the calling repository (a draft
unless `publish` is true).

## Usage

Add `.github/workflows/release.yml` to the app repository:

```yaml
name: Release

on:
  workflow_dispatch:
    inputs:
      version:
        description: Version to release (e.g. 1.2.3 or 1.2.3-rc.1)
        type: string
        required: true
      publish:
        description: Publish the release (otherwise it stays a draft)
        type: boolean
        default: false
      prerelease:
        description: Mark it as a pre-release
        type: boolean
        default: false

permissions: {}

jobs:
  release:
    uses: 685ks/craft-actions/.github/workflows/release-rust-app.yml@main
    with:
      app-id: photocraft
      display-name: PhotoCraft
      bundle-id: app.freedev.ainz.ks.PhotoCraft
      version: ${{ inputs.version }}
      package: photocraft
      bin: photocraft
      features: ""
      publish: ${{ inputs.publish }}
      prerelease: ${{ inputs.prerelease }}
    secrets: inherit
    permissions:
      contents: write # create the release and its tag
      id-token: write # find the craft-actions commit; sign the provenance
      attestations: write # store the provenance
```

and `packaging/app.toml` (paths are relative to the app directory):

```toml
id = "photocraft"
display_name = "PhotoCraft"
bundle_id = "app.freedev.ainz.ks.PhotoCraft"
description = "Edit photos and raster images"
icon_png = "packaging/icon.png"      # square PNG, 512 px or larger
icon_ico = "packaging/icon.ico"      # optional; made from icon_png when absent
license = "MIT OR Apache-2.0"
# Optional:
# homepage = "https://github.com/685ks/photocraft"          (default: the repository)
# publisher = "Ks and contributors"                         (MSI Manufacturer; default: the repository owner)
# windows_upgrade_code = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"  (default: UUIDv5 of bundle_id, stable)
```

Run it from the Actions tab (*Release* → *Run workflow*). Pin `@main` to a tag or commit SHA if you
want releases to be reproducible against a fixed version of this workflow; every composite action
and script it runs is taken from the same commit as the workflow file itself.

## The contract

### Inputs

| Input | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `app-id` | string | yes | | Asset stem, lowercase letters, digits and dashes (e.g. `photocraft`). |
| `display-name` | string | yes | | Product name (e.g. `PhotoCraft`): MSI product name and install folder. |
| `bundle-id` | string | yes | | Reverse-DNS id (e.g. `app.freedev.ainz.ks.PhotoCraft`): MSI upgrade code seed. |
| `version` | string | yes | | Semantic version, e.g. `1.2.3`, `1.2.3-rc.1` (a leading `v` is dropped; no `+build`). The tag is `v<version>`. |
| `package` | string | yes | | Cargo package of the app binary. |
| `bin` | string | yes | | Binary name. |
| `features` | string | no | `""` | Cargo features (comma- or space-separated). |
| `publish` | boolean | no | `false` | Publish the release; otherwise it stays a draft. |
| `prerelease` | boolean | no | `false` | Mark the release as a pre-release. Versions with a `-` are always pre-releases. |
| `dry-run` | boolean | no | `false` | Build, package, check and sign, but create no release (assets stay in the `craft-assets` artifact). |
| `working-directory` | string | no | `.` | The app's directory, holding its Cargo workspace and `packaging/app.toml`. |
| `linux-packages` | string | no | `""` | Ignored: Linux builds were dropped. Still accepted so existing callers keep working. |

### Secrets (all optional; steps that need one skip when it is absent)

| Secret | Used for |
|---|---|
| `RELEASE_SIGNING_KEY` | Unencrypted [minisign](https://jedisct1.github.io/minisign/) secret key (both lines). Signs `SHA256SUMS.txt` as `SHA256SUMS.txt.minisig` with the trusted comment `<display-name> v<version>`, which the launcher checks against the tag. Make one with `minisign -G -W`; see craft-launcher's `docs/release-signing.md`. |
| `WINDOWS_CERTIFICATE` | Base64 of a code signing `.pfx`; `signtool` signs the exe and the MSI (timestamped). |
| `WINDOWS_CERTIFICATE_PASSWORD` | Password of that `.pfx`. |

### Outputs

| Output | Meaning |
|---|---|
| `version` | The released version (without `v`). |
| `tag` | `v<version>`. |
| `release-url` | URL of the GitHub Release (empty on a dry run). |
| `assets-artifact` | Name of the workflow artifact holding every asset (`craft-assets`). |

### Asset names

Packages are named `<app-id>-<version>-<os>-<arch>[-portable].<ext>` with the platform tokens
`windows-x64` (the grammar of
`parse_asset_name` in craft-launcher's `crates/core/src/platform.rs`). The workflow checks every
file against that grammar before anything is signed or uploaded (`scripts/asset_names.py`), and
checks that the auxiliary files (checksums, signature, SBOM, feed) do *not* read as packages.

### What goes into the packages

- **Windows MSI**: per-machine install into `Program Files\<display-name>\<bin>.exe`, Start menu
  shortcut, `InstallLocation` recorded, major upgrades (same upgrade code for every version).
  MSI versions are numeric, so `1.2.3-rc.1` installs as `1.2.3`. The portable zip has `<bin>.exe` at
  the top level.

Apps can read the release version at build time from `CRAFT_RELEASE_VERSION`
(`option_env!("CRAFT_RELEASE_VERSION")`); the workflow warns when the package's Cargo version
differs from the released one.

### Updating apps: `update-feed.json`

Each release carries `update-feed.json`; `https://github.com/<owner>/<repo>/releases/latest/download/update-feed.json`
always serves the newest stable one (pre-releases are never marked latest):

```json
{
  "schema": 1,
  "id": "photocraft",
  "name": "PhotoCraft",
  "version": "1.2.3",
  "tag": "v1.2.3",
  "prerelease": false,
  "date": "2026-10-20T12:00:00Z",
  "release_url": "https://github.com/685ks/photocraft/releases/tag/v1.2.3",
  "checksums_url": "https://github.com/685ks/photocraft/releases/download/v1.2.3/SHA256SUMS.txt",
  "signature_url": "https://github.com/685ks/photocraft/releases/download/v1.2.3/SHA256SUMS.txt.minisig",
  "platforms": {
    "windows-x64": [
      { "kind": "msi", "name": "photocraft-1.2.3-windows-x64.msi", "size": 123, "sha256": "…", "url": "…" },
      { "kind": "portable-zip", "name": "photocraft-1.2.3-windows-x64-portable.zip", "size": 123, "sha256": "…", "url": "…" }
    ]
  }
}
```

Kinds are `msi` and `portable-zip`. The feed is listed in
`SHA256SUMS.txt`, so a verified signature covers it; `signature_url` is `null` for unsigned releases.

### Re-running and safety

- A draft release with the same tag is updated in place (assets replaced, stale ones removed); a
  **published** release is never modified: release a new version instead.
- If the tag already exists it must point at the commit being built.
- Every third-party action is pinned by commit SHA; every downloaded tool (cargo-cyclonedx) is pinned by version and SHA-256; WiX comes from NuGet at
  a fixed version; inputs reach shell scripts only through `env:`; each job gets only the
  permissions it needs.
- Provenance: `gh attestation verify <file> --repo <owner>/<repo>` checks any asset.

## Repository layout

```
.github/workflows/release-rust-app.yml   the reusable workflow
.github/workflows/ci.yml                 lint (actionlint, shellcheck, zizmor), script tests, and an
                                         end-to-end dry run on test-fixtures/hello-craft that installs
                                         and runs the results on Windows
actions/setup-rust                       toolchain (rust-toolchain.toml aware) and targets
actions/build-rust                       cargo build --release --locked of one binary
actions/package-windows                  MSI (WiX), portable zip, signtool
actions/sbom                             CycloneDX SBOM (cargo-cyclonedx)
actions/checksums-and-sign               SHA256SUMS.txt and minisign signature
scripts/                                 input/app.toml validation, asset name grammar, update feed
test-fixtures/hello-craft                a tiny app with its own packaging/app.toml
```

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT)
at your option.
