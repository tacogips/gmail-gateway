# Architecture

## Status

Current implementation

## Overview

`mail-gateway` is a Swift Package Manager project with a reusable core library,
three user-facing CLI executables, a smoke-test executable, package tests, and
Homebrew formula release automation.

## Targets

- `MailGatewayCore`: domain models, config loading, Gmail integration, GraphQL
  command execution, auth helpers, cache/file commands, and write services
- `MailGatewayReader`: read-only CLI entry point for `mail-gateway-reader`
- `MailGatewayDraft`: draft-mode CLI entry point for `mail-gateway-draft`
- `MailGatewaySender`: direct-send CLI entry point for `mail-gateway-sender`
- `MailGatewaySwiftSmokeTests`: executable smoke tests for CLI workflows
- `MailGatewayCoreTests`: Swift package tests stored under
  `Tests/MailGatewayCoreTests`

## Provider Boundary

`MailGatewayCore` routes provider operations through the internal
`MailProviderAdapter` protocol. `GmailProviderAdapter` is the current adapter
and owns the direct `GmailLiveReader` / `GmailLiveWriter` calls; reader and
writer services depend on the adapter protocol instead of constructing Gmail
clients directly.

## Release Surfaces

- Split Homebrew formula archives under `dist/homebrew/`
- Rendered formula files for the tap under `Formula/`
