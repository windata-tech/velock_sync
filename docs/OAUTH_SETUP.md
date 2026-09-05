# OAuth Provider Setup

Velock Sync uses public OAuth clients with PKCE. Never add a client secret to
Flutter source, `--dart-define`, preferences, or CI logs.

## Redirect URI

Register this exact mobile redirect URI with each public-client registration:

```text
velocksync://oauth/callback
```

The Android intent filter and iOS URL scheme are already present in the app.

## Build configuration

Provide only the public client IDs at build time:

```bash
flutter run \
  --dart-define=GOOGLE_OAUTH_CLIENT_ID=<google-public-client-id> \
  --dart-define=ONEDRIVE_OAUTH_CLIENT_ID=<microsoft-public-client-id>
```

The connection UI deliberately disables the corresponding authorization flow
when an ID is missing. Access and refresh tokens are stored only in platform
secure storage, behind an opaque `credentialRef` persisted in the connection
record.

## Provider choices

| Provider | Client flow | Minimum scope | Root location |
| --- | --- | --- | --- |
| Google Drive | PKCE public client | `drive.file` | `appDataFolder` by default, or a folder selected after authorization |
| OneDrive | PKCE public client | `Files.ReadWrite`, `offline_access` | `root` by default, or a folder selected after authorization |
| 百度网盘 | Deferred; credential pre-configuration only | `basic,netdisk` | The app can store an existing token bundle in secure storage, but a usable connection still requires an independently operated official Token Broker and a RemoteObjectStore adapter |
| 阿里云盘 | Deferred | N/A | Requires an independently operated official Token Broker |

For Google Drive, `appDataFolder` is the safe default for a managed vault. For
OneDrive, `root` selects the drive root. After successful browser authorization
the app shows a hierarchical folder selector; it only exposes folders that the
OAuth application can access under its granted scope.

## Re-authentication and removal

Creating a connection opens the system browser and validates the returned
state before token exchange. Re-authorizing from a connection's detail page
atomically replaces its opaque secure credential reference, then removes the
old local reference. Removing an OAuth connection requests remote revocation
where supported before deleting the local secure credential. If revocation
fails, the connection is restored locally so the user can retry.

## Domestic provider broker boundary

Do not proxy provider passwords or compile a confidential client secret into
the app. A future 百度网盘/阿里云盘 integration must use a separately deployed,
least-privilege Token Broker with its own operational ownership, audit trail,
rate limiting, and token-revocation policy.
