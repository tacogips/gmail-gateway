# References

Store external references, product notes, API links, and research material here.

Reference files should be cited from design documents in `design-docs/specs/`.

## Local Behavioral References

- `/Users/taco/gits/tacogips/google-documents-gateway` — shared per-executable
  auth commands, immutable role/scope enforcement, PKCE, atomic token files,
  redacted status, confirmed revoke, and XDG state-path behavior.
- `/Users/taco/gits/tacogips/google-service-gateway` (reviewed tag `v0.1.1`,
  package URL `https://github.com/tacogips/google-service-gateway.git`) —
  `SecureCredentialStore`, `KeychainCredentialStore`, `OAuthCredentialVault`,
  secure client/token persistence, environment-free auth tests, and Desktop
  client fixtures using the legacy `/o/oauth2/auth` authorization path.

These repositories are behavioral and structural references. Their source is
not copied into this repository, and product-specific CLI or storage identities
are not shared.
