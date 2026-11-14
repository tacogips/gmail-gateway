# Gmail Credentials For Mail Gateway

This document summarizes which Google credentials are required to use Gmail with this project and how they map to the mail-gateway configuration model.

## Overview

For this project, Gmail access uses Google's installed-app OAuth 2.0 flow.

The required credential set is:

1. A Google Cloud project
2. The Gmail API enabled in that project
3. An OAuth consent screen configured for the project
4. An OAuth 2.0 Client ID for a Desktop app
5. The downloaded OAuth client JSON file stored locally
6. A local token store file created after user login

An API key is not sufficient for mailbox access because Gmail data is private user data and the gateway must act on behalf of a signed-in user.

## Required Google-Side Credentials

### 1. Google Cloud Project

You need a Google Cloud project that owns the OAuth client and consent screen configuration.

This project is the unit that contains:

- enabled APIs
- OAuth consent screen settings
- OAuth client credentials
- verification state for requested scopes

### 2. Gmail API Enabled

The Gmail API must be enabled for the Cloud project before OAuth tokens can be used against Gmail API endpoints.

### 3. OAuth Consent Screen

You must configure the OAuth consent screen for the same Cloud project.

At minimum, this controls:

- app name and branding shown to users
- test-user access during development when the app is not yet verified
- declared scopes on the Google Auth platform / consent configuration

The consent screen configuration must match the scopes the application actually requests.

### 4. OAuth 2.0 Client ID For Desktop App

For this repository, the correct Google credential type is an OAuth 2.0 Client ID with application type `Desktop app`.

This is the credential Google expects for a local CLI or desktop-style installed application that opens a browser for user consent and receives the OAuth callback locally.

The downloaded JSON file from Google Cloud is the file referenced by:

- `credentials[].oauth_client_secret_path`
- `MAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_OAUTH_CLIENT_SECRET_PATH`
- `MAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_OAUTH_CLIENT_SECRET_JSON`

Despite the field name used by this repository, the file is the OAuth client JSON downloaded from Google Cloud for the Desktop app client.

## Required Local Credential Artifacts

### 5. OAuth Client JSON File

The OAuth client JSON file is downloaded once from Google Cloud and stored on the local machine.

The gateway needs it to start the installed-app OAuth flow.

The file should:

- be stored outside the repository
- be readable only by the local user where practical
- never be returned in GraphQL responses
- never be committed to git

### 6. Token Store File

After the user authorizes the app, the gateway stores token material in a local token store file referenced by:

- `credentials[].token_store_path`
- `MAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_TOKEN_STORE_PATH`
- `MAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_TOKEN_STORE_JSON`

This file is not created in Google Cloud. It is created locally by the application after login and typically contains:

- access token
- refresh token when granted
- expiry metadata
- granted scope or access-mode metadata

The token store is per credential or per principal and must not be shared across unrelated accounts.

## Minimum Scopes For This Project

The repo design currently distinguishes these access modes:

### `access_mode = "read"`

Use:

- `https://www.googleapis.com/auth/gmail.readonly`

This supports reading messages and message bodies for the Phase 1 reader binary.

### `access_mode = "read_send"`

Use:

- `https://www.googleapis.com/auth/gmail.readonly`
- `https://www.googleapis.com/auth/gmail.compose`
- `https://www.googleapis.com/auth/gmail.send`

This is the recommended minimum for the currently planned Phase 2 capability set: read mail, create Gmail drafts, and send new outbound messages.

### Scopes To Avoid By Default

Do not request broader scopes unless the product actually needs them:

- `https://www.googleapis.com/auth/gmail.modify`
- `https://mail.google.com/`

For the current design, those are broader than necessary.

This is partly an implementation recommendation based on the repository's current scope model and partly a policy recommendation from Google to request the least-privileged scopes needed.

## Sensitivity And Verification Impact

The current Google documentation classifies:

- `gmail.send` as Sensitive
- `gmail.compose` as Sensitive
- `gmail.readonly` as Restricted
- `gmail.modify` as Restricted
- `mail.google.com` as Restricted

Practical impact:

- local testing may work with an unverified app and test users
- broader rollout may require OAuth verification
- restricted scopes have stricter review requirements than sensitive scopes
- if a system stores or transmits restricted-scope data from servers, Google documents additional security-assessment requirements

For this repository's local CLI design, the safest default is still to minimize scopes and keep credential and token files local.

## Mapping To Repository Config

Example:

```toml
[[credentials]]
id = "gmail-personal"
provider = "gmail"
access_mode = "read"
oauth_client_secret_path = "~/.config/mail-gateway/google-client.json"
token_store_path = "~/.config/mail-gateway/tokens/personal.json"
```

Interpretation:

- `provider = "gmail"` means the Gmail adapter will be used
- `access_mode` controls which Gmail scopes the app should request
- `oauth_client_secret_path` points to the downloaded Desktop app OAuth client JSON when present in TOML
- `token_store_path` points to the locally generated token store when present in TOML
- `MAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_...` env vars may supply the same paths or JSON values without putting them in `config.toml`
- if both TOML and env are set, the environment variable wins

## Setup Checklist

1. Create or select a Google Cloud project
2. Enable the Gmail API for that project
3. Configure the OAuth consent screen
4. Create an OAuth client with application type `Desktop app`
5. Download the client JSON and store it locally
6. Put the local JSON path into `credentials[].oauth_client_secret_path` or `MAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_OAUTH_CLIENT_SECRET_PATH`
7. Choose `access_mode = "read"` or `access_mode = "read_send"`
8. Set `credentials[].token_store_path` or `MAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_TOKEN_STORE_PATH` to a local writable path
9. Run `mail-gateway-reader auth login --credential <id>`
10. Verify the result with `mail-gateway-reader auth status --credential <id>`

## Notes

- The current implementation completes installed-app Gmail OAuth login and validates the token with the Gmail profile API. Live message retrieval is still outside the implemented baseline.
- The credential requirements in this document describe the intended production setup for the Gmail adapter.
- The recommendation to use `gmail.readonly`, `gmail.compose`, and `gmail.send` for `read_send` follows the current repository design: read access remains necessary, draft creation requires compose access, and direct sending requires send access.
- Attachment transport remains file-path based; this document does not require any Gmail-side credential for inline attachment payloads because that feature is intentionally out of scope.

## References

See `design-docs/references/README.md` for external references.
