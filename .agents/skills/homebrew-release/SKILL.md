---
name: homebrew-release
description: Use when building, validating, publishing, or tap-rendering Homebrew Formula releases for this Swift project, especially separate reader/draft/sender command installs, scripts/build-homebrew-release.sh, scripts/render-homebrew-formula.sh, mise run build:homebrew, homebrew:formula, Nix package/app release checks, or tap formula updates.
---

# Homebrew Release

Use this skill for unsigned Formula releases installed as separate commands:

```bash
brew tap user/tap
brew install gmail-gateway-reader
brew install gmail-gateway-draft
brew install gmail-gateway-sender
```

The signed Cask workflow is not active in this repository. Do not use or
recreate a `gmail-gateway` Cask while the install surface is split Formulae.

Do not fall back to the old single `gmail-gateway` Formula unless the user
explicitly requests a compatibility Formula. The release target is three
independently installable Formulae.

## Release Contract

1. Confirm `VERSION` is the intended release version.
2. Confirm SwiftPM exposes all command products:
   - `gmail-gateway-reader`
   - `gmail-gateway-draft`
   - `gmail-gateway-sender`
3. Confirm Nix exposes matching packages/apps for each command before release:
   - `.#gmail-gateway-reader`
   - `.#gmail-gateway-draft`
   - `.#gmail-gateway-sender`
4. Build and test the Swift package.
5. Build macOS Homebrew tarballs with `scripts/build-homebrew-release.sh`.
6. Publish tarballs to a GitHub Release only when explicitly requested.
7. Render formulae only after all referenced archives and checksums exist.
8. Update and verify every tap formula from the tap checkout.

The default Swift formula contract is macOS-only:

| Formula | Swift product | macOS Apple Silicon asset | macOS Intel asset |
| --- | --- | --- | --- |
| `gmail-gateway-reader` | `gmail-gateway-reader` | `gmail-gateway-reader-<version>-darwin-arm64.tar.gz` | `gmail-gateway-reader-<version>-darwin-x64.tar.gz` |
| `gmail-gateway-draft` | `gmail-gateway-draft` | `gmail-gateway-draft-<version>-darwin-arm64.tar.gz` | `gmail-gateway-draft-<version>-darwin-x64.tar.gz` |
| `gmail-gateway-sender` | `gmail-gateway-sender` | `gmail-gateway-sender-<version>-darwin-arm64.tar.gz` | `gmail-gateway-sender-<version>-darwin-x64.tar.gz` |

Do not add Linux assets unless the project has a reviewed Swift Linux runtime
contract.

Formula class names must be:

| Token | Class |
| --- | --- |
| `gmail-gateway-reader` | `GmailGatewayReader` |
| `gmail-gateway-draft` | `GmailGatewayDraft` |
| `gmail-gateway-sender` | `GmailGatewaySender` |

## Standard Commands

Build and test:

```bash
mise run build
mise run test
swift run gmail-gateway-reader --help
swift run gmail-gateway-draft --help
swift run gmail-gateway-sender --help
```

Verify Nix packages/apps:

```bash
nix build .#gmail-gateway-reader
nix build .#gmail-gateway-draft
nix build .#gmail-gateway-sender
nix run .#gmail-gateway-reader -- --help
nix run .#gmail-gateway-draft -- --help
nix run .#gmail-gateway-sender -- --help
```

Build all Formula archives:

```bash
mise run build:homebrew -- darwin-arm64 darwin-x64
```

Build or render one command only if the scripts support command selection:

```bash
version="$(tr -d '[:space:]' < VERSION)"
mise run build:homebrew -- gmail-gateway-reader darwin-arm64 darwin-x64
mise run homebrew:formula -- "$version" gmail-gateway-reader
```

Render formulae locally:

```bash
version="$(tr -d '[:space:]' < VERSION)"
mise run homebrew:formula -- "$version"
```

Render formulae into the default sibling tap:

```bash
version="$(tr -d '[:space:]' < VERSION)"
mise run homebrew:tap-formula -- "$version"
```

For a custom tap path:

```bash
version="$(tr -d '[:space:]' < VERSION)"
scripts/render-homebrew-formula.sh "$version" /path/to/homebrew-tap/Formula
```

## Publishing Notes

Before rendering formulae for public use, ensure the GitHub Release assets
exist for every command and target:

```bash
version="$(tr -d '[:space:]' < VERSION)"
gh release view "v${version}" --repo user/repo
```

If publishing is explicitly requested:

```bash
version="$(tr -d '[:space:]' < VERSION)"
assets=(
  "dist/homebrew/gmail-gateway-reader-${version}-darwin-arm64.tar.gz"
  "dist/homebrew/gmail-gateway-reader-${version}-darwin-x64.tar.gz"
  "dist/homebrew/gmail-gateway-draft-${version}-darwin-arm64.tar.gz"
  "dist/homebrew/gmail-gateway-draft-${version}-darwin-x64.tar.gz"
  "dist/homebrew/gmail-gateway-sender-${version}-darwin-arm64.tar.gz"
  "dist/homebrew/gmail-gateway-sender-${version}-darwin-x64.tar.gz"
)
for asset in "${assets[@]}"; do
  test -f "$asset"
  test -f "$asset.sha256"
done
gh release upload "v${version}" "${assets[@]}" --repo user/repo --clobber
```

After uploading, run `gh release view "v${version}" --repo user/repo --json assets`
and confirm all six command archives are present.

## Verification

From the tap checkout:

```bash
ruby -c Formula/gmail-gateway-reader.rb
ruby -c Formula/gmail-gateway-draft.rb
ruby -c Formula/gmail-gateway-sender.rb
brew audit --strict --formula user/tap/gmail-gateway-reader
brew audit --strict --formula user/tap/gmail-gateway-draft
brew audit --strict --formula user/tap/gmail-gateway-sender
brew fetch --formula user/tap/gmail-gateway-reader
brew fetch --formula user/tap/gmail-gateway-draft
brew fetch --formula user/tap/gmail-gateway-sender
brew install user/tap/gmail-gateway-reader
brew install user/tap/gmail-gateway-draft
brew install user/tap/gmail-gateway-sender
brew test user/tap/gmail-gateway-reader
brew test user/tap/gmail-gateway-draft
brew test user/tap/gmail-gateway-sender
```

If online audit fails because of local GitHub credentials or rate limits, run a
non-online audit and report the limitation.

Formula tests should use a stable command surface. Prefer `--help` unless all
three command executables intentionally expose a shared `--version` contract.
If existing local installs conflict during verification, upgrade or reinstall the
specific Formula being checked; do not uninstall unrelated Formulae.

## Tap API Metadata Gate

After pushing the three Formula files, require `tacogips/homebrew-tap`'s
`update-api-metadata.yml` workflow to succeed for that commit. Verify the
GitHub Raw JSON for `gmail-gateway-reader`, `gmail-gateway-draft`, and
`gmail-gateway-sender`. Each `.versions.stable` must equal the release version,
and each `.ruby_source_checksum.sha256` must equal the SHA-256 of its committed
Formula. Do not consider the release complete while any endpoint is missing or
stale.
