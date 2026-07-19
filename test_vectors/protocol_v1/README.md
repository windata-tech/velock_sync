# Velock Sync Protocol V1 test vectors

These fixtures are intentionally free of credentials, real device keys,
filenames, and user content. The Dart, iOS XCTest, and Android JVM harnesses
load every case directly from this directory. Native tests independently
enforce canonical protocol spelling, opaque IDs, replay rejection, and the
VLSB1 HKDF/AES-GCM rejection path; they do not merely deserialize JSON.

| Directory | Expected result |
| --- | --- |
| `valid` | Canonical V1 discovery document is accepted. `protocol.utf8.json` carries its exact UTF-8 bytes in a JSON-safe envelope so a repository line ending cannot alter the protocol payload. |
| `unsupported_version` | Discovery document is rejected. |
| `path_traversal` | Opaque identifiers cannot form traversal keys. |
| `replay` | Duplicate operation IDs are rejected before import. |
| `invalid_authentication` | A syntactically valid blob with a forged tag is rejected. |
| `corrupted_blob` | A truncated blob artifact is rejected. |

Platform adapters should consume these exact byte/text fixtures rather than
normalizing them before validation.
