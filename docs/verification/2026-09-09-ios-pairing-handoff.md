# iOS pairing handoff investigation — 2026-09-09

## Scope and non-completion

The required acceptance remains fresh-device recovery of passwords, cards, notes,
documents, files and media, durable decryption, matching revisions and complete
remote batches, followed by both iOS release gates. This note is not acceptance.

## Observed evidence

- Dedicated recovery simulator: EA9A8C79-0ED3-4E97-8D93-B0EADC70631B.
- Recovery-card account import passed in the retained test results at
  `ui_test_results/cross-app-20260909T025526Z-37633/replica-recover-account.log`.
- Subsequent pairing failed because the approval control never appeared.
- A pairing-only retry preserved both app sandboxes and the recovered account.
- The real exchange group contains the request created at
  `2026-09-09T03:05:19.416407Z`; it was not a failure to write the request.
- Unified simulator log at 2026-09-09 11:06:05.527 +08:00 reports failure to open
  the pairing URL, NSOSStatusErrorDomain -10826, originating in
  `_LSSchemeApprovalPromptWithCompletionHandler_block_invoke_2`.
- The harness previously waited 20 seconds then activated Velock directly. That
  is not evidence that iOS delivered the request URL and can interrupt consent.

## Changes under verification

- Harness now handles the system Open consent and requires real foreground
  handoff; it does not replace URL delivery with direct activation.
- Failed handoff/approval captures actual UI state and exits that test instead
  of tapping nonexistent approval controls and generating misleading failures.
- Apple pairing channel now checks the launch result; false throws instead of
  reporting a pending handoff. No response, approval or consumed marker is
  synthesized.
- Apple pairing channel regression suite: 7 tests passed, including rejected
  launch. This does not prove the end-to-end flow.

## Still required

Re-run pairing UI, then actual download/import, persisted/decryptable six-type
recovery and revision/remote coverage checks. Release readiness is not proven.

## Follow-up: wrong-vault oracle and original-card recovery (11:41 CST)

Pairing-only passed previously, but the replica's vault was
`fa581829-4685-482b-8be6-878e10b3b411` and business tables were empty.
That is **not** recovery acceptance.

Decoded the original source-card PNG using Apple's Vision QR reader, then
locally authenticated/decrypted its Sync extension without printing secrets.
It contains source vault `d25a3744-f540-45fe-a9f8-5573b68f72f6`.
The retained Photos picker contains newer registration/recovery cards; importing
an old image does not make that historical asset the first tile. A byte-identical
fresh-dated copy was observed as the first tile and imported through the real UI.

Recovery initially failed because an existing sandbox had the same display name.
A Dart debugger breakpoint caught `VenyoreError` code 1017 (`Name already exists`).
No simulator or account was erased. Changed only the new recovery form's display
name to `Velock E2E Replica Restored`, submitted via UI, and observed the dashboard.
Read-only DB inspection now shows sandbox 2 with the original source vault and
new device `f0e1d909-77d8-459a-ae01-1947652b0150`. The old unrelated sandbox remains.
The selected-space identity gate passed before pairing.

Harness changes: preserve old image bytes but refresh import filesystem dates;
require identity match before re-pairing; query the selected sandbox rather than
mixing entities from multiple retained spaces; refuse registration fallback in
recovery mode; require the recovery form to disappear, not merely a loose Settings
match. Replica-only runs no longer try installing on the shutdown source; source
containers are resolved read-only without booting it. Python oracle tests: 12 pass.

Pending: downloaded/imported business content, decrypt/open checks, restart
persistence, revision convergence, and final release gates. This is not a release
approval and not a clean-install recovery acceptance: the original-card UI recovery
was performed alongside an existing retained empty sandbox.

## Final verification update (2026-09-09)

The retained recovery副本 was not reset. The full post-restart content inspection
now passes for password, card, note, file, media, and document. The selected
recovered sandbox converged with the source on the five revision-tracked
collections (card=2, document=1, file=3, note=2, password=6); the sync run and
remote-coverage checks also pass. CrossAppUITests passed 1/1 for the restart
inspection flow. Sync has 285 Flutter tests passing and 格间 has 685 Flutter tests
passing; both analyzers report no issues.

Both iOS projects also produce Release archives with signing disabled:

- `/tmp/velock-archives/velock-sync.xcarchive`
- `/tmp/velock-archives/velock-codex.xcarchive`

Those archives prove the Release compilation/archive pipeline, but are **not
App Store upload artifacts**. On 2026-09-09 this Mac has no provisioning profiles
under `~/Library/MobileDevice/Provisioning Profiles`, and the archived apps have
no code signature. A signed App Store archive/export therefore remains blocked
until Apple Distribution signing is available for the following identifiers:

- `tech.windata.velock`
- `tech.windata.velock.sync`
- `tech.windata.velock.vactionextension`
- `tech.windata.velock.vshareextension`
- `tech.windata.velock.credentialprovider`

Do not treat the simulator/debug runs or unsigned archives as App Store release
approval. No simulator reset, database seeding, or destructive E2E cleanup was
used for this final verification.

## Signing follow-up (2026-09-09)

Retried both Release archives with `-allowProvisioningUpdates`. Xcode was able
to obtain/use development signing automatically:

- `/tmp/velock-archives/velock-sync-signed.xcarchive` — archive succeeded;
  signed with `Apple Development: Yi Tan (873KD94Z8D)` and an iOS Team
  Provisioning Profile for `tech.windata.velock.sync`.
- `/tmp/velock-archives/velock-codex-signed.xcarchive` — archive succeeded;
  the main app and embedded extensions were signed with the same development
  identity/profile family.

This is useful evidence that both Release builds and all embedded extensions
are structurally archivable and signable on this Mac. It is still not App Store
readiness: a development identity/profile cannot be exported as an App Store
submission. Apple Distribution signing and distribution profiles are still
required.

## App Store export gate (2026-09-09)

An actual `xcodebuild -exportArchive` using `method=app-store` was attempted for
`velock-codex-signed.xcarchive`. It failed with the authoritative Xcode error:

`exportArchive No signing certificate "iOS Distribution" found`

The machine does have four Xcode-managed “Store Provisioning Profile” files for
the 格间 app and its three extensions, but no matching Apple Distribution/iOS
Distribution signing identity. The remaining release blocker is therefore
specifically the distribution certificate/private key in the login keychain (and
then exporting both archives with the Store profiles). The code and archive
pipeline cannot resolve or generate that private signing key autonomously.
