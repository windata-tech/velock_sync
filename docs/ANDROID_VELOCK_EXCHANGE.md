# Android Velock Exchange Contract

The Android Velock integration is a trust boundary between two separately
installed applications. `velock_sync` is the untrusted transport client. The
Velock companion app owns the provider below; this repository must never ship
that provider as a substitute for the companion.

## Admission requirements

The companion app must expose a `ContentProvider` (or an equivalent bound
service) that is protected by the signature-level permission:

```text
tech.windata.velock.permission.SYNC_EXCHANGE
```

It must reject callers unless both the calling UID package and signing
certificate match the approved Velock Sync release. The provider must not
grant broad URI permissions, browse access to the companion's databases, or
access to the live Velock business directory.

The two apps must agree on a single authority at integration time. It is not
hard-coded in the Sync app before the companion publishes its signed release;
this avoids accidentally treating an arbitrary content provider as Velock.

The Android Sync build is disabled for this integration unless its release
configuration supplies all three non-secret identifiers:

```text
VELOCK_EXCHANGE_AUTHORITY=<published provider authority>
VELOCK_COMPANION_PACKAGE=<published Velock package name>
VELOCK_COMPANION_CERT_SHA256=<lowercase SHA-256 of the signing certificate>
```

For example, a release build passes them as Gradle properties. Before each IPC
operation, Sync resolves the authority and checks both the resolved package
and one of its current signing certificates against these values. The manifest
query grants package visibility only; it does not constitute trust.

## Required operations

Every identifier is an opaque, slash-free ID. The provider must reject an
empty ID, `..`, `/`, `\\`, or an ID exceeding its documented maximum length.
All package payloads are opaque ciphertext artifacts; Sync must not ask for a
decryption operation.

| Operation | Required behavior |
| --- | --- |
| `queryReadyOutbox()` | Return READY package metadata only: batch ID, source device ID, sequence, immutable envelope/blob IDs and sizes. |
| `openOutboxEnvelope(batchId)` | Return a read-only `ParcelFileDescriptor` for the already signed envelope. |
| `openOutboxBlob(batchId, blobId)` | Return a read-only `ParcelFileDescriptor` for one declared ciphertext blob. |
| `claimOutbox(batchId, leaseId)` | Atomically claim exactly one READY package. It must be idempotent for the same lease and recover expired leases. |
| `acknowledgeOutbox(batchId, remoteCommit)` | Record the remote commit only after Sync has published it; it must be idempotent. |
| `createInbox(batchId)` | Create an isolated temporary inbox package, never a Ready package. |
| `writeInboxBlob(batchId, blobId)` | Return a write-only `ParcelFileDescriptor` for a declared ciphertext artifact. The provider validates expected IDs/sizes while committing. |
| `commitInbox(batchId)` | Verify the submitted package and hand it to Velock's importer. It returns only after a receipt state is durable. |
| `queryInboxReceipt(batchId)` | Return the signed ACK artifact reference once Velock has completed import. Sync uploads this artifact unchanged. |

Provider implementations must stream descriptors; they must not materialize
the full envelope or blob in Binder transactions. A failed write must stay in
a temporary state and must never become READY or imported content.

## Failure and lifecycle rules

- Use stable, non-sensitive error codes: `NOT_FOUND`, `LEASE_CONFLICT`,
  `LEASE_EXPIRED`, `INVALID_PACKAGE`, `ACCESS_DENIED`, `TEMPORARY_UNAVAILABLE`.
- A Sync crash after `claimOutbox` is recoverable through lease expiry.
- A crash after remote publish but before `acknowledgeOutbox` is safe: retry
  acknowledgement with the same immutable commit reference.
- A crash after `commitInbox` but before ACK upload is safe: query the durable
  receipt and publish the exact returned bytes; Sync never signs an ACK for a
  Velock dataset.
- The provider must log neither package plaintext nor key material. Sync logs
  only its sanitized error code and opaque transfer ID.

## Release gate

Android Velock datasets remain disabled until a companion build exposes this
contract, grants the signature permission to the production Sync certificate,
and passes an on-device interoperability test covering claim recovery,
inbox rejection, signed receipt forwarding, and caller-signature rejection.
