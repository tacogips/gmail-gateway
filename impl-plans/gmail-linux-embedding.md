# Gmail SDK inside Linux workflow guests

GmailGatewayCore and every CLI target now compile on Linux. Swift Crypto supplies
SHA-256 there; macOS keeps CryptoKit and Security. Linux uses the system CSPRNG.
The small C platform boundary maps exclusive token moves to renameat2 with
RENAME_NOREPLACE; macOS keeps renameatx_np with RENAME_EXCL. No non-atomic fallback
is allowed. Existing token journal, parent-directory fsync, source-identity and
credential-tier checks remain in the core.

The synchronous CLI bridge prefers a dispatch-backed TaskExecutor on Linux and
macOS15+, preventing eight blocking callers from starving its async executor.
macOS14 retains its previous bridge. Embedded runtimes should call the async SDK.

Verification (2026-10-23):

- macOS: swift test, 204 XCTest and185 Swift Testing cases; smoke executable passed.
- Linux arm64, Swift6.2 Ubuntu24.04: all targets compiled,203 XCTest cases passed
  with swift test --parallel --num-workers1 --disable-swift-testing.
- All185 Swift Testing functions exercised in individual processes with
  --testing-library swift-testing --no-parallel --filter;184 initially passed,
  and the response-plus-error case passed after recording FoundationNetworking's
  safe unknown-mutation-outcome behavior. Every filter matched a test.
- Linux real subprocess credential lock, journal crash safety, no-overwrite
  collision and fixed SHA/nil-project fingerprint vectors passed. Linux smoke passed.
- The eight-caller bridge regression passed with only two Linux CPUs and on macOS.
- SwiftLint completed with existing warnings; git diff --check passed.
- Actual Claude Opus5.5 reviewed portability, atomic moves, and the bridge separately;
  compile findings were corrected and the errno assertion captures errno immediately.

Linux's shared URLSession retains registered test protocols. Consequently these
legacy global-interceptor fixtures need process isolation; the ordinary in-process
Linux suite is not a passing check. No gateway credentials or live Gmail data were
used. Detailed local evidence lives in ignored tmp/linux-portability/.

Riela must pin this source revision, enable its Linux product dependency and use
GmailGatewaySDK.execute. ART native Gmail workflows and App deployment are subsequent
steps; this source change alone does not deploy ART.
