# gmail-gateway

Swift command-line gateway for Gmail workflows

## Development

```bash
mise install
mise run build
mise run test
swift run gmail-gateway-reader --help
swift run gmail-gateway-draft --help
swift run gmail-gateway-sender --help
```

The package uses Swift Package Manager with:

- Library target: `GmailGatewayCore`
- Executable targets: `GmailGatewayReader`, `GmailGatewayDraft`, `GmailGatewaySender`
- Installed executables: `gmail-gateway-reader`, `gmail-gateway-draft`, `gmail-gateway-sender`

Swift target names and type names must be valid Swift identifiers. If the project
name contains hyphens, keep `PROJECT_NAME` and `EXECUTABLE_NAME` hyphenated as
needed, but use identifier-safe values such as `GmailGatewayCore` and
`GmailGatewayReader` for Swift module/type variables.

## Homebrew Formula

Build local formula archives:

```bash
mise run build:homebrew -- darwin-arm64 darwin-x64
```

Render formulae after both platform archives exist:

```bash
mise run homebrew:formula -- 0.1.2
```

Render directly into the default sibling tap checkout:

```bash
mise run homebrew:tap-formula -- 0.1.2
```

Install from the tap after the formula is published:

```bash
brew tap tacogips/tap
brew install gmail-gateway-reader
brew install gmail-gateway-draft
brew install gmail-gateway-sender
```

See `packaging/homebrew/README.md` and `.agents/skills/` for release workflows.
