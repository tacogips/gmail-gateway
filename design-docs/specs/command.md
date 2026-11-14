# Command

## Status

Current implementation

## Binaries

The package ships five user-facing executables:

- `gmail-gateway-reader`: read-only GraphQL and local file/cache/auth commands
- `gmail-gateway-draft`: read plus draft-oriented write mutations
- `gmail-gateway-sender`: read plus explicit direct-send mutations
- `gmail-gateway-threads`: stored-mail and label mutations
- `gmail-gateway-message-box`: RFC 822 mail ingestion

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
credential declarations. For reader, sender, and draft, a missing synthesized
OAuth-client file is valid only when the matching provider, credential ID, and
access-mode profile contains a valid client in the injected Keychain vault. An
empty or mismatched vault fails validation. Explicit environment or TOML paths
remain authoritative and do not fall through to Keychain.

### Auth

For `gmail-gateway-reader`, `gmail-gateway-sender`, and
`gmail-gateway-draft`:

```bash
<binary> auth setup --credential <id> --client-secret-path <path>
                    [--replace --confirm-credential <id>]
<binary> auth login --credential <id>
<binary> auth status --credential <id>
<binary> auth revoke --credential <id> --confirm-credential <id>
```

For `gmail-gateway-threads` and `gmail-gateway-message-box`, the existing
contract remains:

```bash
<binary> auth login --credential <id>
<binary> auth status --credential <id>
<binary> auth revoke --credential <id>
```

`auth setup` and confirmed revocation are available only to the target
persistent-auth executables: `gmail-gateway-reader`,
`gmail-gateway-sender`, and `gmail-gateway-draft`. Setup imports a Desktop OAuth
client into secure storage, login persists mode-bound token state, status is
local and redacted, and revoke removes only the selected token.
`gmail-gateway-threads` and `gmail-gateway-message-box` do not expose setup and
retain their existing login, status, unconfirmed revoke, and token behavior. See
[design-persistent-auth-commands.md](./design-persistent-auth-commands.md) for
source precedence, access-mode binding, replacement safety, and rollout rules.

`auth login` supports:

- `--redirect-uri <uri>` for an explicit loopback callback URI
- `--open-browser <true|false>` to control automatic browser launch
- `--timeout-seconds <n>` for the OAuth callback wait

An explicit redirect must match a validated redirect stored with the Desktop
OAuth client. When omitted, the first validated stored redirect is used. Login
preserves the selected `127.0.0.1`, `::1`, or `localhost` host, fixed or dynamic
port semantics, and callback path in both authorization and token exchange. A
`localhost` callback is advertised only after every locally resolved loopback
address family is listening on the same effective port; partial binding fails
before browser launch without hostname rewriting.

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
