# mail-gateway

Swift command-line gateway for Gmail workflows

## Development

```bash
nix develop
task build
task test
swift run mail-gateway-reader --help
swift run mail-gateway-draft --help
swift run mail-gateway-sender --help
```

The package uses Swift Package Manager with:

- Library target: `MailGatewayCore`
- Executable targets: `MailGatewayReader`, `MailGatewayDraft`, `MailGatewaySender`
- Installed executables: `mail-gateway-reader`, `mail-gateway-draft`, `mail-gateway-sender`

Swift target names and type names must be valid Swift identifiers. If the project
name contains hyphens, keep `PROJECT_NAME` and `EXECUTABLE_NAME` hyphenated as
needed, but use identifier-safe values such as `MailGatewayCore` and
`MailGatewayReader` for Swift module/type variables.

## Homebrew Formula

Build local formula archives:

```bash
task build:homebrew -- darwin-arm64 darwin-x64
```

Render formulae after both platform archives exist:

```bash
task homebrew:formula -- 0.1.2
```

Render directly into the default sibling tap checkout:

```bash
task homebrew:tap-formula -- 0.1.2
```

Install from the tap after the formula is published:

```bash
brew tap tacogips/tap
brew install mail-gateway-reader
brew install mail-gateway-draft
brew install mail-gateway-sender
```

See `packaging/homebrew/README.md` and `.agents/skills/` for release workflows.
