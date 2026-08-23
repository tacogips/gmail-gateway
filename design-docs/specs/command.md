# Command

## Status

Current implementation

## Binaries

The package ships three user-facing executables:

- `gmail-gateway-reader`: read-only GraphQL and local file/cache/auth commands
- `gmail-gateway-draft`: read plus draft-oriented write mutations
- `gmail-gateway-sender`: read plus explicit direct-send mutations

Each binary accepts the same command surface:

```bash
<binary> [--config <path>] [--pretty] <command>
<binary> --help
<binary> --version
<binary> version
```

`--config <path>` overrides the default config path. `GMAIL_GATEWAY_CONFIG` is
also honored when the flag is omitted. `--pretty` formats JSON output where the
command returns JSON.

## Commands

### Doctor

```bash
<binary> doctor
```

Checks the resolved config source, whether supported environment overrides are
set and selected, OAuth client readiness, configured access modes, token-store
authentication state, and authenticated account identity. The command does not
make a network request and never prints environment-variable values. It exits
with status `0` when all checks pass, `3` for configuration problems, or `4`
when only authentication needs attention.

### GraphQL

```bash
<binary> graphql --query <query>
<binary> graphql --query-file <path>
```

Runs a one-shot GraphQL operation. The reader binary exposes read-only schema
behavior. The draft binary treats `sendMessage` as draft creation. The sender
binary treats `sendMessage` as direct send and also supports draft creation.

GraphQL responses expose message, body, attachment, and temporary-file metadata
with `downloadKey` values, not payload bytes or local paths.

Exactly one of `--query` or `--query-file` is required. `--variables` and
`--variables-file` are rejected with a "not supported" error until a full
GraphQL execution engine is adopted.

### Config

```bash
<binary> config validate
```

Loads and validates TOML configuration, account references, storage paths, and
credential declarations.

### Auth

```bash
<binary> auth login --credential <id>
<binary> auth status --credential <id>
<binary> auth revoke --credential <id>
```

`auth login` supports:

- `--redirect-uri <uri>` for an explicit loopback callback URI
- `--open-browser <true|false>` to control automatic browser launch
- `--timeout-seconds <n>` for the OAuth callback wait

### Cache

```bash
<binary> cache prune [--account <id>|--all]
```

Removes cached local files for one account or all accounts.

### File

```bash
<binary> file download --key <download-key> [--key <download-key> ...] [--output-dir <dir>]
```

Downloads selected body, attachment, or temporary-file payloads addressed by
GraphQL `downloadKey` metadata. Repeating `--key` performs a batch download and
copies files under `<output-dir>/<accountId>/<messageId>/<filename>` to avoid
collisions. Single-key output includes the materialized `localPath`; GraphQL
metadata does not.
