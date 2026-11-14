---
name: gmail-gateway-setup
description: Configure and verify Gmail OAuth for this mail-gateway repository. Use when setting up Gmail API access, registering Google OAuth client or token JSON in kinko, validating no-config default startup, running auth login/status, using gcloud/Google Cloud Console for OAuth clients, or proving live Gmail retrieval through mail-gateway-reader.
---

# Gmail Gateway Setup

## Workflow

Use the repository root, not `Sources/`, for commands.

Prefer `direnv exec .` for commands that need kinko secrets because `.envrc` runs `kinko direnv export`.

## Defaults

`~/.config/mail-gateway/config.toml` is optional. When the implicit default config is missing, the reader should synthesize:

- credential id: `gmail-personal`
- account id: `personal`
- OAuth client path fallback: `~/.config/mail-gateway/google-client.json`
- token store path fallback: `~/.config/mail-gateway/tokens/gmail-personal.json`

Explicit missing config paths via `--config` or `MAIL_GATEWAY_CONFIG` should still fail.

Verify no-config startup:

```bash
swift run mail-gateway-reader config validate --pretty
swift run mail-gateway-reader auth status --credential gmail-personal --pretty
```

## kinko Keys

Use kinko for credentials. For `gmail-personal`, the supported keys are:

```text
MAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_OAUTH_CLIENT_SECRET_PATH
MAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_TOKEN_STORE_PATH
MAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_OAUTH_CLIENT_SECRET_JSON
MAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_TOKEN_STORE_JSON
```

Path keys are useful fallbacks; JSON keys avoid requiring local credential files. Never print the values. To check key presence only:

```bash
kinko direnv export 2>/dev/null \
  | rg 'MAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_(OAUTH_CLIENT_SECRET|TOKEN_STORE)_(PATH|JSON)' \
  | sed -E "s/^(export [^=]+)=.*/\1=[redacted]/"
```

To import a downloaded Google OAuth client JSON without printing it:

```bash
json_file="$HOME/Downloads/client_secret_...json"
tmp=$(mktemp)
ruby -e 'json = File.read(ARGV[0]); escaped = json.gsub("'"'"'", "'"'"'\\'"'"''"'"'"); puts "MAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_OAUTH_CLIENT_SECRET_JSON='"'"'#{escaped}'"'"'"' "$json_file" > "$tmp"
kinko import sh --file "$tmp" -y
rm -f "$tmp"
```

After `auth login`, register the token JSON similarly as `MAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_TOKEN_STORE_JSON`.

Verify JSON values are not shell-escaped literals:

```bash
direnv exec . sh -c 'printf %s "$MAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_OAUTH_CLIENT_SECRET_JSON" | head -c 4 | od -An -tx1'
```

The prefix should start with `7b 22`, meaning `{ "`.

## Google Cloud

Use gcloud where possible:

```bash
gcloud auth list
gcloud config get-value project
gcloud services enable gmail.googleapis.com --project <project-id>
```

Use Computer Use in Brave for Google Auth Platform setup that gcloud cannot fully handle for this desktop Gmail OAuth flow:

1. Configure OAuth app branding/consent for the project.
2. Use External testing mode for a local CLI unless the project policy requires otherwise.
3. Create an OAuth client with application type `Desktop app`.
4. Download the JSON from the client dialog.

Do not accept legal/user-data policy checkboxes on the user's behalf unless the user explicitly confirms acceptance.

## Login And Live Verification

Run login with kinko-loaded env:

```bash
direnv exec . swift run mail-gateway-reader auth login --credential gmail-personal --pretty
```

Complete the Google OAuth consent in Brave for the signed-in account. The requested scope should be Gmail read-only.

Verify ready auth:

```bash
direnv exec . swift run mail-gateway-reader auth status --credential gmail-personal --pretty
```

For live checks, avoid dumping mail contents. Prefer count-only or cursor-only queries:

```bash
direnv exec . swift run mail-gateway-reader graphql \
  --query '{ threads(input: { accountId: "personal" }) { totalCount } }' \
  --pretty

direnv exec . swift run mail-gateway-reader graphql \
  --query '{ threads(input: { accountId: "personal" }) { totalCount edges { cursor } } }' \
  --pretty
```

If validating kinko token JSON rather than the token file, override the token path to a nonexistent value while leaving `TOKEN_STORE_JSON` loaded:

```bash
direnv exec . env MAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_TOKEN_STORE_PATH=/tmp/mail-gateway-token-does-not-exist.json \
  swift run mail-gateway-reader graphql \
  --query '{ threads(input: { accountId: "personal" }) { totalCount } }' \
  --pretty
```

## Final Checks

Before handoff, run:

```bash
swift build
swift run mail-gateway-swift-smoke-tests
task ci
git diff --check
```
