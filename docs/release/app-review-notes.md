# App Review notes — Velock Sync

Paste the relevant paragraphs into App Store Connect → App Review Information →
Notes. Keep them in sync with the build you submit.

## What the app is

Velock Sync has two independent jobs, in two tabs:

1. **格间 / Velock backup** — transports end-to-end encrypted objects produced by
   our companion app *Velock* (a separate app, also on the App Store). Sync never
   sees plaintext: it uploads and downloads opaque objects. It asks the user to
   open Velock to authorize a device the first time.
2. **文件同步 / File sync** — a plain folder mirror. The user picks one folder on
   the device and one folder on their own storage, and the two are kept in step
   (both directions, upload only, or download only). **The remote copy is not
   encrypted**, and the app says so before a location is created.

Nothing is sent to us: there is no account, no analytics and no server of ours.
The user supplies their own storage (a NAS or any WebDAV service).

## Reviewer access without hardware

Every sync feature needs a storage server the user owns. To review the flows:

* Any WebDAV endpoint works (for example a free WebDAV test service, a Nextcloud
  demo, or a local server). Enter address, port, user name and password under
  **设置 → 云端账号与保存位置 → +**.
* Plain-HTTP endpoints are supported for local networks; the form asks for an
  explicit confirmation before accepting `http://`.

If a test endpoint cannot be provided in the review environment, the tab-level
empty states, the three-step wizard, the settings page and the diagnostics pages
are all reachable without any server.

## App Transport Security (`NSAllowsArbitraryLoads`)

The app connects to **user-supplied** WebDAV servers. Home NAS devices on the
local network commonly expose only plaintext HTTP, and the user may also run a
server on a private address. `NSAllowsLocalNetworking` is enabled for that case;
`NSAllowsArbitraryLoads` remains enabled because the same WebDAV client must also
reach user-hosted servers over the public internet that the user configured
themselves. The app never talks to a server we operate, and the connection form
requires an explicit "use HTTP anyway" confirmation that warns about the risk.

## Background modes

`UIBackgroundModes = [fetch]` plus one `BGTaskScheduler` identifier are used only
to continue a transfer the user already configured, roughly every 15 minutes
while the app is backgrounded. The periodic task is only submitted when at least
one sync location has background sync switched **on**; with none configured, the
app cancels the task.

## Privacy

* No data is collected or shared with us; there is no third-party analytics or
  advertising SDK.
* Files are read and written only inside folders the user explicitly selects
  (iOS document picker / Android Storage Access Framework). No broad storage
  permission is requested.
* Credentials are stored in the Keychain / Android Keystore. Logs contain no
  credentials, no key material and no file contents.
* `PrivacyInfo.xcprivacy` declares the required-reason APIs actually used
  (disk space for a preflight check, file timestamps, user defaults).

## Known limitations worth knowing while reviewing

* File sync currently supports WebDAV only; cloud drives (Google Drive, OneDrive,
  Baidu) can be used by the Velock backup job but not as a plain mirror target.
* The Velock backup tab needs the companion app to authorize a device. Without it
  the tab explains how to install it and offers restore-from-cloud guidance.
