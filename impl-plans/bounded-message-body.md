# Explicit bounded message body transfer

Issue #5: ART receives only snippets because existing `message`/`thread` deliberately
return null textBody/htmlBody. Preserve that user-approved file-only API. Add
`messageBodyBytes` as explicit reader capability for isolated inspection pipes.

Read exact fixed Gmail message endpoint in full format (32 MiB streamed cap).
Traverse at most 10,000 MIME nodes/depth 64; exclude filename-bearing attachments
and their descendants. Return at most64 text/plain/text/html body parts with
original charset, exact bytes/count/SHA256 and part IDs. External body attachment
IDs use bounded fixed Gmail endpoints only. Total decoded bytes default2MiB,
maximum8MiB. Any malformed/missing/ambiguous/over-limit part fails the entire call;
`complete=true` means no qualifying part was dropped, not that text exists or
has passed inspection. An empty parts list remains body-unavailable to callers.
No file writes, automatic retries, new OAuth scopes, or real provider tests.

Verify nested alternatives, attached text exclusion, external body retrieval,
wrong identity, malformed/ambiguous/duplicate parts, cumulative byte bounds,
pre-cancelled zero dispatch, SDK/CLI registration and unchanged null legacy fields.
Use the existing ephemeral mocked transport seam; no shared URLProtocol globals
or real credentials. Publish0.1.24 after full tests/smoke/lint and peer review.
