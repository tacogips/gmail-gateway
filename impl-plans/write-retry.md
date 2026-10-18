# Bounded write retries (0.1.22)

User requested configurable initial wait and maximum retries across gateway writes. Use per-config immutable typed policy, TOML/environment overrides, default2seconds/3retries, n1...60/m0...5, exponential60second cap. Retry only confirmed429/documented quota403 rejection or preconnection errors; decline mutation redirects so a later connection failure cannot hide the original write. Never replay ambiguous5xx/timeout/lost response or a confirmed write merely because parsing/readback failed. Preserve all existing permissions/read/OAuth behavior. Honor Retry-After minimums; stop if above cap. Request-scoped deadlines and cancellation prevent later attempts.

Validate real URLSession paths with local URLProtocol fixtures, fake backoff/deadline clocks, config integration, exact attempt budget, quota vs permission, transient connection vs ambiguous dispatch, and no duplicate write after success. Full tests/build/lint and both macOS release archives are required before publication; no live provider writes are used.

Validation: full XCTest and 185 Swift Testing tests passed, including 12 retry/config/deadline fixtures; Swift smoke executable passed. SwiftLint retains only five existing warnings. Independent Apple gateway maintainer review found no blocker. No live provider writes were performed. Nix validation is unavailable on this host (no nix executable or flake definition); the maintained release surface is the five split macOS Formula commands.

## Completed release verification

- Immutable `v0.1.22` source: `185cba5396d8afa43919f735c9329eb477b17418`.
- `arch -arm64 swift test`: 173 XCTest and 185 Swift Testing tests passed; Swift smoke executable passed.
- All five command archives for both macOS architectures passed SHA-256, extracted binary version, and help checks. All 20 GitHub release asset digests match local files.
- All five Formulae passed strict Homebrew audit, fetch, upgrade, and tests. Tap change: `1ece8122b94ec08b0f950c8c1b46f91dfcea4d55`; metadata workflow `39131449964` succeeded. Immutable metadata `8a8dd3916c1b3d41e5dce03c00ca43b3b0041f69` reports the expected versions and Formula SHA-256 values.
- GitHub gitleaks passed. Raw Linux workflow `39130685601` still fails on the pre-existing `GmailCredentialResolution.swift` CryptoKit import; this release's archive surface is macOS. Riela uses its existing Linux reader adaptation.
- No live provider writes or container/image operations were performed.
