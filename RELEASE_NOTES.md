# gmail-gateway 0.1.12

## Persistent Gmail OAuth Authentication

Reader, sender, and draft now provide `auth setup`, `auth login`, `auth
status`, and confirmed local `auth revoke`. Setup and tokens are stored in the
Gmail-specific macOS Keychain service, so macOS may prompt for Keychain access.

Explicit environment JSON, environment paths, and configured credential paths
continue to take precedence over the secure profile. Legacy target-mode tokens
without exact scope metadata and the OAuth-client fingerprint need one
intentional re-login. Threads and message-box remain legacy-only; no writer
binary or alias was added.
