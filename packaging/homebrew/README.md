# Homebrew Packaging

This project ships split Homebrew Formula releases:

- Formula: unsigned tarballs containing one command each:
  `bin/mail-gateway-reader`, `bin/mail-gateway-draft`, or
  `bin/mail-gateway-sender`.

Swift formula archives are macOS-only by default. Add Linux archives only after
the project has a reviewed Swift Linux build and runtime contract.

## Formula

Build release archives:

```bash
scripts/build-homebrew-release.sh darwin-arm64 darwin-x64
```

The command writes archives and checksums under `dist/homebrew/`:

```text
dist/homebrew/mail-gateway-reader-<version>-darwin-arm64.tar.gz
dist/homebrew/mail-gateway-reader-<version>-darwin-arm64.tar.gz.sha256
dist/homebrew/mail-gateway-reader-<version>-darwin-x64.tar.gz
dist/homebrew/mail-gateway-reader-<version>-darwin-x64.tar.gz.sha256
dist/homebrew/mail-gateway-draft-<version>-darwin-arm64.tar.gz
dist/homebrew/mail-gateway-draft-<version>-darwin-arm64.tar.gz.sha256
dist/homebrew/mail-gateway-draft-<version>-darwin-x64.tar.gz
dist/homebrew/mail-gateway-draft-<version>-darwin-x64.tar.gz.sha256
dist/homebrew/mail-gateway-sender-<version>-darwin-arm64.tar.gz
dist/homebrew/mail-gateway-sender-<version>-darwin-arm64.tar.gz.sha256
dist/homebrew/mail-gateway-sender-<version>-darwin-x64.tar.gz
dist/homebrew/mail-gateway-sender-<version>-darwin-x64.tar.gz.sha256
```

Publish those assets to the GitHub release named `v<version>`, then render the
formula into a tap checkout:

```bash
scripts/render-homebrew-formula.sh <version> ../homebrew-tap/Formula
```

## Verification

From the tap checkout:

```bash
for formula in mail-gateway-reader mail-gateway-draft mail-gateway-sender; do
  ruby -c "Formula/$formula.rb"
  brew audit --strict --formula "tacogips/tap/$formula"
done
```

If online audit fails due local GitHub credentials or rate limits, run the
non-online audit and record the limitation.
