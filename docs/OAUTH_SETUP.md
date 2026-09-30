# Cloud drive app keys (OAuth)

Google Drive, OneDrive, Baidu Netdisk and Aliyun Drive only let an app sign a
user in if that app is registered on the provider's open platform. The
registration produces an app key (Client ID / AppKey, plus a SecretKey for
Baidu Netdisk).

**This repository contains no app keys.** A key committed here would be usable
by anyone who clones the project, and every copy would spend the owner's quota
and reputation. Keys therefore reach the app in exactly two ways:

1. **Built-in keys** — injected at build time for official releases (CI
   secrets or a local, git-ignored file). Users of those builds simply sign in.
2. **The user's own keys** — anyone can register an app for free and enter the
   values on the connection page under “Use your own app key”. They are kept
   only in platform secure storage on that device and override the built-in
   key for that provider.

A provider with neither a built-in key nor a user key is shown under
“More cloud drives” and opens the own-key form instead of a dead end.

## Redirect URI

Every registration (built-in or user-owned) must use this redirect:

```text
velocksync://oauth/callback
```

The Android intent filter and the iOS URL scheme are already configured.

## Building with built-in keys

Copy the example file, fill in only the providers you have registered, and pass
it to Flutter:

```bash
cp oauth_keys.example.json oauth_keys.json
flutter build ipa --dart-define-from-file=oauth_keys.json
```

`oauth_keys.json` is listed in `.gitignore`; never commit it and never print it
in CI logs. Empty values mean “no built-in key” for that provider.

| Define | Provider | Notes |
| --- | --- | --- |
| `GOOGLE_OAUTH_CLIENT_ID` | Google Drive | Public PKCE client, no secret |
| `ONEDRIVE_OAUTH_CLIENT_ID` | OneDrive | Application (client) ID, public client |
| `BAIDU_NETDISK_APP_KEY` | Baidu Netdisk | AppKey |
| `BAIDU_NETDISK_SECRET_KEY` | Baidu Netdisk | Required by Baidu at code exchange and refresh |
| `BAIDU_NETDISK_APP_FOLDER` | Baidu Netdisk | Optional, the app folder under `/apps/` |
| `ALIYUN_DRIVE_CLIENT_ID` | Aliyun Drive | App ID |
| `ALIYUN_DRIVE_CLIENT_SECRET` | Aliyun Drive | Optional |

Baidu Netdisk has no public-client flow: its SecretKey is compiled into a
build that carries built-in Baidu keys and can be extracted from the binary.
Treat that key as low-trust, watch its quota, and rotate it if abused. Google
Drive and OneDrive are public clients and never take a secret.

## Registering your own app

- **Google Drive** — in Google Cloud, enable the Drive API, configure the OAuth
  consent screen and create an OAuth Client ID. Only the Client ID is entered.
  Scope used: `drive.file`.
- **OneDrive** — register a public client app in Microsoft Entra, add the
  redirect under “Mobile and desktop applications”, and enter the Application
  (client) ID. Scopes used: `Files.ReadWrite`, `offline_access`.
- **Baidu Netdisk** — create an app on the Baidu Netdisk open platform and enter
  its AppKey, SecretKey and app name. Baidu only lets third-party apps write to
  `/apps/<app name>`, so the app name must match exactly.
- **Aliyun Drive** — create an app on the Aliyun Drive open platform and enter
  its App ID; the App Secret is optional.

## What is stored where

- The user's own registration: platform secure storage, key
  `velock-sync/oauth-client/<provider>`. Never in preferences, connection
  records, logs or synced data.
- Tokens: platform secure storage behind an opaque `credentialRef` in the
  connection record. When a connection was signed in with the user's own Baidu
  or Aliyun secret, that secret is stored with the tokens, because refreshing
  them needs the same secret. A connection keeps working with the key it signed
  in with even if the user later changes or removes their own registration;
  signing in again uses the current one.

## Re-authentication and removal

Creating a connection opens the system browser and validates the returned
state before token exchange. Re-authorizing a connection atomically replaces
its secure credential reference, then removes the old one. Removing an OAuth
connection requests remote revocation where supported before deleting the
local credential; if revocation fails the connection is restored so the user
can retry.
