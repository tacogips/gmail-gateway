# Architecture

## Status

Current implementation

## Overview

`gmail-gateway` is a Swift Package Manager project with a reusable core library,
three user-facing CLI executables, a smoke-test executable, package tests, and
Homebrew formula release automation.

## Targets

- `GmailGatewayCore`: domain models, config loading, Gmail integration, GraphQL
  command execution, auth helpers, cache/file commands, and write services
- `GmailGatewayReader`: read-only CLI entry point for `gmail-gateway-reader`
- `GmailGatewayDraft`: draft-mode CLI entry point for `gmail-gateway-draft`
- `GmailGatewaySender`: direct-send CLI entry point for `gmail-gateway-sender`
- `GmailGatewaySwiftSmokeTests`: executable smoke tests for CLI workflows
- `GmailGatewayCoreTests`: Swift package tests stored under
  `Tests/GmailGatewayCoreTests`

## Provider Boundary

`GmailGatewayCore` routes provider operations through the internal
`MailProviderAdapter` protocol. `GmailProviderAdapter` is the current adapter
and owns the direct `GmailLiveReader` / `GmailLiveWriter` calls; reader and
writer services depend on the adapter protocol instead of constructing Gmail
clients directly.

## Release Surfaces

- Split Homebrew formula archives under `dist/homebrew/`
- Rendered formula files for the tap under `Formula/`
