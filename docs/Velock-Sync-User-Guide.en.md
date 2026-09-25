# Velock Sync: Quick Start and Device Recovery

This guide covers first-time setup in a new, isolated, never-synced demonstration space and recovery on another device using WebDAV. It is not a guide to migrating an existing space to an empty remote. Velock encrypts and opens your content. Velock Sync transfers the encrypted data after you authorize it.

## Before you start

- Install both Velock and Velock Sync.
- Prepare your own WebDAV server address, port, credentials and writable folder.
- Use HTTPS for a real server. **Do not copy the tutorial's loopback address or HTTP setting.** `localhost` / `127.0.0.1` is for the recording computer’s local simulator setup, not a server address another physical device can use. Both real devices need access to the same HTTPS service.
- Keep your recovery card private and store a secure backup away from the original device.
- For English in Velock, select **Setting → Language → English**. In Velock Sync, select **Settings → Language → English**. The selection persists across launches.

## Video 1: First-time setup

### Check the source content first

Before first-time pairing and upload, create or import non-sensitive samples in Velock, finish saving them, and open each of these five types on the source device:

- **File:** open `velock-sync-e2e-proof.txt` and read `VELOCK SYNC REAL DATA E2E` in its body.
- **Photo:** open the full synthetic demonstration image, not just its thumbnail. The system may rename the imported image.
- **Login account:** open `E2E Password` and check that `e2e-user` is readable; keep the password masked.
- **Credit card:** separately open `E2E Credit Card` and check its synthetic test-card details. Do not use real card information.
- **Diary / note:** this tutorial uses a note sample, not a separately verified diary feature. Open `E2E note content` and check the body containing `恢复校验正文` (the recovery-check text).

These names are tutorial samples; check your own corresponding content in real use. The additional document check is separate from these five on-device demonstrations; see the scope note below.

### Allow Velock Sync to connect

1. Open Velock and unlock the space you want to sync.
2. Open **Setting → Experimental - Data Sync**.
3. Turn on **Allow new pairings** and confirm **Enable**.
4. Save the replacement-device recovery card when prompted.

**Use the recovery card generated after enabling sync.** An older registration-only card may not include the sync recovery information. You can generate an updated card from the same settings page.

### Configure WebDAV

1. Open Velock Sync and select **Connections**.
2. Select **Add Remote Connection → Choose Remote Protocol → WebDAV**.
3. Enter the server address, port, username, password and subpath supplied by your provider. Keep HTTPS enabled.
4. Select **Save**. Fix any connection error before continuing.

The WebDAV password is not your Velock space password.

### Pair the apps and back up

1. Select **Sync** and enable Velock backup.
2. Start connecting to Velock, then select **Start pairing**.
3. Accept the system prompt to open Velock, if shown.
4. Unlock Velock once, review the request and select **Approve**. Confirm approval.
5. Return to Velock Sync, choose your remote connection if prompted, then confirm creation.
6. Wait for the actual sync result. A newly created profile alone does not prove that your data has been uploaded.

## Video 2: Recover on another device

### Recover the original account

1. Install both apps on the new device.
2. Open Velock and select **Recover an Account → Recover from QR Code**.
3. Select **From Photos** and choose the original space's sync-enabled recovery card, or use the supported scanning option.
4. Review the form and select **Recover Account**. If biometric authentication is not set up, leave that shortcut off.
5. Enter the recovered space. **Do not create a new space instead of recovering the original account.**

Recovering the account and downloading its content are separate steps. An initially empty space does not by itself mean the recovery card is invalid.

### Reconnect and download

1. In the recovered space, open **Setting → Experimental - Data Sync** and allow new pairings if required.
2. In Velock Sync, add the **same WebDAV server and folder** used on the original device.
3. Pair the apps and approve the new request in Velock.
4. Wait for the download result. If instructed to open and unlock Velock to finish recovery, do so.
5. Return to Velock, unlock it and wait for import to finish. Open the file body and full photo first, then the login, credit-card and note details. Compare each with the source device; a profile or list entry alone is not proof. Documents have a separate host-side check described below, not an on-device body demonstration.
6. If the original device asks you to approve a new device, verify that the request is yours before approving it.

**Do not erase the original device or delete the remote folder until recovery has been verified and your recovery card is safely backed up.**

## Everyday use

Save changes in Velock, run the relevant profile in Velock Sync, then sync on the other device and unlock Velock there to finish importing.

## If something goes wrong

- **Pairing cannot start:** Check that Velock is installed, the correct space is unlocked, and new pairings are allowed.
- **Waiting for approval:** Review the pending request in Velock, approve it, then return to Velock Sync.
- **WebDAV authentication failure:** Check the provider credentials, not the Velock space password.
- **Content is not visible yet:** Return to the recovered original space, unlock it and let the import finish.
- **Remote history is incomplete:** Keep the original device and remote backup. Check for a wrong folder or missing backup history; do not clear history, bypass protection or retry against an empty folder. This tutorial does not provide automatic full migration of an existing space.
- **Unsafe remote writing is unsupported:** Do not bypass the protection or delete existing data; check server compatibility.

The tutorial requirements are: a disposable account and sample content, continuous original footage without cuts, speed changes, voice-over or added subtitles, and separate checks of all five on-device content types in both flows. These requirements do not mean that new videos have been recorded or accepted. Demonstration recovery materials must never be used to protect real data.

## Check each content type after recovery

Keep the original device available while checking the replacement device:

- **Files first:** open the actual file, read its contents, and check its name, size and folder. A filename or empty folder is not proof of recovery.
- **Albums first:** open the full photo, not just its thumbnail, and compare its content and information.
- **Login accounts:** open the restored account details.
- **Credit cards:** check card details separately; a restored login does not prove card recovery.
- **Diary entries / notes:** open the full body, not just its title or list summary.

Only consider retiring the original device after these checks. The earlier basic setup videos demonstrated a single login, not complete coverage of these content types.

## Additional document check and recovery limits

The tutorial also requires a sixth category, **document**, to be checked on the recording computer (host): both source and recovered devices must have non-empty encrypted documents with matching entity revisions and recovery metadata. This is an additional persistence check, **not proof that a document body was opened on the phone or that its decrypted body was verified**. Documents and notes are separate categories. Ordinary users do not need to run the test scripts, but should not interpret this host result as proof that every document is readable.

**Do not point a previously synced space at an empty remote and treat a completed sync as a complete backup.** The fresh tutorial source must have no previously published history before first-time setup; the replacement device must use the same complete remote backup. Progress checkpoints do not contain the full business content, and a recovery card does not replace the remote content backup. If remote history is missing, preserve the original device and complete old backups while resolving the missing history. This guide does not claim that automatic full migration or re-upload of an existing space has been fixed.
