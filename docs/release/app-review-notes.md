# App Review notes — Velock Sync

Paste the relevant paragraphs into App Store Connect → App Review Information →
Notes. Keep them in sync with the build you submit.

## What the app is

Velock Sync has two independent jobs, in two tabs:

1. **格间 / Velock backup** — transports objects that our companion app *Velock*
   (格间, a separate app) encrypts on the device before handing them over. Sync
   never sees plaintext: it uploads and downloads opaque objects. It asks the
   user to open Velock to authorize a device the first time.
2. **文件同步 / Files** — a plain folder mirror. The user picks one folder on the
   device and one folder on their own WebDAV server, and the two are kept in step
   (both directions, upload only, or download only). **The remote copy is not
   encrypted**; anyone with access to that WebDAV account can read and change the
   files, and the app says so before a location is created.

Nothing is sent to us: there is no account, no analytics and no server of ours.
The user supplies their own WebDAV server.

## Supported storage in 1.0

WebDAV is the only storage type in version 1.0. Google Drive, OneDrive, Baidu
Netdisk and Aliyun Drive are not offered in this build and do not appear when
adding a connection.

## The 格间 / Velock tab needs Velock 2.0.7 or later

The Velock backup tab only works together with Velock **2.0.7 or later**, which
is not yet released at the time of this submission (the current public Velock
version is 2.0.6). With an older Velock, or without Velock installed, the tab
shows a notice that Velock must be updated; backup and restore cannot start
from it. This is expected for this submission. The Files tab does not depend on
Velock and can be reviewed fully on its own.

## How to review file sync (WebDAV)

Test server for review: **<fill in before submission: https URL, user name,
password>** — or any WebDAV endpoint (a Nextcloud instance, a NAS, or a local
WebDAV server). Plain-HTTP endpoints on a local network are supported; the form
asks for an explicit confirmation before accepting `http://`.

1. Open the **文件同步 / Files** tab and tap **+** (top right).
2. Step 1 — choose a folder on the device (for example a folder under
   *On My iPhone* in the Files picker) that contains a few files.
3. Step 2 — tap **添加 WebDAV 连接 / Add WebDAV connection**, enter the server
   address, port, user name and password, and save. Back in the wizard, pick the
   connection and choose (or create) an empty remote folder.
4. Step 3 — keep the defaults (both directions, keep both copies on conflict)
   and tap **创建 / Create**.
5. On the new location card, tap **立即同步 / Sync now**. The device files appear
   in the remote folder as ordinary files. Add or change a file on the server and
   sync again: it is downloaded into the device folder.

Connections can also be managed under **设置 / Settings → 云端账号与保存位置 /
Cloud accounts and locations**.

If a test endpoint cannot be used in the review environment, the tab-level
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
The Android build declares `usesCleartextTraffic="true"` for the same reason, so
both platforms accept the same user-configured servers.

`NSLocalNetworkUsageDescription` is set because a user's WebDAV server is often
on the local network; iOS shows the local-network prompt the first time the app
connects to such an address.

## Export compliance (`ITSAppUsesNonExemptEncryption = false`)

> Owner must confirm this declaration before submission; it is a legal
> statement, not a technical default.

What the shipped features use: HTTPS/TLS from the operating system, SHA-256
hashing, and Ed25519 signature verification / signing for integrity and device
authorization. Velock backup data is encrypted by the separate Velock app, not
by Velock Sync; file sync writes plaintext files.

The binary still contains a standard AES-256-GCM + PBKDF2 implementation
(`package:cryptography`, not the OS) in the retired encrypted folder-sync code
(`lib/sync_core/crypto/generic_vault_*_cipher.dart`,
`vault_recovery_package.dart`). No 1.0 screen can create such a job. If that
code stays in the build, answer App Store Connect's "standard encryption
algorithms instead of, or in addition to, the OS" question accordingly, or
remove the code before relying on `false`.

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

* Only WebDAV servers can be used in 1.0 (see above).
* The Velock backup tab needs Velock 2.0.7 or later to authorize a device; until
  that version is available it shows the update notice described above.
