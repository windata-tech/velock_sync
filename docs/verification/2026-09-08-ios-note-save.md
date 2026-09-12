# iOS incremental acceptance — note save

Source simulator: 26CC5821-DEF4-47D3-978D-A11D7293AD61.
No simulator erasure or account re-creation performed.

## Confirmed defect and fix

Note Save was blocked by `FormatException: Inbound batch has an invalid producer.`
The Inbox envelope's vault and source device matched the local sync identity:
an echoed own-device backup was treated as an error before local note persistence.
Runtime now skips own-device envelopes without importing, acknowledging or advancing
inbound cursors; foreign-vault and remote producer checks remain unchanged.

Regression: `flutter test test/sync/sync_password_importer_integration_test.dart`
passed, including a self-echo alongside a valid remote producer, no echo receipt,
and predecessor rejection.

## Simulator evidence

Build: `flutter build ios --simulator --debug --dart-define=VELOCK_E2E_FIXTURES=true`.
Text input uses an explicitly opt-in debug-only fixture button; this is NOT evidence
that native Quill typing automation works. The transparent overlay was removed.
The actual Save action validates, encrypts, inserts and publishes through production
code. XCUITest waits for editor dismissal and the actual note-list Button.

Final log: `/tmp/velock-note-fixture-test-6.log`.
Previously verified first saved row: id=1, ciphertext exists, 1017 bytes.
Tests now additionally require source note database count; file/media probe also
fails if either database category is absent rather than treating picker opening
as import success.

## Still unverified / incomplete

- Media and document real source import and restored content.
- Six-category replacement-phone recovery with content integrity evidence.
- Release gate for both apps. This report does not establish App Store readiness.
