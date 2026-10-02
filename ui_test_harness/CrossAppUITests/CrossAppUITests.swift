import XCTest

/// Black-box cross-app UI flow for the two independent Velock apps.
///
/// The suite intentionally does not link against either app's Flutter code.
/// It drives the installed apps through their visible UI and accessibility
/// identifiers/text so it remains useful while the production apps evolve.
final class CrossAppUITests: XCTestCase {
    private let syncBundleID = "tech.windata.velock.sync"
    private let velockBundleID = "tech.windata.velock"
    private let fixtureHostBundleID = "tech.windata.velock.crossapp.uitest.host"
    private var webDAVPort: String {
        ProcessInfo.processInfo.environment["E2E_WEBDAV_PORT"] ?? "18991"
    }

    /// One-time diagnostic so scripted runs reveal which environment the
    /// test runner actually received (missing E2E_WEBDAV_PORT silently falls
    /// back to 18991 and every port-scoped selector misses).
    // Opt-in tutorial capture: the host starts/stops a raw simulator recording.
    // Registration/fixture setup happen before capture; normal tests are unchanged.
    private var tutorialTextOnly = false
    private var tutorialSeedPrepared = false
    private var tutorialReplicaCapture = false
    private var tutorialSourceCapturePending = false
    private var tutorialCaptureName: String?
    private var tutorialPace: Bool {
        ProcessInfo.processInfo.environment["E2E_TUTORIAL_PACE"] == "1"
    }

    private func beginTutorialCapture(_ name: String) throws {
        guard let root = ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] else {
            throw XCTSkip("Tutorial recording is explicitly opt-in")
        }
        let base = URL(fileURLWithPath: root)
        try Data(name.utf8).write(to: base.appendingPathComponent("start-" + name))
        let started = base.appendingPathComponent("recording-" + name).path
        let ready = NSPredicate { _, _ in FileManager.default.fileExists(atPath: started) }
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 30), .completed,
                       "Host recorder did not acknowledge capture start")
        tutorialCaptureName = name
        tutorialStage("CAPTURE_BEGIN")
    }

    private func tutorialStage(_ name: String) {
        guard let root = ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] else { return }
        let base = URL(fileURLWithPath: root)
        try? Data(name.utf8).write(to: base.appendingPathComponent("current-stage"))
        guard tutorialPace, tutorialCaptureName != nil else { return }
        let line = "\(Int(Date().timeIntervalSince1970 * 1000))\t\(name)\n"
        let timeline = base.appendingPathComponent("tutorial-stage-timeline.tsv")
        if !FileManager.default.fileExists(atPath: timeline.path) {
            try? Data().write(to: timeline)
        }
        if let handle = try? FileHandle(forWritingTo: timeline) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    /// Presentation-only holds. Regression runs are unchanged; tutorial takes
    /// get deliberate, visible reading time instead of relying on tap speed.
    private func tutorialHold(_ seconds: TimeInterval, reason: String) {
        guard tutorialPace, tutorialCaptureName != nil else { return }
        tutorialStage("hold-\(reason)")
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func finishTutorialCapture() {
        guard let name = tutorialCaptureName,
              let root = ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] else { return }
        try? Data().write(to: URL(fileURLWithPath: root).appendingPathComponent("stop-" + name))
        let stopped = URL(fileURLWithPath: root).appendingPathComponent("stopped-" + name).path
        let done = NSPredicate { _, _ in FileManager.default.fileExists(atPath: stopped) }
        let expectation = XCTNSPredicateExpectation(predicate: done, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed,
                       "Recorder did not finish before XCTest teardown")
        tutorialCaptureName = nil
    }

    // Presentation flows deliberately avoid regression-test retries, cold
    // restarts and probes for controls known to be absent. Any error aborts the
    // take: rejected takes are never spliced into a delivery.
    private var englishTutorial: Bool {
        ProcessInfo.processInfo.environment["E2E_TUTORIAL_LANGUAGE"] == "en"
    }

    private var cleanTutorial: Bool {
        ProcessInfo.processInfo.environment["E2E_TUTORIAL_CLEAN"] == "1"
    }

    private func tutorialNode(_ app: XCUIApplication, _ labels: [String], buttons: Bool = false) -> XCUIElement {
        let predicate = NSPredicate(format: "label IN %@ OR identifier IN %@", labels, labels)
        return (buttons ? app.buttons : app.descendants(matching: .any)).matching(predicate).firstMatch
    }

    private func tutorialContains(_ app: XCUIApplication, _ labels: [String]) -> XCUIElement {
        let predicates = labels.map { NSPredicate(format: "label CONTAINS %@ OR identifier == %@", $0, $0) }
        return app.descendants(matching: .any).matching(NSCompoundPredicate(orPredicateWithSubpredicates: predicates)).firstMatch
    }

    private func tutorialRootTab(_ labels: [String]) -> XCUIElement {
        // Root tabs expose duplicated labels ("File\nFile"). Exact button
        // matching avoids settings descriptions such as "Photos Preference".
        let visible = labels.flatMap { [$0, $0 + "\n" + $0] }
        return velockApp.buttons.matching(NSPredicate(
            format: "identifier IN %@ OR label IN %@", labels, visible)).firstMatch
    }

    private func tutorialReady(_ element: XCUIElement, _ stage: String, timeout: TimeInterval = 12) {
        tutorialStage(stage)
        let ready = NSPredicate { _, _ in element.exists && element.isHittable }
        let outcome = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: timeout)
        if outcome != .completed {
            print("TUTORIAL_MISSING_STAGE \(stage)")
            if let root = ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] {
                try? XCUIScreen.main.screenshot().pngRepresentation.write(
                    to: URL(fileURLWithPath: root).appendingPathComponent("rejected-\(stage).png"))
            }
        }
        XCTAssertEqual(outcome, .completed, "Tutorial did not reach \(stage)")
        tutorialNoError()
    }

    private func tutorialTap(_ element: XCUIElement, _ stage: String) {
        tutorialReady(element, stage)
        element.tap()
        tutorialHold(0.45, reason: "after-tap-\(stage)")
    }

    private func tutorialNoError() {
        for app in [velockApp!, syncApp!] where app.state == .runningForeground {
            let error = tutorialContains(app, ["密码错误", "密码不正确", "密码不能为空", "Incorrect password", "Wrong password", "Password is incorrect", "Password cannot be null", "首次同步失败", "First sync failed", "操作失败", "Operation failed"])
            XCTAssertFalse(error.exists && error.isHittable, "Error appeared; reject this raw take")
        }
    }

    private func tutorialUnlock() {
        let enter = tutorialNode(velockApp, ["进入沙盒空间", "Enter Sandbox", "Enter space", "Enter Space", "tkBtn_lock_unlock", "解锁", "Unlock"], buttons: true)
        let settings = tutorialContains(velockApp, ["设置", "Setting", "Settings", "允许新的配对", "Allow new pairings"])
        let state = NSPredicate { _, _ in
            (enter.exists && enter.isHittable) || (settings.exists && settings.isHittable)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: state, object: nil)], timeout: 12), .completed)
        guard enter.exists && enter.isHittable else { return }
        let password = ProcessInfo.processInfo.environment["VELOCK_RUNTIME_PASSWORD"] ?? ""
        XCTAssertFalse(password.isEmpty)
        let secure = velockApp.secureTextFields.firstMatch
        let labeled = tutorialNode(velockApp, ["请输入密码", "Please enter password", "Please Enter Password", "Enter password"])
        let textField = velockApp.textFields.firstMatch
        let field = secure.exists ? secure : (textField.exists ? textField : labeled)
        tutorialReady(field, "unlock-password-field")
        // Flutter changes TextField to SecureTextField after focus on iOS.
        // Read pre-focus contents before that accessibility query changes type.
        let old = field.value as? String ?? ""
        let chosen = "Chosen field type: \(field.elementType.rawValue), label: \(field.label), frame: \(field.frame)"
        field.tap()
        if ProcessInfo.processInfo.environment["E2E_TUTORIAL_FOCUS_PROBE"] == "1",
           let root = ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: root).appendingPathComponent("focus-after-tap.png"))
            let detail = chosen + "\nKeyboard count: \(velockApp.keyboards.count)\n" +
                "Secure input present: \(velockApp.secureTextFields.firstMatch.exists)"
            try? detail.write(to: URL(fileURLWithPath: root).appendingPathComponent("focus-elements.txt"), atomically: true, encoding: .utf8)
        }
        // XCTest can type into a focused input with a connected hardware
        // keyboard; a visible software keyboard is not a reliable focus test.
        // typeText itself fails rather than submitting if no input has focus.
        // Never append to a retained password. Placeholders are not contents.
        if !old.isEmpty && !["请输入密码", "Please enter password", "Please Enter Password", "Password", "Enter password"].contains(old) {
            velockApp.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        velockApp.typeText(password)
        // Submit exactly once, only after input. No empty-password probe/retry.
        enter.tap()
        let unlocked = enter.waitForNonExistence(timeout: 12)
        if !unlocked, let root = ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: root).appendingPathComponent("rejected-unlock.png"))
        }
        XCTAssertTrue(unlocked, "Password gate did not unlock on first submission")
        tutorialNoError()
        tutorialHold(0.9, reason: "unlock-complete")
    }

    private func tutorialOpenSyncSettings() {
        tutorialUnlock()
        let settings = tutorialContains(velockApp, ["设置", "Setting", "Settings"])
        tutorialTap(settings, "settings")
        let sync = tutorialContains(velockApp, ["云备份", "Cloud backup", "实验性 - 数据同步", "Experimental - Data Sync", "Experimental – Data Sync", "Experimental - Data Synchronization"])
        for _ in 0..<4 {
            if sync.exists && sync.isHittable { break }
            velockApp.swipeUp()
        }
        tutorialTap(sync, "data-sync-settings")
        tutorialReady(tutorialContains(velockApp, ["允许新的配对", "Allow new pairings", "Allow New Pairings"]), "pairing-settings-ready")
    }

    private func tutorialEnablePairing(saveCard: Bool) {
        let row = tutorialContains(velockApp, ["允许新的配对", "Allow new pairings", "Allow New Pairings"])
        tutorialReady(row, "allow-pairing")
        let toggle = velockApp.switches.firstMatch
        if (toggle.exists && (toggle.value as? String) == "0") || row.label.contains("未启用") || row.label.contains("Disabled") {
            // Flutter merges this switch with the whole section, including
            // the localized explanation; its AX midpoint is not the control.
            // Visually verified on the dedicated 440 x 956 pt tutorial device.
            XCTAssertEqual(velockApp.frame.width, 440, accuracy: 1)
            XCTAssertEqual(velockApp.frame.height, 956, accuracy: 1)
            velockApp.coordinate(withNormalizedOffset: CGVector(dx: 0.855, dy: 0.1935)).tap()
            tutorialTap(tutorialNode(velockApp, ["启用", "Enable"], buttons: true), "enable-pairing-confirm")
        }
        if saveCard {
            let save = tutorialNode(velockApp, ["保存恢复卡到相册", "Save Recovery Card to Photos", "Save recovery card to Photos"], buttons: true)
            tutorialReady(save, "save-recovery-card")
            persistRecoveryCardScreenshotIfRequested()
            save.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let returned = NSPredicate { _, _ in
                if row.exists && row.isHittable { return true }
                let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["允许", "Allow"])).firstMatch
                if allow.exists && allow.isHittable { allow.tap() }
                return false
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: returned, object: nil)], timeout: 12), .completed)
        }
        tutorialReady(row, "pairing-enabled")
        tutorialHold(1.2, reason: "pairing-enabled")
    }

    private func tutorialNewConnection() {
        syncApp.launch()
        tutorialTap(tutorialContains(syncApp, ["连接", "Connections"]), "connections")
        tutorialTap(tutorialContains(syncApp, ["添加远端连接", "Add remote connection", "Add Remote Connection"]), "add-connection")
        tutorialTap(tutorialContains(syncApp, ["选择远端协议", "选择协议", "Choose protocol", "Select Protocol", "Select remote protocol", "Choose Remote Protocol"]), "choose-protocol")
        tutorialTap(tutorialContains(syncApp, ["WebDAV"]), "webdav")
        tutorialTap(syncApp.switches.firstMatch, "demo-http")
        tutorialTap(tutorialNode(syncApp, ["仍然使用 HTTP", "Use HTTP anyway", "Continue with HTTP", "Use HTTP Anyway"], buttons: true), "demo-http-confirm")
        let address = tutorialContains(syncApp, ["服务器地址", "Server address", "Server Address"])
        tutorialTap(address, "server-address")
        syncApp.typeText("127.0.0.1")
        tutorialHold(0.6, reason: "server-address-entered")
        tutorialTap(tutorialContains(syncApp, ["端口", "Port"]), "server-port")
        syncApp.typeText(webDAVPort)
        tutorialHold(0.6, reason: "server-port-entered")
        tutorialTap(tutorialNode(syncApp, ["保存", "Save"], buttons: true), "save-connection")
        tutorialReady(tutorialContains(syncApp, ["WebDAV · ", "已连接服务", "Connected services", "Connected Services", "Connected"]), "connection-saved")
        tutorialHold(0.9, reason: "connection-saved")
    }

    private func tutorialPairAndSync(replica: Bool) {
        tutorialNewConnection()
        tutorialTap(tutorialContains(syncApp, ["同步", "Sync"]), "sync-tab")
        tutorialTap(tutorialContains(syncApp, ["开启格间备份", "Enable Velock Backup", "Enable Velock backup"]), "enable-backup")
        tutorialTap(tutorialContains(syncApp, ["开始连接格间", "Connect Velock", "Connect to Velock", "Start connecting Velock"]), "inspect-pairing")
        tutorialTap(tutorialContains(syncApp, ["开始配对", "Start pairing", "Start Pairing"]), "start-pairing")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = syncApp.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["打开", "Open"])).firstMatch
        let systemOpen = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["打开", "Open"])).firstMatch
        let launched = NSPredicate { _, _ in
            if self.velockApp.state == .runningForeground { return true }
            if open.exists && open.isHittable { open.tap() }
            else if systemOpen.exists && systemOpen.isHittable { systemOpen.tap() }
            return self.velockApp.state == .runningForeground
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: launched, object: nil)], timeout: 15), .completed)
        tutorialUnlock()
        let approve = tutorialNode(velockApp, ["批准", "Approve"], buttons: true)
        tutorialTap(approve, "approve-request")
        let confirmation = tutorialNode(velockApp, ["批准这台 Velock Sync？", "Approve this Velock Sync?"])
        tutorialReady(confirmation, "approval-confirmation")
        tutorialHold(0.9, reason: "approval-confirmation")
        let dialogApprove = velockApp.buttons.matching(NSPredicate(format: "label IN %@", ["批准", "Approve"]))
        XCTAssertEqual(dialogApprove.count, 1, "Approval must be scoped to the visible dialog")
        tutorialTap(dialogApprove.firstMatch, "confirm-approval")
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 8), "Approval dialog did not close")
        // Observe the completed authorization, not an arbitrary fixed delay.
        let completed = NSPredicate { _, _ in !approve.exists || !approve.isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: completed, object: nil)], timeout: 12), .completed)
        tutorialNoError()
        tutorialHold(0.8, reason: "approval-complete")
        syncApp.activate()
        tutorialTap(tutorialNode(syncApp, ["确认并创建", "Confirm and create", "Confirm & Create", "Confirm and Create"], buttons: true), "create-profile")
        let result = tutorialContains(syncApp, ["已下载", "格间同步完成", "当前没有新的数据需要同步", "Downloaded", "Velock sync complete", "Sync complete", "No new data to sync"])
        tutorialStage("sync-complete")
        XCTAssertTrue(result.waitForExistence(timeout: 25), "First sync did not produce a result")
        tutorialNoError()
        tutorialHold(replica ? 1.1 : 2.4, reason: "sync-result")
        if !replica {
            tutorialTap(tutorialNode(syncApp, ["刷新同步配置", "Refresh sync profiles"], buttons: true), "refresh-completed-backup")
            let notBackedUp = tutorialContains(syncApp, ["尚未备份", "Not backed up yet"])
            XCTAssertTrue(notBackedUp.waitForNonExistence(timeout: 8), "Completed backup summary remained stale")
            tutorialHold(0.8, reason: "refresh-complete")
        }
        attachScreenshot(replica ? "tutorial-recovery-downloaded" : "tutorial-first-sync-complete")
        if replica {
            let openVelock = tutorialNode(syncApp, ["打开格间", "Open Velock"], buttons: true)
            if openVelock.exists && openVelock.isHittable { openVelock.tap() }
            else { velockApp.activate() }
            tutorialUnlock()
            tutorialOpenRestoredContent()
        }
    }

    private func tutorialReturnToDashboard() {
        let credentials = velockApp.buttons.matching(NSPredicate(format: "label CONTAINS '凭证' OR label CONTAINS 'Credentials'")).firstMatch
        let syncTitle = tutorialNode(velockApp, ["云备份", "Cloud backup", "实验性 - 数据同步", "Experimental - Data Sync"])
        // The pairing deep link can stack a second sync-settings route above
        // the original. Pop actual routes, not a fixed number of blind taps.
        for _ in 0..<3 {
            if credentials.exists && credentials.isHittable { break }
            tutorialReady(syncTitle, "sync-page-before-back")
            let candidates = velockApp.buttons.matching(NSPredicate(
                format: "label IN %@", ["返回", "Back", "设置", "Setting", "Settings"])).allElementsBoundByIndex
            let navigationBack = candidates.first {
                $0.exists && $0.isHittable && $0.frame.minX < 100 && $0.frame.maxY < 150
            }
            tutorialStage("back-to-dashboard")
            if let navigationBack {
                navigationBack.tap()
            } else {
                // AX fallback, observed navigation control on this device size.
                XCTAssertEqual(velockApp.frame.width, 440, accuracy: 1)
                XCTAssertEqual(velockApp.frame.height, 956, accuracy: 1)
                velockApp.coordinate(withNormalizedOffset: CGVector(dx: 24.0/440.0, dy: 84.0/956.0)).tap()
            }
            let dashboard = NSPredicate { _, _ in credentials.exists && credentials.isHittable }
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: dashboard, object: nil)], timeout: 2) == .completed { break }
        }
        tutorialReady(credentials, "content-dashboard-ready")
    }

    private func tutorialOpenRestoredContent() {
        tutorialReturnToDashboard()
        tutorialVerifyAllContent()
    }

    /// Public tutorial must demonstrate content, not just one restored account.
    /// Uses synthetic fixtures only. No seeding, retries or app restart here.
    private func tutorialVerifyAllContent() {
        var verified: [String] = []
        func evidence(_ kind: String) {
            tutorialNoError()
            attachScreenshot("tutorial-content-" + kind)
            tutorialHold(2.3, reason: "read-\(kind)")
            verified.append(kind)
        }
        tutorialVerifyFileContent(evidence)
        tutorialVerifyPhotoContent(evidence)
        tutorialVerifyCredentialContent(evidence)
        // document has additional host persistence/revision checks; mobile's
        // Notes credential is distinct from the desktop document module.
        XCTAssertEqual(Set(verified), Set(["file", "media", "password", "card", "note"]))
        if let root = ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] {
            do {
                let data = try JSONSerialization.data(withJSONObject: ["verified_ui_kinds": verified])
                let phase = tutorialReplicaCapture ? "replica" : "source"
                try data.write(to: URL(fileURLWithPath: root).appendingPathComponent(phase + "-ui-coverage.json"))
            } catch { XCTFail("Cannot persist tutorial UI coverage") }
        }
    }

    private func tutorialBackToTabs(_ stage: String) {
        tutorialTap(tutorialNode(velockApp, ["QLOverlayDoneButtonAccessibilityIdentifier", "返回", "Back", "关闭", "Close", "close", "完成", "Done"], buttons: true), stage)
        tutorialReady(tutorialRootTab(["tkNav_files", "文件", "File", "Files"]), stage + "-complete")
    }

    private func tutorialVerifyFileContent(_ evidence: (String) -> Void) {
        // File and album come first: these are the primary tutorial scenarios.
        tutorialTap(tutorialRootTab(["tkNav_files", "文件", "File", "Files"]), "show-files")
        let files = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'file-item-' AND label == %@", "velock-sync-e2e-proof.txt"))
        tutorialReady(files.firstMatch, "proof-file-ready")
        tutorialHold(0.9, reason: "file-selected")
        XCTAssertEqual(files.count, 1, "Proof file must be unique; never open an arbitrary first tile")
        tutorialTap(files.firstMatch, "open-proof-file")
        // First-use iOS preview explanation is a real user step, not an error.
        let explanation = tutorialNode(velockApp, ["关于网络权限的说明", "About network permission"])
        let content = velockApp.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "VELOCK SYNC REAL DATA E2E", "VELOCK SYNC REAL DATA E2E")).firstMatch
        let previewState = NSPredicate { _, _ in explanation.exists || content.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: previewState, object: nil)], timeout: 15), .completed)
        if explanation.exists {
            tutorialTap(tutorialNode(velockApp, ["知道了", "Got it", "Got It"], buttons: true), "preview-explanation")
        }
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let readable = NSPredicate { _, _ in
            // Preview does not need network access to read this local fixture.
            let deny = system.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["不允许", "Don't Allow"])).firstMatch
            if deny.exists && deny.isHittable { deny.tap() }
            return content.exists && content.isHittable
        }
        tutorialStage("proof-file-content")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: readable, object: nil)], timeout: 20), .completed,
                       "Decrypted text body was not visible in the actual preview")
        tutorialHold(0.6, reason: "file-body-settled")
        evidence("file")
        tutorialBackToTabs("close-proof-file")

    }

    private func tutorialVerifyPhotoContent(_ evidence: (String) -> Void) {
        tutorialTap(tutorialRootTab(["tkNav_images", "相册", "Photo", "Photos", "Albums", "Images"]), "show-album")
        let photos = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'media-item-' AND label == %@", ProcessInfo.processInfo.environment["E2E_TUTORIAL_PHOTO_NAME"] ?? "velock-sync-e2e-proof.png"))
        tutorialReady(photos.firstMatch, "proof-photo-ready")
        tutorialHold(0.9, reason: "photo-selected")
        XCTAssertEqual(photos.count, 1, "Proof photo must be unique; never select the recovery card")
        let photoID = photos.firstMatch.identifier.replacingOccurrences(of: "media-item-", with: "")
        tutorialTap(photos.firstMatch, "open-proof-photo")
        tutorialReady(tutorialNode(velockApp, ["media-preview-ready-" + photoID]), "proof-photo-decoded")
        tutorialHold(0.6, reason: "photo-settled")
        evidence("media")
        tutorialTap(tutorialNode(velockApp, ["media-preview-close"]), "close-proof-photo")
        tutorialReady(tutorialRootTab(["tkNav_files", "文件", "File", "Files"]), "photo-close-complete")

    }

    private func tutorialVerifyCredentialContent(_ evidence: (String) -> Void) {
        tutorialTap(tutorialContains(velockApp, ["凭证", "Credentials"]), "show-credentials")
        tutorialTap(tutorialNode(velockApp, ["账户", "账号", "Account", "Accounts"], buttons: true), "show-accounts")
        tutorialHold(0.8, reason: "account-selected")
        tutorialTap(tutorialContains(velockApp, ["E2E Password"]), "open-account")
        tutorialReady(tutorialContains(velockApp, ["e2e-user"]), "account-content")
        tutorialHold(0.5, reason: "account-settled")
        evidence("password")
        tutorialBackToTabs("close-account")
        tutorialTap(tutorialContains(velockApp, ["E2E Credit Card"]), "open-credit-card")
        // This fixed number is a synthetic Visa test fixture, never a real card.
        let cardPattern = ".*4111[ ]*1111[ ]*1111[ ]*1111.*"
        let cardNumber = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label MATCHES %@ OR value MATCHES %@", cardPattern, cardPattern)
        ).firstMatch
        tutorialReady(cardNumber, "credit-card-content")
        tutorialHold(0.5, reason: "card-settled")
        evidence("card")
        tutorialBackToTabs("close-credit-card")
        tutorialTap(tutorialNode(velockApp, ["备注", "Note", "Notes"], buttons: true), "show-diary-notes")
        tutorialTap(tutorialContains(velockApp, ["E2E note content"]), "open-diary-note")
        // Use the second body line, not the list title/summary, as proof.
        tutorialReady(tutorialContains(velockApp, ["恢复校验正文"]), "diary-body-content")
        tutorialHold(0.5, reason: "note-settled")
        evidence("note")
        tutorialBackToTabs("close-diary-note")
    }

    private func tutorialPrepareEnglishSync() {
        syncApp.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        syncApp.launch()
        tutorialReady(tutorialContains(syncApp, ["设置", "Setting", "Settings"]), "prepare-sync-ready")
        let englishSettings = tutorialContains(syncApp, ["Settings"])
        if englishSettings.exists && englishSettings.isHittable {
            syncApp.terminate()
            return
        }
        tutorialTap(tutorialContains(syncApp, ["设置", "Setting", "Settings"]), "prepare-sync-language")
        tutorialTap(tutorialContains(syncApp, ["语言", "Language"]), "prepare-sync-language-menu")
        tutorialTap(tutorialNode(syncApp, ["English"]), "prepare-sync-english")
        tutorialReady(tutorialContains(syncApp, ["Language"]), "prepare-sync-language-persisted")
        syncApp.terminate()
    }

    private func tutorialPrepareEnglishSource() {
        tutorialPrepareEnglishSync()
        velockApp.activate()
        tutorialUnlock()
        let englishSettings = tutorialContains(velockApp, ["Setting"])
        if englishSettings.exists && englishSettings.isHittable {
            velockApp.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            return
        }
        tutorialTap(tutorialContains(velockApp, ["设置", "Setting", "Settings"]), "prepare-velock-settings")
        let language = tutorialContains(velockApp, ["语言", "Language"])
        for _ in 0..<4 {
            if language.exists && language.isHittable { break }
            velockApp.swipeUp()
        }
        tutorialTap(language, "prepare-velock-language")
        tutorialTap(tutorialNode(velockApp, ["English"], buttons: true), "prepare-velock-english")
        tutorialReady(tutorialContains(velockApp, ["Language"]), "english-language-applied")
        // Reopen outside recording so the tutorial starts on the dashboard.
        velockApp.terminate()
        velockApp.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        velockApp.launch()
        tutorialUnlock()
    }

    func testTutorialUnlockFirstAttempt() throws {
        guard ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] != nil else {
            throw XCTSkip("Tutorial diagnostics are explicitly opt-in")
        }
        velockApp.launch()
        tutorialUnlock()
        tutorialReady(tutorialContains(velockApp, ["设置", "Setting", "Settings"]), "login-once")
        syncApp.launch()
        velockApp.activate()
        tutorialUnlock()
        tutorialReady(tutorialContains(velockApp, ["设置", "Setting", "Settings"]), "resume-unlock-once")
    }

    func testTutorialSourceFlow() throws {
        guard ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] != nil else {
            throw XCTSkip("Tutorial recording is explicitly opt-in")
        }
        XCTAssertEqual(ProcessInfo.processInfo.environment["E2E_TUTORIAL_FULL_CONTENT"], "1",
                       "Tutorial must cover files, albums and all credential kinds")
        XCTAssertEqual(ProcessInfo.processInfo.environment["E2E_TUTORIAL_PREPARED"], "1",
                       "Prepare and host-verify all source payloads before capture")
        if englishTutorial {
            // Fixture preparation is outside the take. Use the established
            // Chinese setup path, then change the real persisted UI language.
            velockApp.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        }
        if ProcessInfo.processInfo.environment["E2E_TUTORIAL_PREPARED"] == "1" {
            velockApp.launch()
            tutorialUnlock()
        } else {
            ensureVelockInitializedAndPairingEnabled(enablePairing: false)
            seedVelockBusinessDataIfRequested()
        }
        if englishTutorial { tutorialPrepareEnglishSource() }
        // Off-camera: withdraw only the pairing entry point, preserving vault
        // data/keys. The take then demonstrates the actual Enable + card flow.
        tutorialOpenSyncSettings()
        let pairingRow = tutorialContains(velockApp, ["允许新的配对", "Allow new pairings", "Allow New Pairings"])
        let pairingSwitch = velockApp.switches.firstMatch
        if (pairingSwitch.exists && (pairingSwitch.value as? String) == "1") ||
            pairingRow.label.contains("已启用") || pairingRow.label.contains("Enabled") {
            XCTAssertEqual(velockApp.frame.width, 440, accuracy: 1)
            XCTAssertEqual(velockApp.frame.height, 956, accuracy: 1)
            velockApp.coordinate(withNormalizedOffset: CGVector(dx: 0.855, dy: 0.1935)).tap()
            tutorialTap(tutorialNode(velockApp, ["停用", "Disable"], buttons: true), "prepare-disable-pairing")
        }
        tutorialReturnToDashboard()
        tutorialSeedPrepared = true
        defer { finishTutorialCapture() }
        if cleanTutorial {
            try beginTutorialCapture("01-first-setup")
            tutorialReturnToDashboard()
            tutorialVerifyAllContent()
            tutorialOpenSyncSettings()
            tutorialEnablePairing(saveCard: true)
            tutorialPairAndSync(replica: false)
        } else {
            tutorialSourceCapturePending = true
            testCrossAppPairingFlow()
        }
    }

    func testTutorialReplicaFlow() throws {
        guard ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] != nil else {
            throw XCTSkip("Tutorial recording is explicitly opt-in")
        }
        XCTAssertEqual(ProcessInfo.processInfo.environment["E2E_TUTORIAL_FULL_CONTENT"], "1",
                       "Password-only recovery is not complete tutorial coverage")
        tutorialSeedPrepared = true
        tutorialReplicaCapture = true
        defer { finishTutorialCapture() }
        testRecoverVelockAccountFromCardPhoto()
        if cleanTutorial {
            tutorialOpenSyncSettings()
            tutorialEnablePairing(saveCard: false)
            tutorialPairAndSync(replica: true)
        } else {
            testCrossAppPairingFlow()
            testRestoredCredentialAfterColdRestart()
        }
    }

    private var printedEnvironment: Bool = false
    private func logTestEnvironmentIfFirst() {
        guard !printedEnvironment else { return }
        printedEnvironment = true
        print("E2E_ENV webDAVPort=\(webDAVPort) " +
              "RECOVERY_PASSPHRASE=\(ProcessInfo.processInfo.environment["E2E_RECOVERY_PASSPHRASE"]?.isEmpty == false ? "set" : "unset") " +
              "RECOVERY_PACKAGE_FILE=\(ProcessInfo.processInfo.environment["E2E_RECOVERY_PACKAGE_FILE"]?.isEmpty == false ? "set" : "unset")")
    }

    private var syncApp: XCUIApplication!
    private var velockApp: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        syncApp = XCUIApplication(bundleIdentifier: syncBundleID)
        velockApp = XCUIApplication(bundleIdentifier: velockBundleID)
    }

    /// Opt-in check against an existing installation. Saves the currently
    /// selected folder through the UI; does not start backup or seed/reset data.
    func testSavedBackupLocationLeavesHistoryHelpLoop() throws {
        guard ProcessInfo.processInfo.environment["E2E_LOCATION_CHECK"] == "1" else {
            throw XCTSkip("Requires explicit permission to save the current backup location")
        }
        func node(_ label: String) -> XCUIElement {
            let exact = syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", label)
            ).firstMatch
            if exact.exists { return exact }
            return syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH %@ OR label CONTAINS %@", label + "\n", "\n" + label)
            ).firstMatch
        }
        func press(_ label: String, timeout: TimeInterval = 20) {
            let target = node(label)
            XCTAssertTrue(target.waitForExistence(timeout: timeout), "Missing: \(label)\n\(syncApp.debugDescription)")
            if target.elementType == .button && target.label != label {
                // Flutter exposes the status card as one accessibility button.
                // Its action is in the bottom part of the observed card frame.
                target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.87)).tap()
            } else {
                target.tap()
            }
        }
        syncApp.launch()
        press("详情")
        // Existing automatic backup can finish after launch. Do not manufacture
        // another failure just to exercise the help route; both entries share
        // the same folder-save implementation.
        let historyHelp = node("查看原因和下一步").exists
        if historyHelp {
            press("查看原因和下一步")
            press("选择原备份文件夹")
        } else {
            XCTAssertTrue(node("上次备份已完成").waitForExistence(timeout: 60))
            press("管理")
            press("更换保存位置")
        }
        XCTAssertTrue(node("/USB_HDD_8T/111").waitForExistence(timeout: 20))
        press("使用这个文件夹")
        press("保存位置", timeout: 60)
        if historyHelp {
            press("完成")
        } else {
            press("返回")
        }
        XCTAssertTrue(node("保存位置已更改").waitForExistence(timeout: 20))
        XCTAssertTrue(node("检查并备份").exists)
        XCTAssertFalse(node("查看原因和下一步").exists)
        attachScreenshot("saved-location-ready-to-check")
        if let path = ProcessInfo.processInfo.environment["E2E_LOCATION_SCREENSHOT"] {
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: path))
        }
    }

    func testManualBackupCompletionDoesNotShowFailureAlert() throws {
        guard ProcessInfo.processInfo.environment["E2E_MANUAL_BACKUP_CHECK"] == "1" else {
            throw XCTSkip("Explicit opt-in: runs the existing backup without changing its configuration")
        }
        syncApp.launch()
        let exact = syncApp.buttons.matching(NSPredicate(format: "label == %@", "立即备份")).firstMatch
        let card = syncApp.buttons.matching(NSPredicate(format: "label CONTAINS %@", "\n立即备份")).firstMatch
        XCTAssertTrue(exact.waitForExistence(timeout: 10) || card.waitForExistence(timeout: 50))
        if exact.exists {
            exact.tap()
        } else {
            // The observed home card exposes both actions in one AX node;
            // the primary backup action occupies its bottom-left half.
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.87)).tap()
        }
        let failure = syncApp.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "同步失败")).firstMatch
        XCTAssertFalse(failure.waitForExistence(timeout: 8), syncApp.debugDescription)
        XCTAssertTrue(card.waitForExistence(timeout: 60) || exact.exists)
        XCTAssertFalse(failure.exists)
        let completed = syncApp.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "上次备份已完成")).firstMatch
        XCTAssertTrue(completed.exists)
        attachScreenshot("manual-backup-completed-without-failure")
        if let path = ProcessInfo.processInfo.environment["E2E_MANUAL_BACKUP_SCREENSHOT"] {
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: path))
        }
    }

    func testManageBackupLocationOffersNewFolderOnRight() throws {
        guard ProcessInfo.processInfo.environment["E2E_FOLDER_BUTTON_CHECK"] == "1" else {
            throw XCTSkip("Explicit opt-in: opens and cancels new-folder form; no remote writes")
        }
        func node(_ label: String) -> XCUIElement {
            let exact = syncApp.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            if exact.exists { return exact }
            return syncApp.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@ OR label CONTAINS %@", label, label + "\n", "\n" + label)).firstMatch
        }
        func press(_ label: String) {
            let target = node(label)
            XCTAssertTrue(target.waitForExistence(timeout: 25), "Missing \(label): \(syncApp.debugDescription)")
            target.tap()
        }
        syncApp.launch()
        press("详情")
        press("管理")
        press("更换保存位置")
        XCTAssertTrue(node("选择备份文件夹").waitForExistence(timeout: 25), syncApp.debugDescription)
        let create = node("新建文件夹")
        XCTAssertTrue(create.waitForExistence(timeout: 25))
        XCTAssertGreaterThan(create.frame.midX, node("上一级").frame.midX)
        press("新建文件夹")
        XCTAssertTrue(node("创建并进入").waitForExistence(timeout: 10))
        press("取消")
        XCTAssertTrue(node("选择备份文件夹").waitForExistence(timeout: 10), syncApp.debugDescription)
        attachScreenshot("manage-location-new-folder-on-right")
        if let path = ProcessInfo.processInfo.environment["E2E_FOLDER_BUTTON_SCREENSHOT"] {
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: path))
        }
    }

    override func record(_ issue: XCTIssue) {
        if let root = ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: root).appendingPathComponent("rejected-failure.png"))
            if let app = velockApp, app.state == .runningForeground {
                try? app.debugDescription.write(toFile: root + "/rejected-state.txt", atomically: true, encoding: .utf8)
            }
        }
        super.record(issue)
    }

    func testTutorialPairingSwitchProbe() throws {
        guard ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] != nil else {
            throw XCTSkip("Tutorial diagnostics are explicitly opt-in")
        }
        velockApp.launch()
        tutorialOpenSyncSettings()
        let row = tutorialContains(velockApp, ["允许新的配对", "Allow new pairings"])
        let toggle = velockApp.switches.firstMatch
        if let root = ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] {
            let text = "row frame \(row.frame) label \(row.label)\nswitch exists \(toggle.exists) frame \(toggle.frame) label \(toggle.label)"
            try? text.write(to: URL(fileURLWithPath: root).appendingPathComponent("toggle-geometry.txt"), atomically: true, encoding: .utf8)
        }
        let target = toggle.exists ? toggle : row
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        tutorialReady(tutorialNode(velockApp, ["启用", "Enable"], buttons: true), "probe-enable")
        tutorialTap(tutorialNode(velockApp, ["取消", "Cancel"], buttons: true), "probe-cancel")
    }

    func testTutorialNavigationProbe() throws {
        guard ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] != nil else {
            throw XCTSkip("Tutorial diagnostics are explicitly opt-in")
        }
        velockApp.launch()
        tutorialOpenSyncSettings()
        syncApp.launch()
        velockApp.activate()
        tutorialUnlock()
        tutorialOpenRestoredContent()
    }

    func testTutorialFileContentProbe() throws {
        guard ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] != nil else {
            throw XCTSkip("Explicit content diagnostic only")
        }
        velockApp.launch()
        tutorialUnlock()
        tutorialVerifyFileContent { kind in
            tutorialNoError()
            attachScreenshot("verified-" + kind)
        }
    }

    func testTutorialPhotoContentProbe() throws {
        guard ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] != nil else {
            throw XCTSkip("Explicit content diagnostic only")
        }
        velockApp.launch()
        tutorialUnlock()
        tutorialVerifyPhotoContent { kind in
            tutorialNoError()
            attachScreenshot("verified-" + kind)
        }
    }

    func testTutorialCredentialContentProbe() throws {
        guard ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] != nil else {
            throw XCTSkip("Explicit content diagnostic only")
        }
        velockApp.launch()
        tutorialUnlock()
        tutorialVerifyCredentialContent { kind in
            tutorialNoError()
            attachScreenshot("verified-" + kind)
        }
    }

    func testTutorialImportText() throws {
        guard let root = ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] else {
            throw XCTSkip("Explicit preparation only")
        }
        prepareFixtureHost()
        velockApp.launch()
        tutorialUnlock()
        tutorialTap(tutorialRootTab(["tkNav_files", "文件", "File", "Files"]), "import-text-files")
        // Exact button matching avoids the empty-state message containing “添加”.
        let add = tutorialNode(velockApp, ["tkBtn_files_add", "添加", "Add"], buttons: true)
        if add.exists && add.isHittable { add.tap() }
        else {
            // Observed unlabeled production toolbar button: (364,64,28,28).
            XCTAssertEqual(velockApp.frame.width, 440, accuracy: 1)
            XCTAssertEqual(velockApp.frame.height, 956, accuracy: 1)
            velockApp.coordinate(withNormalizedOffset: CGVector(dx: 378.0/440.0, dy: 78.0/956.0)).tap()
        }
        let picker = tutorialNode(velockApp, ["浏览", "Browse", "最近项目", "Recents"])
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "File picker did not open")
        try velockApp.debugDescription.write(toFile: root + "/picker-state.txt", atomically: true, encoding: .utf8)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: root + "/picker.png"))
        // Scope to the native picker: the obscured Flutter file grid remains
        // in the AX tree and must never satisfy a source-file selector.
        // A genuinely new device opens Recents, not the retained Browse folder.
        let browseTab = velockApp.tabBars["DOC.browsingModeTabBar"].buttons.matching(
            NSPredicate(format: "label IN %@", ["浏览", "Browse"])).firstMatch
        if browseTab.exists && browseTab.isHittable { browseTab.tap() }
        let localStorage = tutorialNode(velockApp, ["我的 iPhone", "我的iPhone", "On My iPhone"])
        if localStorage.waitForExistence(timeout: 2) && localStorage.isHittable { localStorage.tap() }
        let browser = velockApp.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'Browse View (Picker)' OR identifier BEGINSWITH 'DOC.browsingRoot'"
        )).firstMatch
        tutorialReady(browser, "native-picker-root")
        let host = browser.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'CrossAppUITestHost'" )).firstMatch
        if host.waitForExistence(timeout: 2) && host.isHittable { host.tap() }
        let folder = browser.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'VelockSync-E2E-Source'" )).firstMatch
        if folder.waitForExistence(timeout: 2) && folder.isHittable { folder.tap() }
        try browser.debugDescription.write(toFile: root + "/picker-source-state.txt", atomically: true, encoding: .utf8)
        let textFile = browser.cells.matching(NSPredicate(
            format: "(label CONTAINS 'proof' OR identifier CONTAINS 'proof') AND (label CONTAINS[c] 'txt' OR label CONTAINS '文本' OR identifier CONTAINS[c] 'txt')")).firstMatch
        tutorialTap(textFile, "select-proof-text")
        let open = browser.buttons.matching(NSPredicate(format: "label IN %@", ["打开", "Open", "完成", "Done"])).firstMatch
        if open.waitForExistence(timeout: 2) && open.isHittable { open.tap() }
        let imported = velockApp.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'file-item-' AND label == 'velock-sync-e2e-proof.txt'")).firstMatch
        tutorialReady(imported, "text-persisted", timeout: 30)
    }

    func testTutorialPrepareCredentials() throws {
        guard ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] != nil else {
            throw XCTSkip("Explicit preparation only")
        }
        prepareFixtureHost()
        velockApp.launch()
        tutorialUnlock()
        seedVelockBusinessDataIfRequested()
    }

    func testTutorialInspectState() throws {
        guard let root = ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] else {
            throw XCTSkip("Explicit diagnostic only")
        }
        velockApp.launch()
        tutorialUnlock()
        try velockApp.debugDescription.write(toFile: root + "/state.txt", atomically: true, encoding: .utf8)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: root + "/state.png"))
    }

    func testTutorialPrepareEnglish() throws {
        guard ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] != nil else {
            throw XCTSkip("Explicit preparation only")
        }
        velockApp.launch()
        tutorialUnlock()
        tutorialPrepareEnglishSource()
    }

    func testTutorialPreparedSource() throws {
        guard ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] != nil else {
            throw XCTSkip("Tutorial diagnostics are explicitly opt-in")
        }
        velockApp.launch()
        tutorialUnlock()
        tutorialTap(tutorialContains(velockApp, ["凭证", "Credentials"]), "prepared-credentials")
        tutorialTap(tutorialContains(velockApp, ["E2E Password"]), "prepared-password")
        tutorialReady(tutorialContains(velockApp, ["e2e-user"]), "prepared-content")
    }

    override func tearDown() {
        syncApp?.terminate()
        velockApp?.terminate()
        syncApp = nil
        velockApp = nil
    }

    /// Visual verification for the four root tabs. The tabs are selected through
    /// the actual iOS accessibility tree so a screenshot cannot accidentally
    /// be captured from the dashboard route while claiming to be another tab.
    func testFourHomeTabsHaveNoTitles() {
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))

        tapHomeTab("同步", normalizedX: 0.125, screenshotName: "tab-sync-no-title-verified")
        tapHomeTab("连接", normalizedX: 0.375, screenshotName: "tab-connections-no-title-verified")
        tapHomeTab("活动", normalizedX: 0.625, screenshotName: "tab-activity-no-title-verified")
        tapHomeTab("设置", normalizedX: 0.875, screenshotName: "tab-settings-no-title-verified")
    }

    func testDeletionProtectionSettingsVisible() {
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
        tapHomeTab(
            "设置",
            normalizedX: 0.875,
            screenshotName: "deletion-protection-settings"
        )
        XCTAssertTrue(
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '删除保护'")
            ).firstMatch.waitForExistence(timeout: 20),
            "Deletion protection card is missing: \(syncApp.debugDescription)"
        )
        // The badge is state-dependent by design ("尚未生效" until a trusted
        // checkpoint exists, then "已开启"), so this only pins that the card and
        // its rows are reachable; both badge states are covered by the widget
        // tests in test/features/sync_profiles.
        for row in ["最近清理", "等待确认", "活跃设备"] {
            XCTAssertTrue(
                syncApp.descendants(matching: .any).matching(
                    NSPredicate(format: "label CONTAINS %@", row)
                ).firstMatch.waitForExistence(timeout: 10),
                "Deletion protection row is missing: \(row)"
            )
        }
        attachScreenshot("deletion-protection-settings-verified")
    }

    private func tapHomeTab(
        _ label: String,
        normalizedX: CGFloat,
        screenshotName: String
    ) {
        let tab = syncApp.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "\(label)\n")
        ).firstMatch
        if tab.waitForExistence(timeout: 5) && tab.isHittable {
            tab.tap()
        } else {
            syncApp.coordinate(
                withNormalizedOffset: CGVector(dx: normalizedX, dy: 0.94)
            ).tap()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print("HOME_TAB_\(label)_BEGIN\n\(syncApp.debugDescription)\nHOME_TAB_\(label)_END")
        attachScreenshot(screenshotName)
    }

    /// Captures every currently reachable product route without changing
    /// persistent app data. Each flow starts from a fresh app process so a
    /// failed or cancelled form cannot contaminate the next screenshot.
    func testCaptureAllProductPages() {
        launchSyncFresh()
        attachScreenshot("page-sync-home-entry")

        tapHomeTab("同步", normalizedX: 0.125, screenshotName: "page-sync-home-all")
        tapFirstContaining("开启格间备份")
        waitForAnyText("开始连接格间")
        attachScreenshot("page-sync-profile-wizard")

        tapFirstContaining("开始连接格间")
        // A clean simulator may not have a configured Velock pairing channel;
        // both the actionable pairing dialog and the explicit unavailable state
        // are valid product pages. The old generic dataset picker must never
        // appear in the Velock-first flow.
        let pairingOrUnavailable = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '开始配对' OR label CONTAINS '配对通道尚未配置' OR label CONTAINS '格间授权'")
        ).firstMatch
        XCTAssertTrue(pairingOrUnavailable.waitForExistence(timeout: 15), "Velock entry did not expose a pairing state")
        attachScreenshot("page-sync-velock-pairing-state")

        launchSyncFresh()
        tapHomeTab("连接", normalizedX: 0.375, screenshotName: "page-connections")
        tapFirstContaining("新建连接")
        waitForAnyText("保存到哪里")
        attachScreenshot("page-protocols")
        tapFirstContaining("详细配置说明")
        waitForAnyText("远端服务配置说明")
        attachScreenshot("page-connection-help")

        launchSyncFresh()
        openNewConnectionProtocols()
        tapFirstContaining("WebDAV")
        waitForAnyText("服务器地址")
        attachScreenshot("page-new-webdav")
        openConnectionHelp(marker: "WebDAV 配置说明")
        attachScreenshot("page-new-webdav-guide")

        launchSyncFresh()
        openNewConnectionProtocols()
        tapFirstContaining("Google Drive")
        waitForAnyText("Google Drive")
        attachScreenshot("page-new-google-drive")
        openConnectionHelp(marker: "Google Drive 配置说明")
        attachScreenshot("page-new-google-drive-guide")

        launchSyncFresh()
        openNewConnectionProtocols()
        tapFirstContaining("OneDrive")
        waitForAnyText("OneDrive")
        attachScreenshot("page-new-onedrive")
        openConnectionHelp(marker: "OneDrive 配置说明")
        attachScreenshot("page-new-onedrive-guide")

        launchSyncFresh()
        openNewConnectionProtocols()
        tapFirstContaining("百度网盘")
        waitForAnyText("Access Token")
        attachScreenshot("page-new-baidu-token")
        openConnectionHelp(marker: "百度网盘 配置说明")
        attachScreenshot("page-new-baidu-token-guide")

        launchSyncFresh()
        tapHomeTab("连接", normalizedX: 0.375, screenshotName: "page-connections-detail-entry")
        // The audited connection's host comes from the environment so no real
        // server address has to live in this public repository.
        let connectionHost =
            ProcessInfo.processInfo.environment["E2E_AUDIT_CONNECTION_HOST"] ?? "nas.example.com"
        let connection = syncApp.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", connectionHost)
        ).firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 10))
        connection.tap()
        // Connection details load their remote-browser state asynchronously;
        // capture the real resulting page even when the configured endpoint
        // cannot be reached by the simulator.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        attachScreenshot("page-connection-detail")

        launchSyncFresh()
        tapHomeTab("同步", normalizedX: 0.125, screenshotName: "page-sync-detail-entry")
        let profile = syncApp.buttons.matching(
            NSPredicate(format: "label CONTAINS 'test1 的 Velock'")
        ).firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        profile.tap()
        waitForAnyText("概览")
        attachScreenshot("page-sync-detail-overview")
    }

    /// Focused visual check for the newly exposed Baidu credential flow. The
    /// broader route capture above remains the full product-page sweep; this
    /// focused test keeps credential-page regressions quick to diagnose.
    func testCaptureBaiduTokenPages() {
        launchSyncFresh()
        openNewConnectionProtocols()
        tapFirstContaining("百度网盘")
        waitForAnyText("Access Token")
        attachScreenshot("page-new-baidu-token")
        openConnectionHelp(marker: "百度网盘 配置说明")
        attachScreenshot("page-new-baidu-token-guide")
    }

    private func openNewConnectionProtocols() {
        tapHomeTab("连接", normalizedX: 0.375, screenshotName: "page-connections-entry")
        tapFirstContaining("新建连接")
        waitForAnyText("保存到哪里")
    }

    private func openConnectionHelp(marker: String) {
        let helpButton = syncApp.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "说明")
        ).firstMatch
        XCTAssertTrue(helpButton.waitForExistence(timeout: 5), "Missing connection help entry")
        XCTAssertTrue(helpButton.isHittable, "Connection help entry is not tappable")
        helpButton.tap()
        waitForAnyText(marker)
    }

    private func launchSyncFresh() {
        syncApp.terminate()
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
    }

    /// Pops any pushed settings/wizard routes until the dashboard tabs show.
    private func returnToVelockDashboard() {
        for _ in 0..<5 {
            if velockApp.buttons.matching(
                NSPredicate(format: "label CONTAINS '凭证'")
            ).firstMatch.exists {
                return
            }
            velockApp.coordinate(
                withNormalizedOffset: CGVector(dx: 0.06, dy: 0.09)
            ).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
    }

    /// Opens the credential create sheet from the credentials browser.
    ///
    /// The button carries an accessibility label now; the coordinate tap stays
    /// as a fallback for simulator runtimes whose semantics lag a frame.
    private func tapCreateCredential() {
        let create = velockApp.buttons["创建"].firstMatch
        if create.waitForExistence(timeout: 3) && create.isHittable {
            create.tap()
            return
        }
        velockApp.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.07)).tap()
    }

    private func tapFirstContaining(_ label: String) {
        let button = syncApp.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", label)
        ).firstMatch
        if button.waitForExistence(timeout: 10) && button.isHittable {
            button.tap()
            return
        }
        let text = syncApp.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", label)
        ).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "Missing UI label: \(label)")
        text.tap()
    }

    private func waitForAnyText(_ label: String) {
        let element = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", label)
        ).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 15), "Missing page marker: \(label)")
    }

    /// Diagnostic only. This is intentionally excluded from the final E2E run.
    /// It records the accessibility hierarchy used to build stable black-box
    /// selectors for the dedicated Velock sync entry flow.
    func testProbeVelockSyncEntry() {
        launchSyncFresh()
        tapHomeTab("同步", normalizedX: 0.125, screenshotName: "velock-entry-home")
        let entry = waitForAny(
            syncApp.buttons["velock-backup-enable"].firstMatch,
            syncApp.buttons.matching(
                NSPredicate(format: "label CONTAINS '开启格间备份'")
            ).firstMatch,
            timeout: 10
        )
        XCTAssertTrue(entry.exists, "Sync home did not expose the 格间 backup entry")
        entry.tap()
        XCTAssertTrue(
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '开始连接格间'")
            ).firstMatch.waitForExistence(timeout: 10),
            "Velock Sync did not enter the dedicated Velock flow"
        )
        XCTAssertFalse(
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '选择数据集'")
            ).firstMatch.exists,
            "The old generic dataset flow is still exposed"
        )
        attachScreenshot("velock-entry-wizard")
    }

    /// Diagnostic only (2026-09-19 E2E triage). Dumps the accessibility tree
    /// of the Connections tab and the folder-sync remote-connection sheet so
    /// the black-box selectors in testSelectedFolderSourceSync can be kept in
    /// sync with the current UI. Excluded from the scripted E2E runs.
    func testProbeConnectionPickerTree() {
        launchSyncFresh()
        tapHomeTab("连接", normalizedX: 0.375, screenshotName: "probe-connections-tab")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        print("PROBE_CONNECTIONS_TAB_BEGIN")
        print(syncApp.debugDescription)
        print("PROBE_CONNECTIONS_TAB_END")
        attachScreenshot("probe-connections-tab-settled")

        tapHomeTab("同步", normalizedX: 0.125, screenshotName: "probe-sync-home")
        let create = largestButton(in: syncApp, containing: "新建同步")
        XCTAssertTrue(create.waitForExistence(timeout: 10), "Sync home did not expose create")
        create.tap()
        tapFirstContaining("同步文件夹")
        let addFolder = firstExisting(
            syncApp.buttons["添加同步文件夹"],
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '添加同步文件夹'")
            ).firstMatch
        )
        XCTAssertTrue(addFolder.waitForExistence(timeout: 10), "Folder sync page did not expose add")
        addFolder.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        print("PROBE_PICKER_SHEET_BEGIN")
        print(syncApp.debugDescription)
        print("PROBE_PICKER_SHEET_END")
        attachScreenshot("probe-picker-sheet")
    }

    /// Upload-side setup through the real UI. This intentionally stops after
    /// persisting the WebDAV connection so later probes can inspect the next
    /// product surface without coupling connection diagnosis to folder-picker
    /// diagnosis.
    func testCreateWebDAVConnection() {
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))

        let connectionsTab = firstExisting(
            syncApp.staticTexts["Connections"],
            syncApp.staticTexts["连接"],
            syncApp.buttons["Connections"],
            syncApp.buttons["连接"]
        )
        XCTAssertTrue(connectionsTab.waitForExistence(timeout: 10), "Connections tab was not exposed")
        connectionsTab.tap()
        if syncApp.descendants(matching: .any)["新建连接"]
            .waitForExistence(timeout: 3) {
            attachScreenshot("webdav_connection_reused")
            return
        }
        XCTAssertTrue(
            syncApp.descendants(matching: .any)["没有连接的服务"]
                .waitForExistence(timeout: 10),
            "Expected a clean upload-side Connections screen"
        )

        let addConnection = syncApp.buttons.element(boundBy: 0)
        XCTAssertTrue(addConnection.waitForExistence(timeout: 5))
        XCTAssertTrue(addConnection.isHittable)
        addConnection.tap()

        let protocolChoice = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '选择协议' OR label CONTAINS '选择远端协议'")
        ).firstMatch
        XCTAssertTrue(protocolChoice.waitForExistence(timeout: 5))
        protocolChoice.tap()

        let webDAV = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'WebDAV'")
        ).firstMatch
        XCTAssertTrue(webDAV.waitForExistence(timeout: 5))
        webDAV.tap()

        let httpsSwitch = syncApp.switches.firstMatch
        XCTAssertTrue(httpsSwitch.waitForExistence(timeout: 5))
        httpsSwitch.tap()
        let allowHTTP = syncApp.buttons["仍然使用 HTTP"]
        XCTAssertTrue(allowHTTP.waitForExistence(timeout: 5))
        allowHTTP.tap()

        let fields = syncApp.textFields
        XCTAssertGreaterThanOrEqual(fields.count, 2, "WebDAV form needs address and port fields")
        let address = fields.element(boundBy: 0)
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("127.0.0.1")

        let port = fields.element(boundBy: 1)
        port.tap()
        port.typeText(webDAVPort)

        let save = syncApp.buttons["保存"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()

        XCTAssertTrue(
            syncApp.descendants(matching: .any)["已连接服务"]
                .waitForExistence(timeout: 20),
            "Saving WebDAV should return to Connections with a persisted item"
        )
        XCTAssertTrue(
            syncApp.descendants(matching: .any)["新建连接"]
                .waitForExistence(timeout: 10),
            "Persisted WebDAV connection was not visible"
        )
        attachScreenshot("webdav_connection_created")
    }

    /// End-to-end selected-folder source flow on simulators only. It creates
    /// the real WebDAV connection, chooses the fixture folder through the iOS
    /// document picker, provisions a Generic Vault profile, and runs the first
    /// encrypted upload through the shared Sync Core.
    func testSelectedFolderSourceSync() {
        logTestEnvironmentIfFirst()
        prepareFixtureHost()
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
        createLocalWebDAVConnectionIfNeeded()
        tapHomeTab("同步", normalizedX: 0.125, screenshotName: "selected-folder-home")

        let existingProfile = syncApp.buttons.matching(
            NSPredicate(format: "label BEGINSWITH '同步文件夹'")
        ).firstMatch
        if !existingProfile.waitForExistence(timeout: 3) {
            let create = largestButton(in: syncApp, containing: "新建同步")
            XCTAssertTrue(create.waitForExistence(timeout: 10), "Sync home did not expose create")
            create.tap()

            XCTAssertTrue(
                syncApp.staticTexts["新建同步"].waitForExistence(timeout: 10),
                "New sync category page did not open: \(syncApp.debugDescription)"
            )
            print("NEW_SYNC_PAGE_BEGIN\n\(syncApp.debugDescription)\nNEW_SYNC_PAGE_END")
            tapFirstContaining("同步文件夹")

            let addFolder = firstExisting(
                syncApp.buttons["添加同步文件夹"],
                syncApp.descendants(matching: .any).matching(
                    NSPredicate(format: "label CONTAINS '添加同步文件夹'")
                ).firstMatch
            )
            XCTAssertTrue(addFolder.waitForExistence(timeout: 10), "Folder sync page did not expose add")
            addFolder.tap()

            tapRemoteConnectionInPicker(context: "source-sync")

            selectFixtureFolder(named: "VelockSync-E2E-Source")
            XCTAssertTrue(
                syncApp.staticTexts["已创建“同步文件夹”。"].waitForExistence(timeout: 20),
                "Selecting Source did not create the folder sync profile"
            )
            XCTAssertFalse(
                syncApp.staticTexts["创建同步文件夹失败。"].exists,
                "Folder sync profile creation failed"
            )

            // The legacy folder list can be mid-refresh after creating its
            // first profile. Relaunching verifies durable persistence and
            // returns to the canonical Sync home list.
            syncApp.terminate()
            syncApp.launch()
            XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 30))
        }

        tapHomeTab(
            "同步",
            normalizedX: 0.125,
            screenshotName: "selected-folder-profile-persisted"
        )
        let syncNow = syncApp.buttons.matching(
            NSPredicate(format: "label BEGINSWITH '立即同步'")
        ).firstMatch
        if !syncNow.exists {
            let profileButton = syncApp.buttons.matching(
                NSPredicate(format: "label CONTAINS '同步配置操作'")
            ).firstMatch
            if !profileButton.waitForExistence(timeout: 15) {
                writeDebugTree(syncApp.debugDescription, name: "profile-unavailable")
            }
            XCTAssertTrue(
                profileButton.waitForExistence(timeout: 5),
                "Folder sync profile was unavailable"
            )
            profileButton.coordinate(
                withNormalizedOffset: CGVector(dx: 0.22, dy: 0.5)
            ).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            writeDebugTree(syncApp.debugDescription, name: "after-profile-tap")
        }

        XCTAssertTrue(syncNow.waitForExistence(timeout: 10), "Profile detail did not expose immediate sync")
        syncNow.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        writeDebugTree(syncApp.debugDescription, name: "after-sync-tap")

        let confirmation = syncApp.staticTexts["确认首次同步"]
        if confirmation.waitForExistence(timeout: 1) {
            let confirm = syncApp.buttons["确认并同步"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()
        }

        let uploaded = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '已完成 · '")
        ).firstMatch
        let failure = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH '同步失败'")
        ).firstMatch
        let result = waitForOutcome(success: uploaded, failure: failure, timeout: 90)
        if result != .success {
            writeDebugTree(syncApp.debugDescription, name: "sync-failure")
            print("SELECTED_FOLDER_SYNC_FAILURE_BEGIN\n\(syncApp.debugDescription)\nSELECTED_FOLDER_SYNC_FAILURE_END")
            attachScreenshot("selected-folder-sync-failure")
        }
        XCTAssertEqual(result, .success, "Selected Folder source upload did not complete")
        print("E2E_SELECTED_FOLDER_UPLOAD=\(uploaded.label)")
        attachScreenshot("selected-folder-sync-completed")
    }

    /// Exports the source Generic Vault recovery bundle into a caller-provided
    /// mode-0600 file. The package and passphrase never enter XCTest output.
    func testExportSelectedFolderRecoveryPackage() throws {
        logTestEnvironmentIfFirst()
        let environment = ProcessInfo.processInfo.environment
        guard let passphrase = environment["E2E_RECOVERY_PASSPHRASE"], !passphrase.isEmpty,
              let outputPath = environment["E2E_RECOVERY_PACKAGE_FILE"], !outputPath.isEmpty else {
            XCTFail("Secure recovery runtime inputs are missing")
            return
        }

        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
        tapHomeTab("同步", normalizedX: 0.125, screenshotName: "selected-folder-export-home")

        let profileButton = syncApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '同步配置操作'")
        ).firstMatch
        XCTAssertTrue(profileButton.waitForExistence(timeout: 15), "Folder sync profile was unavailable")
        profileButton.coordinate(
            withNormalizedOffset: CGVector(dx: 0.22, dy: 0.5)
        ).tap()

        let settingsTab = syncApp.buttons.matching(
            NSPredicate(format: "label BEGINSWITH '设置'")
        ).firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10), "Profile settings tab was unavailable")
        settingsTab.tap()

        let exportRecovery = syncApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '生成恢复包'")
        ).firstMatch
        if !exportRecovery.waitForExistence(timeout: 10) {
            writeDebugTree(syncApp.debugDescription, name: "export-settings")
        }
        XCTAssertTrue(exportRecovery.waitForExistence(timeout: 5), "Recovery export was unavailable")
        exportRecovery.tap()

        for field in [
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label == '恢复口令'")
            ).firstMatch,
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label == '再次输入恢复口令'")
            ).firstMatch,
        ] {
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(passphrase)
        }

        let generate = syncApp.buttons["生成"]
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        generate.tap()
        XCTAssertTrue(syncApp.staticTexts["一次性恢复包"].waitForExistence(timeout: 20))

        let packageElement = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'VLSR1.' OR value BEGINSWITH 'VLSR1.'")
        ).firstMatch
        XCTAssertTrue(packageElement.waitForExistence(timeout: 10))
        let package = [packageElement.value as? String, packageElement.label]
            .compactMap { $0 }
            .first(where: { $0.hasPrefix("VLSR1.") })
        guard let package, package.hasPrefix("VLSR1.") else {
            XCTFail("Recovery package content is invalid")
            return
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(
            atPath: outputPath,
            contents: Data(package.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            XCTFail("Could not persist the recovery handoff")
            return
        }
        syncApp.buttons["我已安全保存"].tap()
        print("E2E_SELECTED_FOLDER_RECOVERY_EXPORT=completed")
    }

    /// Fresh-replica selected-folder recovery. It imports the secure bundle,
    /// selects the replica folder, then downloads and verifies the fixture.
    func testRecoverSelectedFolderReplica() throws {
        logTestEnvironmentIfFirst()
        let environment = ProcessInfo.processInfo.environment
        guard let passphrase = environment["E2E_RECOVERY_PASSPHRASE"], !passphrase.isEmpty,
              let packagePath = environment["E2E_RECOVERY_PACKAGE_FILE"], !packagePath.isEmpty,
              let vaultID = environment["E2E_VAULT_ID"], !vaultID.isEmpty else {
            XCTFail("Replica recovery runtime inputs are missing")
            return
        }
        let package = try String(contentsOfFile: packagePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(package.hasPrefix("VLSR1."))

        prepareFixtureHost()
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
        createLocalWebDAVConnectionIfNeeded()
        openSelectedFolderProfileList(screenshotName: "selected-folder-replica-home")

        // The folder-sync page shows either the list tile
        // “通过恢复包加入已有空间” or the first-run empty-state button
        // “已有同步空间？/通过恢复包加入”; match the shared phrase.
        let recover = firstExisting(
            syncApp.buttons["通过恢复包加入已有空间"],
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '通过恢复包加入'")
            ).firstMatch
        )
        XCTAssertTrue(recover.waitForExistence(timeout: 10), "Recovery entry was not exposed\n\(syncApp.debugDescription)")
        recover.tap()

        tapRemoteConnectionInPicker(context: "replica-recover")

        let vaultField = syncApp.textFields["Vault ID"]
        XCTAssertTrue(vaultField.waitForExistence(timeout: 5))
        vaultField.tap()
        vaultField.typeText(vaultID)

        // The field renders with its placeholder text as the visible label;
        // match the VLSR1 marker shared by both placeholder and caption.
        let packageField = waitForAny(
            syncApp.textViews.matching(
                NSPredicate(format: "label CONTAINS 'VLSR1'")
            ).firstMatch,
            syncApp.textFields.matching(
                NSPredicate(format: "label CONTAINS 'VLSR1'")
            ).firstMatch,
            timeout: 10
        )
        XCTAssertTrue(packageField.exists, "Recovery package field was not exposed\n\(syncApp.debugDescription)")
        packageField.tap()
        packageField.typeText(package)

        let passphraseField = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label == '恢复口令'")
        ).firstMatch
        XCTAssertTrue(passphraseField.waitForExistence(timeout: 5))
        passphraseField.tap()
        passphraseField.typeText(passphrase)

        let continueToFolder = syncApp.buttons["继续选择文件夹"]
        XCTAssertTrue(continueToFolder.waitForExistence(timeout: 5))
        continueToFolder.tap()
        selectFixtureFolder(named: "VelockSync-E2E-Replica")

        XCTAssertTrue(
            syncApp.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH '已加入“已恢复的同步文件夹”'")
            ).firstMatch.waitForExistence(timeout: 20),
            "Replica profile recovery did not complete"
        )

        syncApp.terminate()
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 30))
        tapHomeTab("同步", normalizedX: 0.125, screenshotName: "selected-folder-replica-persisted")

        let profileButton = syncApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '已恢复的同步文件夹' AND label CONTAINS '同步配置操作'")
        ).firstMatch
        XCTAssertTrue(profileButton.waitForExistence(timeout: 15))
        profileButton.coordinate(
            withNormalizedOffset: CGVector(dx: 0.22, dy: 0.5)
        ).tap()

        let syncNow = syncApp.buttons.matching(
            NSPredicate(format: "label BEGINSWITH '立即同步'")
        ).firstMatch
        XCTAssertTrue(syncNow.waitForExistence(timeout: 10))
        syncNow.tap()

        let confirmation = syncApp.staticTexts["确认加入已有同步空间"]
        if confirmation.waitForExistence(timeout: 2) {
            let confirm = syncApp.buttons["确认并同步"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()
        }

        let completed = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '已完成 · '")
        ).firstMatch
        let failure = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH '同步失败'")
        ).firstMatch
        let result = waitForOutcome(success: completed, failure: failure, timeout: 90)
        XCTAssertEqual(result, .success, "Selected Folder replica download did not complete")
        attachScreenshot("selected-folder-replica-sync-completed")
        verifyReplicaFixtureIntegrity()
        print("E2E_SELECTED_FOLDER_REPLICA=completed")
    }

    /// Diagnostic only. Records the non-sensitive controls on the persisted
    /// profile so the recovery-package action can be driven without relying on
    /// a guessed icon position. It deliberately stops before opening the
    /// passphrase dialog.
    func testProbeRecoveryPackageControl() {
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))

        let profile = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH '同步文件夹'")
        ).firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 10))

        for index in 0..<syncApp.buttons.count {
            let button = syncApp.buttons.element(boundBy: index)
            print("E2E_RECOVERY_CONTROL_BUTTON index=\(index) label=\(button.label) frame=\(button.frame)")
        }

        let actions = syncApp.buttons["同步配置操作"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        XCTAssertTrue(actions.isHittable)
        actions.tap()

        let exportRecovery = syncApp.descendants(matching: .any)["生成恢复包"]
        XCTAssertTrue(exportRecovery.waitForExistence(timeout: 5))
        exportRecovery.tap()
        XCTAssertTrue(
            syncApp.staticTexts["生成恢复包"].waitForExistence(timeout: 5),
            "The derived key-action coordinate did not open the recovery prompt"
        )
        attachScreenshot("recovery_package_passphrase_prompt")
    }

    /// Verifies the restored bytes within the same test invocation. Starting a
    /// second XCTest invocation may reinstall the fixture host and reset its
    /// Documents container before it can inspect the downloaded file.
    private func verifyReplicaFixtureIntegrity() {
        let fixtureApp = XCUIApplication(bundleIdentifier: fixtureHostBundleID)
        fixtureApp.launch()
        XCTAssertTrue(fixtureApp.wait(for: .runningForeground, timeout: 20))

        let details = fixtureApp.descendants(matching: .any)["fixture-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 10), "Fixture details were unavailable")
        let report = details.label
        XCTAssertTrue(report.contains("Replica restored: yes"), "Replica proof file is missing")

        let sourceHash = captureValue(named: "Source SHA-256", in: report)
        let replicaHash = captureValue(named: "Replica SHA-256", in: report)
        let sourceBytes = captureValue(named: "Source bytes", in: report)
        let replicaBytes = captureValue(named: "Replica bytes", in: report)
        XCTAssertNotNil(sourceHash)
        XCTAssertNotNil(replicaHash)
        XCTAssertEqual(replicaHash, sourceHash, "Replica proof file hash differs from source")
        XCTAssertEqual(replicaBytes, sourceBytes, "Replica proof file byte count differs from source")
        attachScreenshot("replica_fixture_integrity_verified")
        fixtureApp.terminate()
    }

    /// Creates representative business data through 格间's real UI. This is
    /// intentionally kept in the UI harness (rather than inserting rows into
    /// the database) so the subsequent sync run exercises the same records a
    /// user creates. The script enables it only on the source simulator.
    private func seedVelockBusinessDataIfRequested() {
        if tutorialSeedPrepared { return }
        guard ProcessInfo.processInfo.environment["E2E_SEED_DATA"] == "1" else {
            return
        }
        // Pairing enablement ends on the protected settings page. Return to
        // the authenticated dashboard before creating business records.
        let home = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '首页'" )
        ).firstMatch
        if !home.waitForExistence(timeout: 5) {
            // The settings flow is presented as a nested Cupertino route and
            // does not expose the dashboard tab until it is popped.
            for _ in 0..<4 {
                if velockApp.buttons.matching(NSPredicate(format: "label CONTAINS '首页'" )).firstMatch.exists { break }
                velockApp.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.09)).tap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
        }
        let dashboard = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '首页'" )
        ).firstMatch
        if dashboard.waitForExistence(timeout: 5) { dashboard.tap() }
        let credentials = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '凭证'" )
        ).firstMatch
        XCTAssertTrue(credentials.waitForExistence(timeout: 10))
        credentials.tap()

        // Account/password credential. Keep incremental runs idempotent: an
        // already-created fixture is real source data and must not be replaced
        // merely because the test is being resumed.
        let existingPassword = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'E2E Password'")
        ).firstMatch
        if !existingPassword.waitForExistence(timeout: 3) {
            tapCreateCredential()
            XCTAssertTrue(velockApp.buttons["账号密码"].waitForExistence(timeout: 5))
            velockApp.buttons["账号密码"].tap()
            XCTAssertTrue(velockApp.textFields["请输入标题"].waitForExistence(timeout: 10))
            velockApp.textFields["请输入标题"].tap(); velockApp.textFields["请输入标题"].typeText("E2E Password")
            let account = velockApp.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '请输入账号'" )).firstMatch
            let password = velockApp.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '请输入密码'" )).firstMatch
            XCTAssertTrue(account.exists); XCTAssertTrue(password.exists)
            account.tap(); velockApp.typeText("e2e-user")
            password.tap(); velockApp.typeText("e2e-secret")
            velockApp.buttons["保存"].firstMatch.tap()
            requireInVelock(velockApp.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'E2E Password'" )).firstMatch, "Password credential was not saved", timeout: 45)
        }

        // Ordinary bank-card regressions retain their fixture. The full
        // tutorial explicitly uses a separate synthetic credit-card example.
        let creditCardFixture = ProcessInfo.processInfo.environment["E2E_SEED_CREDIT_CARD"] == "1"
        let cardTitle = creditCardFixture ? "E2E Credit Card" : "E2E Card"
        let cardDigits = creditCardFixture ? "4111111111111111" : "6222021234567890"
        let cardTab = velockApp.buttons["卡片"].firstMatch.exists
            ? velockApp.buttons["卡片"].firstMatch
            : velockApp.buttons["银行卡"].firstMatch
        if cardTab.waitForExistence(timeout: 3) { cardTab.tap() }
        let existingCard = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", cardTitle)
        ).firstMatch
        if !existingCard.waitForExistence(timeout: 3) {
            tapCreateCredential()
            XCTAssertTrue(velockApp.buttons["银行卡"].waitForExistence(timeout: 5))
            velockApp.buttons["银行卡"].tap()
            XCTAssertTrue(velockApp.textFields["请输入标题"].waitForExistence(timeout: 10))
            velockApp.textFields["请输入标题"].tap(); velockApp.textFields["请输入标题"].typeText(cardTitle)
            // The card group's value field is rendered by a custom PlatformTextField
            // without a stable AX label. Its first value row is fixed below the
            // title on the iPhone layout; tap the real field rather than matching
            // the adjacent static label “卡号”.
            velockApp.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.28)).tap()
            velockApp.typeText(cardDigits)
            velockApp.buttons["保存"].firstMatch.tap()
            requireInVelock(velockApp.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", cardTitle)).firstMatch, "Card editor did not return to credentials")
        }

        // Note credential. The iOS 26 simulator's software keyboard exposes
        // Quill's editor as a non-focusable custom surface; keep this seed
        // opt-in until that platform automation issue is fixed, rather than
        // blocking validation of the rest of the sync pipeline.
        guard ProcessInfo.processInfo.environment["E2E_SEED_NOTE"] == "1" else {
            attachScreenshot("source_business_data_seeded")
            return
        }
        velockApp.buttons["备注"].tap()
        // The browser now has a single labeled create entry that opens a type
        // sheet, so pick the note type from that sheet instead of the removed
        // per-type debug identifiers.
        tapCreateCredential()
        if velockApp.buttons["账号密码"].firstMatch.waitForExistence(timeout: 3) {
            let noteOption = velockApp.buttons["备注"].firstMatch
            XCTAssertTrue(
                noteOption.waitForExistence(timeout: 5),
                "Create sheet did not expose the note entry\n\(velockApp.debugDescription)"
            )
            noteOption.tap()
        }
        XCTAssertTrue(velockApp.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '新建备注' OR label CONTAINS '创建笔记' OR label CONTAINS '新建笔记'" )).firstMatch.waitForExistence(timeout: 10), "Note editor missing\n\(velockApp.debugDescription)")
        // Explicit debug fixture only replaces Quill text entry. Save and
        // subsequent encrypted persistence remain real application operations.
        let fixtureInput = velockApp.descendants(matching: .any)["e2e-fill-note-fixture"]
        XCTAssertTrue(fixtureInput.waitForExistence(timeout: 5),
                      "Build with --dart-define=VELOCK_E2E_FIXTURES=true; fixture entry is debug-only")
        fixtureInput.tap()
        velockApp.buttons["保存"].firstMatch.tap()
        XCTAssertTrue(fixtureInput.waitForNonExistence(timeout: 30),
                      "Note save did not finish; editor/error remains: \(velockApp.debugDescription)")
        XCTAssertTrue(velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS 'E2E note content'")
        ).firstMatch.waitForExistence(timeout: 10),
                      "Saved note missing from browser: \(velockApp.debugDescription)")
        XCTAssertTrue(velockApp.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'E2E note content'" )).firstMatch.waitForExistence(timeout: 10), "Note credential was not saved")
        attachScreenshot("source_business_data_seeded")
    }

    /// Cold-start helper: unlock the existing space and turn on
    /// 「允许新的配对」 so the companion Sync app can pair.
    func testEnableVelockPairingOnly() {
        ensureVelockInitializedAndPairingEnabled(refreshRecoveryCard: false)
        attachScreenshot("velock-pairing-enabled")
    }

    /// Redesigned backup entry (格间 tab → 开始备份 → 1 · 连接格间): starts the
    /// pairing from Sync, unlocks 格间 and allows the request in one go so the
    /// companion never backgrounds (and relocks) in between. Stops once Sync
    /// is back in the foreground; cloud location and first backup are driven
    /// separately. Does not reset either app.
    /// Backup smoke test driven only by accessibility identifiers (Flutter
    /// widget keys published through `withAutomationId`), so copy edits and
    /// the language setting do not break it.
    ///
    /// With an existing backup it runs “立即备份”. Otherwise it pairs with 格间
    /// (unlocking with VELOCK_RUNTIME_PASSWORD when needed), adds an HTTP
    /// WebDAV connection at 127.0.0.1:E2E_WEBDAV_PORT, uses the connection
    /// root and starts the first backup. Either way it passes only when the
    /// status card reports a completed backup.
    ///
    /// Run through `tool/ios_ui_test/sim/backup_smoke.sh`, which starts the
    /// local WebDAV server and checks the uploaded objects afterwards.
    func testBackupSmoke() {
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 15))

        let existing = element(syncApp, "backup-primary-action")
        let enable = element(syncApp, "velock-backup-enable")
        let deadline = Date().addingTimeInterval(20)
        while !existing.exists && !enable.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        if existing.exists {
            if !backupIsRunning() { existing.tap() }
        } else {
            guard enable.exists else {
                failWithTree("Home shows neither a backup nor the setup entry")
                return
            }
            enable.tap()
            smokePairWithVelock()
            smokeChooseDestination()
        }
        waitForCompletedBackup(timeout: 240)
        attachScreenshot("backup-smoke-done")
        let hold = Double(ProcessInfo.processInfo.environment["E2E_HOLD_SECONDS"] ?? "") ?? 0
        if hold > 0 { RunLoop.current.run(until: Date().addingTimeInterval(hold)) }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func tapWhenReady(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 15) {
        let target = element(app, id)
        guard target.waitForExistence(timeout: timeout) else {
            failWithTree("\(id) did not appear", app: app)
            return
        }
        target.tap()
    }

    /// Prints only nodes that have an identifier or a label; the full
    /// debugDescription is thousands of lines.
    private func failWithTree(_ message: String, app: XCUIApplication? = nil) {
        let target = app ?? syncApp!
        let lines = target.debugDescription
            .split(separator: "\n")
            .filter { $0.contains("identifier:") || $0.contains("label:") }
            .prefix(120)
            .joined(separator: "\n")
        attachScreenshot("backup-smoke-failure")
        XCTFail("\(message)\nSMOKE_TREE_BEGIN\n\(lines)\nSMOKE_TREE_END")
    }

    /// Waits for [element]; on timeout fails with the filtered 格间 tree so a
    /// broken step is diagnosable from run_test.sh output alone.
    @discardableResult
    private func requireInVelock(_ element: XCUIElement, _ message: String, timeout: TimeInterval = 10) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        failWithTree(message, app: velockApp)
        return false
    }

    private func backupIsRunning() -> Bool {
        let title = element(syncApp, "backup-status-title")
        return title.exists && ["正在传输，请稍候", "Transferring your data"].contains(title.label)
    }

    private func smokePairWithVelock() {
        let inspect = element(syncApp, "inspect-velock-readiness")
        let renew = element(syncApp, "renew-velock-authorization")
        let folder = element(syncApp, "use-backup-folder")
        let addStorage = element(syncApp, "go-create-connection")
        let deadline = Date().addingTimeInterval(20)
        // A request sent before Sync was terminated resumes on its own and
        // may already be approved.
        while Date() < deadline {
            if inspect.exists { inspect.tap(); break }
            if renew.exists { renew.tap(); break }
            if folder.exists || addStorage.exists { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<30 {
            if velockApp.state == .runningForeground { break }
            for owner in [syncApp!, springboard] {
                let open = owner.alerts.buttons.matching(
                    NSPredicate(format: "label IN %@", ["打开", "Open"])
                ).firstMatch
                if open.exists && open.isHittable { open.tap(); break }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        guard velockApp.wait(for: .runningForeground, timeout: 10) else {
            failWithTree("Sync did not open 格间")
            return
        }
        unlockVelockIfNeeded()
        tapWhenReady(velockApp, "approve-sync-request", timeout: 30)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        syncApp.activate()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 15))
    }

    private func smokeChooseDestination() {
        let folder = element(syncApp, "use-backup-folder")
        let addStorage = element(syncApp, "go-create-connection")
        let chooseExisting = element(syncApp, "continue-velock-setup")
        let portConnection = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'velock-connection-' AND label CONTAINS %@", ":\(webDAVPort)")
        ).firstMatch
        var addedConnection = false
        let deadline = Date().addingTimeInterval(90)
        while !folder.exists && Date() < deadline {
            if portConnection.exists {
                portConnection.tap()
            } else if chooseExisting.exists && chooseExisting.isHittable && addedConnection {
                chooseExisting.tap()
            } else if addStorage.exists && addStorage.isHittable && !addedConnection {
                // Add our own server even when other connections exist, so
                // the run never writes to a real NAS.
                addStorage.tap()
                addLocalWebDAVConnection()
                addedConnection = true
            } else if chooseExisting.exists && chooseExisting.isHittable {
                chooseExisting.tap()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        guard folder.exists else {
            failWithTree("The backup folder picker did not open")
            return
        }
        folder.tap()
        tapWhenReady(syncApp, "finalize-velock-profile")
    }

    private func addLocalWebDAVConnection() {
        tapWhenReady(syncApp, "protocol-webDav")
        tapWhenReady(syncApp, "webdav_https")
        tapWhenReady(syncApp, "webdav-allow-http", timeout: 5)
        // Turning HTTPS off rewrites the scheme to http://; type after it.
        tapWhenReady(syncApp, "webdav_address")
        syncApp.typeText("127.0.0.1")
        tapWhenReady(syncApp, "webdav_port")
        syncApp.typeText(webDAVPort)
        tapWhenReady(syncApp, "webdav-save")
    }

    private func waitForCompletedBackup(timeout: TimeInterval) {
        let done = ["上次备份已完成", "Last backup completed"]
        let title = element(syncApp, "backup-status-title")
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            if title.exists {
                last = title.label
                if done.contains(last) { return }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        failWithTree("Backup did not complete; last status: \(last.isEmpty ? "<none>" : last)")
    }

    /// Step driver for apps whose UI the scripted tests don't know (e.g. an
    /// old release in the upgrade check). E2E_STEPS is "||"-separated:
    /// launch | activate | unlock | tap:<label> | tapid:<id> | tapxy:<x>,<y>
    /// | type:<text> | wait:<s> | dump. A dump (debugDescription + PNG) is
    /// always written at the end into E2E_DRIVE_DIR.
    func testDriveSteps() throws {
        let env = ProcessInfo.processInfo.environment
        guard let steps = env["E2E_STEPS"], let dir = env["E2E_DRIVE_DIR"] else {
            throw XCTSkip("Explicit driver only")
        }
        let app: XCUIApplication = env["E2E_DRIVE_BUNDLE"].map { XCUIApplication(bundleIdentifier: $0) } ?? velockApp!
        var n = 0
        func dump() {
            n += 1
            try? app.debugDescription.write(toFile: "\(dir)/\(n).txt", atomically: true, encoding: .utf8)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(n).png"))
        }
        for raw in steps.components(separatedBy: "||") {
            let step = raw.trimmingCharacters(in: .whitespaces)
            let (cmd, arg): (String, String) = {
                guard let i = step.firstIndex(of: ":") else { return (step, "") }
                return (String(step[..<i]), String(step[step.index(after: i)...]))
            }()
            switch cmd {
            case "launch": app.launch(); _ = app.wait(for: .runningForeground, timeout: 20)
            case "activate": app.activate(); _ = app.wait(for: .runningForeground, timeout: 20)
            case "unlock": tutorialUnlock()
            case "tap", "tapany":
                let node = app.descendants(matching: .any).matching(
                    NSPredicate(format: "label == %@ OR identifier == %@", arg, arg)).firstMatch
                let loose = app.descendants(matching: .any).matching(
                    NSPredicate(format: "label BEGINSWITH %@", arg)).firstMatch
                if node.waitForExistence(timeout: 8) { node.tap() }
                else if loose.waitForExistence(timeout: 2) { loose.tap() }
                else if cmd == "tap" { dump(); XCTFail("missing: \(arg)"); return }
            case "tapxy":
                let xy = arg.split(separator: ",").compactMap { Double($0) }
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: xy[0], dy: xy[1])).tap()
            case "press":
                let xy = arg.split(separator: ",").compactMap { Double($0) }
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: xy[0], dy: xy[1])).press(forDuration: 1.2)
            case "keys":
                // Taps software-keyboard keys one by one, for inputs that
                // XCTest cannot focus (e.g. the Quill editor).
                for ch in arg {
                    let label = ch == "\n" ? "return" : String(ch).uppercased()
                    let match = NSPredicate(format: "label ==[c] %@", label)
                    let key = app.keys.matching(match).firstMatch.exists
                        ? app.keys.matching(match).firstMatch : app.buttons.matching(match).firstMatch
                    if key.waitForExistence(timeout: 3) { key.tap() } else { XCTFail("no key \(label)"); return }
                }
            case "type": app.typeText(arg)
            case "wait": RunLoop.current.run(until: Date().addingTimeInterval(Double(arg) ?? 1))
            case "dump": dump()
            default: XCTFail("unknown step \(step)"); return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        dump()
    }

    func testSeedVelockBusinessData() {
        ensureVelockInitializedAndPairingEnabled(enablePairing: false)
        seedVelockBusinessDataIfRequested()
    }

    func testSeedVelockNoteOnly() {
        velockApp.launch()
        if !velockApp.wait(for: .runningForeground, timeout: 20) {
            // The request is delivered through the scene URL and iOS may leave
            // the app backgrounded after the handoff. Bring it forward before
            // declaring the pairing request missing.
            velockApp.activate()
            XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 20))
        }
        unlockVelockIfNeeded()
        let credentials = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '凭证'" )
        ).firstMatch
        XCTAssertTrue(credentials.waitForExistence(timeout: 15))
        credentials.tap()
        let notesTab = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '备注'" )
        ).firstMatch
        XCTAssertTrue(notesTab.waitForExistence(timeout: 10))
        notesTab.tap()
        tapCreateCredential()
        XCTAssertTrue(velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '新建备注'" )
        ).firstMatch.waitForExistence(timeout: 10), "Note editor was not opened")
        let fixtureInput = velockApp.descendants(matching: .any)["e2e-fill-note-fixture"]
        XCTAssertTrue(fixtureInput.waitForExistence(timeout: 5),
                      "Build with --dart-define=VELOCK_E2E_FIXTURES=true; fixture entry is debug-only")
        fixtureInput.tap()
        velockApp.buttons["保存"].firstMatch.tap()
        XCTAssertTrue(fixtureInput.waitForNonExistence(timeout: 30),
                      "Note save did not finish; editor/error remains: \(velockApp.debugDescription)")
        XCTAssertTrue(velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS 'E2E note content'")
        ).firstMatch.waitForExistence(timeout: 10),
                      "Saved note missing from browser: \(velockApp.debugDescription)")
    }

    /// Cross-device step 3 (source device): approve the new device that joined
    /// the vault so its batches become downloadable here.
    func testApproveJoinRequestOnSource() {
        ensureVelockInitializedAndPairingEnabled(refreshRecoveryCard: false)
        returnToVelockDashboard()

        let settingsTab = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '设置'")
        ).firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 15))
        settingsTab.tap()
        let syncSettings = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '数据同步'")
        ).firstMatch
        XCTAssertTrue(syncSettings.waitForExistence(timeout: 10))
        syncSettings.tap()

        let section = velockApp.staticTexts["新设备请求加入"]
        XCTAssertTrue(
            section.waitForExistence(timeout: 20),
            "Pending join request was not surfaced in the sync settings"
        )
        attachScreenshot("source_join_request_pending")

        let approve = velockApp.buttons["批准"].firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "Approve action missing")
        approve.tap()
        // Confirmation dialog uses the same label.
        let confirm = velockApp.buttons.matching(
            NSPredicate(format: "label == '批准'")
        ).element(boundBy: 1)
        if confirm.exists {
            confirm.tap()
        } else {
            velockApp.buttons["批准"].firstMatch.tap()
        }
        XCTAssertTrue(
            section.waitForNonExistence(timeout: 20),
            "Join request section is still visible after approval"
        )
        attachScreenshot("source_join_request_approved")
    }

    /// Cross-device step 2 (replica device): download the tombstone, confirm
    /// the entry is attributed to another device and restore it.
    func testTrashRestoreOnReplica() {
        ensureVelockInitializedAndPairingEnabled(refreshRecoveryCard: false)
        returnToVelockDashboard()

        // Pull the delete tombstone from the remote.
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
        tapHomeTab("同步", normalizedX: 0.125, screenshotName: "replica-trash-sync-home")
        let syncNow = syncApp.buttons["立即同步"].firstMatch
        if !syncNow.waitForExistence(timeout: 5) {
            let profileRow = syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS 'Velock E2E'")
            ).firstMatch
            if profileRow.waitForExistence(timeout: 10) && profileRow.isHittable {
                profileRow.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1))
            }
        }
        XCTAssertTrue(syncNow.waitForExistence(timeout: 20), "Sync action was not exposed")
        syncNow.tap()
        let result = syncApp.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS '同步任务已完成' OR label CONTAINS '同步检查完成，没有待同步内容' OR label CONTAINS '同步失败' OR label CONTAINS '同步完成'"
            )
        ).firstMatch
        _ = result.waitForExistence(timeout: 150)
        let later = syncApp.buttons["稍后"].firstMatch
        if later.waitForExistence(timeout: 3) { later.tap() }
        attachScreenshot("replica_trash_sync_done")

        // Unlock Velock so it imports the downloaded tombstone.
        velockApp.activate()
        XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 20))
        unlockVelockIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(10))

        let settingsTab = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '设置'")
        ).firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 15), "Dashboard tabs were not reachable")
        settingsTab.tap()
        let recentlyDeleted = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '最近删除'")
        ).firstMatch
        XCTAssertTrue(recentlyDeleted.waitForExistence(timeout: 10))
        recentlyDeleted.tap()

        let remoteDeletedRow = velockApp.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS 'E2E Password' AND label CONTAINS '来自其他设备'"
            )
        ).firstMatch
        XCTAssertTrue(
            remoteDeletedRow.waitForExistence(timeout: 20),
            "Replica trash did not attribute the deletion to another device"
        )
        attachScreenshot("replica_trash_from_other_device")

        remoteDeletedRow.tap()
        let restore = velockApp.buttons["恢复"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 10), "Restore action was not offered")
        restore.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        attachScreenshot("replica_trash_restored")

        // The credential must be back on this device.
        returnToVelockDashboard()
        let credentialsTab = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '凭证'")
        ).firstMatch
        XCTAssertTrue(credentialsTab.waitForExistence(timeout: 10))
        credentialsTab.tap()
        XCTAssertTrue(
            velockApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS 'E2E Password'")
            ).firstMatch.waitForExistence(timeout: 15),
            "Restored credential is missing from the replica"
        )
        attachScreenshot("replica_trash_back_in_credentials")
    }

    /// Cross-device step 1 (source device): delete a credential, upload the
    /// tombstone and confirm the trash entry becomes “已同步”.
    func testTrashDeleteAndUploadOnSource() {
        ensureVelockInitializedAndPairingEnabled(refreshRecoveryCard: false)
        returnToVelockDashboard()

        let credentialsTab = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '凭证'")
        ).firstMatch
        XCTAssertTrue(credentialsTab.waitForExistence(timeout: 15))
        credentialsTab.tap()

        let passwordRow = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'E2E Password'")
        ).firstMatch
        XCTAssertTrue(passwordRow.waitForExistence(timeout: 10), "Seeded password was not listed")
        let start = passwordRow.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        let end = passwordRow.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let deleteAction = velockApp.buttons.matching(
            NSPredicate(format: "label == '删除'")
        ).firstMatch
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5), "Swipe did not reveal delete")
        deleteAction.tap()
        let confirm = velockApp.buttons["移到最近删除"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(passwordRow.waitForNonExistence(timeout: 10))

        // Velock stages pending revisions into the shared outbox when its sync
        // settings are visited; without that step the new tombstone would sit
        // in the local change log and the next Sync run would upload nothing.
        let settingsForExport = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '设置'")
        ).firstMatch
        XCTAssertTrue(settingsForExport.waitForExistence(timeout: 10))
        settingsForExport.tap()
        let syncSettings = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '数据同步'")
        ).firstMatch
        XCTAssertTrue(syncSettings.waitForExistence(timeout: 10))
        syncSettings.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(20))
        attachScreenshot("trash_after_velock_export")

        // Upload the tombstone from the Sync app.
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
        tapHomeTab("同步", normalizedX: 0.125, screenshotName: "trash-sync-home")
        let syncNow = syncApp.buttons["立即同步"].firstMatch
        if !syncNow.waitForExistence(timeout: 5) {
            let profileRow = syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS 'Velock E2E'")
            ).firstMatch
            if profileRow.waitForExistence(timeout: 10) && profileRow.isHittable {
                profileRow.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1))
            }
        }
        XCTAssertTrue(syncNow.waitForExistence(timeout: 20), "Sync action was not exposed")
        syncNow.tap()
        let result = syncApp.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS '同步任务已完成' OR label CONTAINS '同步检查完成，没有待同步内容' OR label CONTAINS '同步失败' OR label CONTAINS '同步完成'"
            )
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 150), "Upload sync did not finish")
        XCTAssertFalse(result.label.contains("同步失败"), result.label)
        attachScreenshot("trash_sync_after_upload")
        let later = syncApp.buttons["稍后"].firstMatch
        if later.waitForExistence(timeout: 3) { later.tap() }

        // The trash entry must now report a truthful “已同步”.
        velockApp.activate()
        XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 20))
        returnToVelockDashboard()
        let settingsTab = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '设置'")
        ).firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()
        let recentlyDeleted = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '最近删除'")
        ).firstMatch
        XCTAssertTrue(recentlyDeleted.waitForExistence(timeout: 10))
        recentlyDeleted.tap()
        let syncedRow = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'E2E Password' AND label CONTAINS '已同步'")
        ).firstMatch
        XCTAssertTrue(
            syncedRow.waitForExistence(timeout: 20),
            "Trash entry did not report 已同步 after the upload receipt"
        )
        attachScreenshot("trash_entry_synced")
    }

    /// Local acceptance for the recent-delete flow: delete a credential,
    /// confirm the new wording, find it in 最近删除 and restore it.
    func testLocalTrashFlow() {
        ensureVelockInitializedAndPairingEnabled(refreshRecoveryCard: false)
        // The pairing helper finishes on the sync settings page.
        returnToVelockDashboard()

        // Tab labels are exposed as "凭证\n凭证" on this runtime, so match by
        // containment rather than by an exact label.
        let credentialsTab = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '凭证'")
        ).firstMatch
        XCTAssertTrue(credentialsTab.waitForExistence(timeout: 15), "Dashboard tabs were not reachable")
        credentialsTab.tap()

        let passwordRow = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'E2E Password'")
        ).firstMatch
        XCTAssertTrue(passwordRow.waitForExistence(timeout: 10), "Seeded password was not listed")
        attachScreenshot("trash_01_before_delete")

        // Swipe the row to reveal the destructive action, then confirm.
        let start = passwordRow.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        let end = passwordRow.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let deleteAction = velockApp.buttons.matching(
            NSPredicate(format: "label == '删除'")
        ).firstMatch
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5), "Swipe did not reveal delete")
        deleteAction.tap()

        let confirmTitle = velockApp.staticTexts["移到最近删除？"]
        XCTAssertTrue(
            confirmTitle.waitForExistence(timeout: 5),
            "Delete confirmation did not use the recent-delete wording"
        )
        let confirm = velockApp.buttons["移到最近删除"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(
            passwordRow.waitForNonExistence(timeout: 10),
            "Deleted credential is still listed in 凭证"
        )
        attachScreenshot("trash_02_after_delete")

        // 设置 → 最近删除 must show the entry with a truthful sync state.
        let settingsTab = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '设置'")
        ).firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()
        let recentlyDeleted = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '最近删除'")
        ).firstMatch
        XCTAssertTrue(recentlyDeleted.waitForExistence(timeout: 10), "Missing 最近删除 entry")
        recentlyDeleted.tap()
        let trashedRow = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'E2E Password'")
        ).firstMatch
        XCTAssertTrue(trashedRow.waitForExistence(timeout: 10), "Entry missing from 最近删除")
        attachScreenshot("trash_03_in_trash")

        // Restore from 最近删除 and verify it returns to the credentials list.
        trashedRow.tap()
        let restore = velockApp.buttons["恢复"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 10), "Restore action was not offered")
        restore.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        // The page may still show the restore toast at this instant, so the
        // list refresh is best-effort here; the authoritative check is that
        // the credential is back in 凭证 below.
        let emptyTrash = velockApp.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '没有可恢复的项目'")
        ).firstMatch
        if !emptyTrash.waitForExistence(timeout: 20) {
            print("TRASH_LIST_STILL_VISIBLE_AFTER_RESTORE")
        }
        attachScreenshot("trash_04_restored")

        let back = velockApp.buttons.firstMatch
        if back.exists && back.isHittable {
            velockApp.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.09)).tap()
        }
        if credentialsTab.waitForExistence(timeout: 5) { credentialsTab.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(
            velockApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS 'E2E Password'")
            ).firstMatch.waitForExistence(timeout: 10),
            "Restored credential did not return to 凭证"
        )
        attachScreenshot("trash_05_back_in_credentials")
    }

    /// Diagnostic only: reports whether the profile's sync controls are
    /// actually enabled/hittable on this device.
    func testProbeSyncNowState() {
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
        tapHomeTab("同步", normalizedX: 0.125, screenshotName: "probe-sync-home")
        let row = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'Velock E2E'")
        ).firstMatch
        _ = row.waitForExistence(timeout: 10)
        if row.exists && row.isHittable { row.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let buttons = syncApp.buttons.matching(
            NSPredicate(format: "label == '立即同步'")
        )
        print("PROBE_SYNC_NOW count=\(buttons.count)")
        for index in 0..<buttons.count {
            let button = buttons.element(boundBy: index)
            print(
                "PROBE_SYNC_NOW[\(index)] enabled=\(button.isEnabled) "
                + "hittable=\(button.isHittable) frame=\(button.frame)"
            )
        }
        attachScreenshot("probe-sync-now")
        guard buttons.count > 0 else { return }
        buttons.element(boundBy: 0).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print("PROBE_AFTER_TAP_1S\n\(syncApp.debugDescription)")
        attachScreenshot("probe-after-tap-1s")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        print("PROBE_AFTER_TAP_3S\n\(syncApp.debugDescription)")
        attachScreenshot("probe-after-tap-3s")
        RunLoop.current.run(until: Date().addingTimeInterval(30))
        print("PROBE_AFTER_TAP_33S\n\(syncApp.debugDescription)")
        attachScreenshot("probe-after-tap-33s")
    }

    func testSyncExistingVelockProfile() {
        ensureVelockInitializedAndPairingEnabled(refreshRecoveryCard: false)
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
        tapHomeTab("同步", normalizedX: 0.125, screenshotName: "existing-sync-home")
        // The home page exposes the per-profile shortcut only as a tooltip on
        // an icon, so open the profile detail and use its explicit action.
        let syncNow = syncApp.buttons["立即同步"].firstMatch
        if !syncNow.waitForExistence(timeout: 5) {
            let profileRow = syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS 'Velock E2E'")
            ).firstMatch
            if profileRow.waitForExistence(timeout: 10) && profileRow.isHittable {
                profileRow.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1))
            }
        }
        XCTAssertTrue(syncNow.waitForExistence(timeout: 20),
                      "Existing profile cannot sync: \(syncApp.debugDescription)")
        syncNow.tap()
        let completed = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '同步任务已完成' OR label CONTAINS '同步检查完成，没有待同步内容' OR label CONTAINS '请打开格间并解锁以完成恢复' OR label CONTAINS '同步失败'")
        ).firstMatch
        if !completed.waitForExistence(timeout: 90) {
            // Toasts are transient: short runs can finish before the query
            // lands. When the caller validates the persisted sync run itself
            // (state.db freshness check in run_cross_app_ui_test.sh), treat a
            // missing toast as inconclusive instead of a failure.
            if ProcessInfo.processInfo.environment["E2E_SYNC_DB_VERIFIED"] == "1" {
                print("E2E_EXISTING_SYNC_RESULT=toast-missing (verified from state.db)")
            } else {
                XCTFail("Current sync did not complete: \(syncApp.debugDescription)")
            }
        } else {
            XCTAssertFalse(completed.label.contains("同步失败"), completed.label)
            print("E2E_EXISTING_SYNC_RESULT=\(completed.label)")
        }
        attachScreenshot("existing-profile-synchronized")
        // Sync delivers ciphertext to the shared inbox; Velock imports it
        // after unlocking. A Sync toast alone is not business-data recovery.
        velockApp.activate()
        if !velockApp.wait(for: .runningForeground, timeout: 20) {
            velockApp.activate()
            XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 20))
        }
        unlockVelockIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(8))
    }

    /// Fast configured-profile path. The host runner must require a fresh
    /// completed sync_runs row; an enabled button alone is not success evidence.
    func testTutorialRejectIncompleteRemoteHistory() throws {
        guard ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] != nil else {
            throw XCTSkip("Requires a dedicated source and disposable empty WebDAV")
        }
        syncApp.launch()
        tutorialTap(tutorialContains(syncApp, ["同步", "Sync"]), "history-sync-home")
        let profile = tutorialContains(syncApp, ["Velock E2E"])
        tutorialTap(profile, "history-profile")
        let syncNow = syncApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '立即同步' OR label CONTAINS 'Sync now' OR label CONTAINS 'Sync Now'")
        ).firstMatch
        for _ in 0..<5 {
            if syncNow.exists && syncNow.isHittable { break }
            syncApp.swipeUp()
        }
        tutorialTap(syncNow, "history-sync-now")
        let failure = tutorialContains(syncApp, ["远端缺少历史备份", "Remote backup history is incomplete"])
        tutorialReady(failure, "history-incomplete-rejected", timeout: 25)
        attachScreenshot("history-incomplete-rejected")
        if let root = ProcessInfo.processInfo.environment["E2E_TUTORIAL_DIR"] {
            try syncApp.screenshot().pngRepresentation.write(to:
                URL(fileURLWithPath: root).appendingPathComponent("history-incomplete-rejected.png"))
        }

    }

    func testSyncConfiguredVelockProfile() {
        XCTAssertEqual(ProcessInfo.processInfo.environment["E2E_SYNC_DB_VERIFIED"], "1")
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
        tapHomeTab("同步", normalizedX: 0.125, screenshotName: "configured-sync-home")
        let profile = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'Velock E2E'")
        ).firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 10) && profile.isHittable)
        profile.tap()
        let syncNow = syncApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '立即同步'")
        ).firstMatch
        // The detail page is scrollable and merged semantics include the subtitle.
        for _ in 0..<5 {
            if syncNow.waitForExistence(timeout: 1) && syncNow.isHittable { break }
            syncApp.swipeUp()
        }
        XCTAssertTrue(syncNow.waitForExistence(timeout: 5) && syncNow.isHittable,
                      "Configured sync action is not reachable: \(syncApp.debugDescription)")
        syncNow.tap()
        // A completed result dialog intentionally disables the underlying
        // button. Do not mistake that for a still-running transfer. The host
        // verifies the fresh persisted run, including real failures/timeouts.
        let openCompanion = syncApp.buttons["打开格间"].firstMatch
        if openCompanion.waitForExistence(timeout: 2) && openCompanion.isHittable {
            openCompanion.tap()
        }
        velockApp.launch()
        XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 20))
        unlockVelockIfNeeded()
        let dashboard = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '凭证'")
        ).firstMatch
        XCTAssertTrue(dashboard.waitForExistence(timeout: 20))
    }

    /// Verifies decrypted synthetic content after a real process restart.
    /// Unlike a screenshot-only tour, every selected fixture is asserted.
    func testRestoredCredentialAfterColdRestart() {
        velockApp.terminate()
        velockApp.launch()
        XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 20))
        unlockVelockIfNeeded()
        let credentials = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '凭证'")
        ).firstMatch
        XCTAssertTrue(credentials.waitForExistence(timeout: 20) && credentials.isHittable)
        credentials.tap()
        let password = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS 'E2E Password'")
        ).firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 15) && password.isHittable)
        password.tap()
        let account = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'e2e-user' OR value CONTAINS 'e2e-user'")
        ).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 20) && account.isHittable,
                      "Restored encrypted credential could not be read after restart")
        attachScreenshot("verified-restored-credential-after-cold-restart")
    }

    /// Focused checkpoint/GC acceptance probe for an already configured
    /// simulator. Unlike the generic sync test it never tries to initialize or
    /// repair pairing state; it only unlocks the existing vault, runs one sync,
    /// and unlocks Velock again so the checkpoint write is exercised.
    func testSyncAndPublishCheckpointOnConfiguredDevice() {
        velockApp.launch()
        XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 20))
        unlockVelockIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(5))

        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
        tapHomeTab("同步", normalizedX: 0.125, screenshotName: "checkpoint-sync-home")
        let syncNow = syncApp.buttons["立即同步"].firstMatch
        if !syncNow.waitForExistence(timeout: 5) {
            let profileRow = syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS 'Velock E2E'")
            ).firstMatch
            if profileRow.waitForExistence(timeout: 10) && profileRow.isHittable {
                profileRow.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1))
            }
        }
        XCTAssertTrue(syncNow.waitForExistence(timeout: 20), "Sync action is unavailable")
        syncNow.tap()
        let result = syncApp.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS '同步任务已完成' OR label CONTAINS '同步检查完成，没有待同步内容' OR label CONTAINS '同步失败' OR label CONTAINS '同步完成'"
            )
        ).firstMatch
        if ProcessInfo.processInfo.environment["E2E_SYNC_DB_ONLY"] == "1" {
            RunLoop.current.run(until: Date().addingTimeInterval(15))
        } else {
            _ = result.waitForExistence(timeout: 150)
        }
        let later = syncApp.buttons["稍后"].firstMatch
        if later.waitForExistence(timeout: 3) { later.tap() }

        velockApp.activate()
        XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 20))
        unlockVelockIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        attachScreenshot("checkpoint-published")
    }

    func testSeedVelockDocumentOnly() {
        ensureVelockInitializedAndPairingEnabled(refreshRecoveryCard: false)
        let fixture = velockApp.descendants(matching: .any)["e2e-create-document-fixture"]
        for _ in 0..<5 {
            if fixture.waitForExistence(timeout: 1) && fixture.isHittable { break }
            velockApp.swipeUp()
        }
        XCTAssertTrue(fixture.waitForExistence(timeout: 5),
                      "Debug document fixture entry missing: \(velockApp.debugDescription)")
        fixture.tap()
        let persisted = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label == 'E2E document persisted'")
        ).firstMatch
        XCTAssertTrue(persisted.waitForExistence(timeout: 45),
                      "Document encryption/persistence failed: \(velockApp.debugDescription)")
        attachScreenshot("document-encrypted-persistence")
    }

    func testExportSyncRecoveryCard() {
        ensureVelockInitializedAndPairingEnabled(forceRecoveryCard: true)
    }

    /// Read-only recovery inspection. Never creates a space or seeds records.
    func testInspectRestoredContentAfterRestart() {
        velockApp.terminate()
        velockApp.launch()
        XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 20))
        unlockVelockIfNeeded()
        let credentials = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '凭证'")
        ).firstMatch
        XCTAssertTrue(credentials.waitForExistence(timeout: 30) && credentials.isHittable)
        credentials.tap()
        print("RESTORED_CREDENTIALS_BEGIN\n\(velockApp.debugDescription)\nRESTORED_CREDENTIALS_END")
        attachScreenshot("restored-credentials-after-restart")
        let password = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS 'E2E Password'")
        ).firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 15), "Restored password fixture is absent")
        password.tap()
        let restoredAccount = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'e2e-user' OR value CONTAINS 'e2e-user'")
        ).firstMatch
        XCTAssertTrue(restoredAccount.waitForExistence(timeout: 30) && restoredAccount.isHittable,
                      "Restored account detail could not be read on the foreground route")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        persistRestoredEvidence("password-detail")
        attachScreenshot("restored-password-detail-after-restart")
        velockApp.buttons["返回"].firstMatch.tap()
        for (label, evidence) in [("备注", "notes"), ("文件", "files"), ("相册", "media")] {
            let tab = velockApp.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 10) && tab.isHittable, "Missing recovered category: \(label)")
            tab.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            persistRestoredEvidence(evidence)
        }

    }

    func testInspectRestoredRemainingDetails() {
        for kind in ["card", "note", "file", "media", "document"] {
            velockApp.terminate()
            velockApp.launch()
            XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 20))
            unlockVelockIfNeeded()
            let rootLabel = (kind == "card" || kind == "note") ? "凭证" :
                (kind == "file" ? "文件" : (kind == "media" ? "相册" : "首页"))
            let root = velockApp.buttons.matching(NSPredicate(format: "label CONTAINS %@", rootLabel)).firstMatch
            XCTAssertTrue(root.waitForExistence(timeout: 20) && root.isHittable)
            root.tap()
            if kind == "note" { velockApp.buttons["备注"].firstMatch.tap() }
            if kind == "card" || kind == "note" {
                let fixture = kind == "card" ? "E2E Card" : "E2E note content"
                let row = velockApp.buttons.matching(NSPredicate(format: "label CONTAINS %@", fixture)).firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 15) && row.isHittable)
                row.tap()
            } else if kind == "file" {
                // iOS 26 exposes the imported filename with a zero-width
                // character between every glyph, so AX substring matching is
                // not reliable. The production file grid is visible at this
                // stable tile position; tap the recovered tile itself.
                XCTAssertTrue(velockApp.buttons.count > 5, "Recovered file grid did not load")
                velockApp.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.25)).tap()
            } else if kind == "media" {
                XCTAssertTrue(velockApp.staticTexts["共2个项目"].waitForExistence(timeout: 15))
                // The photo grid currently has no per-item AX node. This is the
                // first existing tile, observed in the recovered gallery capture.
                velockApp.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.16)).tap()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(5))
            persistRestoredEvidence(kind + "-detail")
        }
    }

    private func persistRestoredEvidence(_ name: String) {
        let root = ProcessInfo.processInfo.environment["E2E_CONTENT_EVIDENCE_DIR"] ?? "/tmp/velock-restored-content"
        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            try velockApp.debugDescription.write(toFile: root + "/" + name + ".txt", atomically: true, encoding: .utf8)
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: root + "/" + name + ".png"))
        } catch { XCTFail("Could not persist recovery evidence: \(error)") }
    }

    func testOpenVelockForInboundImport() {
        velockApp.launch()
        XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 20))
        unlockVelockIfNeeded()
        XCTAssertTrue(
            velockApp.buttons.matching(NSPredicate(format: "label CONTAINS '设置'"))
                .firstMatch.waitForExistence(timeout: 30)
        )
        RunLoop.current.run(until: Date().addingTimeInterval(8))
    }

    /// Imports source file/photo fixtures through production UI. Existing
    /// spaces and their data are preserved; this test adds fixture records.
    func testProbeVelockFileAndImageImport() {
        // Reset only this app's photo authorization, never simulator/app data.
        // Exercise the actual first-use system permission prompt.
        velockApp.resetAuthorizationStatus(for: .photos)

        prepareFixtureHost()
        velockApp.launch()
        XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 20))
        unlockVelockIfNeeded()
        XCTAssertTrue(
            velockApp.buttons.matching(NSPredicate(format: "label CONTAINS '设置' OR label CONTAINS '首页'"))
                .firstMatch.waitForExistence(timeout: 15),
            "Velock was not unlocked; import actions must not run on the password gate"
        )
        print("E2E_IMPORT_AFTER_UNLOCK_BEGIN\n\(velockApp.debugDescription)\nE2E_IMPORT_AFTER_UNLOCK_END")

        let filesTab = firstExisting(
            velockApp.descendants(matching: .any)["tkNav_files"],
            velockApp.buttons.matching(NSPredicate(format: "label CONTAINS '文件'" )).firstMatch
        )
        let imagesTab = firstExisting(
            velockApp.descendants(matching: .any)["tkNav_images"],
            velockApp.buttons.matching(NSPredicate(format: "label CONTAINS '相册'" )).firstMatch
        )
        XCTAssertTrue(filesTab.waitForExistence(timeout: 15), "Files tab is unavailable")
        XCTAssertTrue(imagesTab.waitForExistence(timeout: 15), "Images tab is unavailable")

        filesTab.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let fileAdd = firstExisting(
            velockApp.descendants(matching: .any)["tkBtn_files_add"],
            velockApp.buttons.matching(NSPredicate(format: "label CONTAINS '添加' OR label CONTAINS '导入'" )).firstMatch
        )
        if fileAdd.waitForExistence(timeout: 10) && fileAdd.isHittable {
            fileAdd.tap()
        } else {
            // The current iOS build merges the app-bar action into a generic
            // Flutter semantics node; its production position is stable.
            velockApp.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.07)).tap()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let chooseFile = velockApp.buttons.matching(NSPredicate(format: "label CONTAINS '从文件' OR label CONTAINS '文件'" )).firstMatch
        if chooseFile.waitForExistence(timeout: 5) && chooseFile.isHittable { chooseFile.tap() }
        let documents = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        let pickerInSync = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["浏览", "Browse", "最近项目", "Recents"])
        ).firstMatch
        XCTAssertTrue(
            documents.wait(for: .runningForeground, timeout: 8) || pickerInSync.waitForExistence(timeout: 8),
            "File import did not open the iOS document picker"
        )
        if documents.state == .runningForeground || pickerInSync.exists {
            let pickerApp: XCUIApplication = documents.state == .runningForeground ? documents : velockApp
            let browse = pickerApp.tabBars["DOC.browsingModeTabBar"].buttons["浏览"]
            if browse.exists && browse.isHittable {
                browse.tap()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let host = pickerApp.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'CrossAppUITestHost'" )).firstMatch
            let directFile = pickerApp.descendants(matching: .any).matching(NSPredicate(format: "(label CONTAINS 'velock-sync-e2e-proof' OR identifier CONTAINS 'velock-sync-e2e-proof') AND (label CONTAINS[c] 'txt' OR identifier CONTAINS[c] 'txt')" )).firstMatch
            let file: XCUIElement
            var selectedByCoordinate = false
            if directFile.waitForExistence(timeout: 3) {
                file = directFile
            } else {
                if host.waitForExistence(timeout: 2) {
                    host.tap()
                    let source = pickerApp.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'VelockSync-E2E-Source'" )).firstMatch
                    XCTAssertTrue(source.waitForExistence(timeout: 8), "Fixture source folder is unavailable")
                    source.tap()
                    file = pickerApp.descendants(matching: .any).matching(NSPredicate(format: "(label CONTAINS 'velock-sync-e2e-proof' OR identifier CONTAINS 'velock-sync-e2e-proof') AND (label CONTAINS[c] 'txt' OR identifier CONTAINS[c] 'txt')" )).firstMatch
                } else {
                    // iOS 26 presents the fixture directly in “所有文件”; its
                    // AX label is line-wrapped/truncated, so use the stable
                    // cell position as a final fallback.
                    let fixtureCoordinate = pickerApp.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.18))
                    fixtureCoordinate.tap()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                    fixtureCoordinate.tap()
                    selectedByCoordinate = true
                    file = pickerApp.descendants(matching: .any).matching(NSPredicate(format: "(label CONTAINS 'velock-sync-e2e-proof' OR identifier CONTAINS 'velock-sync-e2e-proof') AND (label CONTAINS[c] 'txt' OR identifier CONTAINS[c] 'txt')" )).firstMatch
                }
            }
            if !selectedByCoordinate {
                XCTAssertTrue(file.waitForExistence(timeout: 8), "Fixture proof file is unavailable")
                file.tap()
            }
            let open = pickerApp.buttons.matching(NSPredicate(format: "label == '打开' OR label == 'Open' OR label == '完成' OR label == 'Done'" )).firstMatch
            if open.waitForExistence(timeout: 3) && open.isHittable {
                open.tap()
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        velockApp.activate()
        XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 10), "Velock did not return from file import")
        // Importing a file can leave the mobile shell on a transient route;
        // relaunch the same app process before starting the independent photo
        // import. This preserves the account and the newly imported file.
        velockApp.terminate()
        velockApp.launch()
        XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 15))
        unlockVelockIfNeeded()
        print("E2E_FILE_IMPORT_BEGIN\n\(velockApp.debugDescription)\nE2E_FILE_IMPORT_END")
        attachScreenshot("probe-file-import")

        if !tutorialTextOnly { importPhotoFixture() }
    }

    func testProbeVelockMediaImport() {
        // iOS 27 hosts the Photos permission prompt outside both SpringBoard
        // and the app's AX tree; callers can pre-grant with `simctl privacy`.
        if ProcessInfo.processInfo.environment["E2E_PHOTOS_PREGRANTED"] != "1" {
            velockApp.resetAuthorizationStatus(for: .photos)
        }
        velockApp.launch()
        XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 20))
        unlockVelockIfNeeded()
        importPhotoFixture()
    }

    private func importPhotoFixture() {
        let currentImagesTab = firstExisting(
            velockApp.descendants(matching: .any)["tkNav_images"],
            velockApp.buttons.matching(NSPredicate(format: "label CONTAINS '相册'" )).firstMatch
        )
        XCTAssertTrue(currentImagesTab.waitForExistence(timeout: 10), "Images tab disappeared after file import")
        currentImagesTab.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let imageAdd = firstExisting(
            velockApp.descendants(matching: .any)["tkBtn_images_add"],
            velockApp.buttons.matching(NSPredicate(format: "label CONTAINS '添加' OR label CONTAINS '导入'" )).firstMatch
        )
        if imageAdd.waitForExistence(timeout: 10) && imageAdd.isHittable {
            imageAdd.tap()
        } else {
            velockApp.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.07)).tap()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        // The image add button is a pull-down menu: explicitly choose the
        // Files route instead of accidentally tapping the bottom navigation
        // item whose label also contains “文件”.
        // `simctl addmedia` puts the fixture in Photos, so exercise the
        // production gallery path (the Files path is a separate feature).
        let fromPhotos = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '从相册' OR label CONTAINS 'From Photos' OR identifier CONTAINS 'fromPhotos'")
        ).firstMatch
        XCTAssertTrue(fromPhotos.waitForExistence(timeout: 8),
                      "Image import menu did not expose the Photos route\n\(velockApp.debugDescription)")
        XCTAssertTrue(fromPhotos.isHittable, "Photos route exists but is not hittable\n\(velockApp.debugDescription)")
        let permissionMonitor = addUIInterruptionMonitor(withDescription: "Photos access") { alert in
            let allow = alert.buttons.matching(NSPredicate(
                format: "label CONTAINS '完全访问' OR label CONTAINS '所有照片' OR label CONTAINS 'Full Access' OR label CONTAINS 'Allow Access to All Photos'"
            )).firstMatch
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        defer { removeUIInterruptionMonitor(permissionMonitor) }
        fromPhotos.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permissionPredicate = NSPredicate(
            format: "label CONTAINS '完全访问' OR label CONTAINS '所有照片' OR label CONTAINS 'Full Access' OR label CONTAINS 'Allow Access to All Photos'"
        )
        // Newer iOS versions can expose this system alert under the target
        // app rather than SpringBoard. Handle either accessibility owner.
        for _ in 0..<20 {
            let inApp = velockApp.buttons.matching(permissionPredicate).firstMatch
            let inSystem = springboard.buttons.matching(permissionPredicate).firstMatch
            if inApp.exists && inApp.isHittable { inApp.tap(); break }
            if inSystem.exists && inSystem.isHittable { inSystem.tap(); break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        print("E2E_IMAGE_IMPORT_BEGIN\n\(velockApp.debugDescription)\nE2E_IMAGE_IMPORT_END")
        attachScreenshot("probe-image-import")
        // PhotoManager omits filenames from the iOS AX tree. The newest
        // seeded asset has semantic index 1 even when the grid is reversed.
        let image = velockApp.images.matching(NSPredicate(
            format: "label BEGINSWITH '图片1,' OR label BEGINSWITH 'Image1,'"
        )).firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 15),
                      "Fixture image is not exposed in the gallery: \(velockApp.debugDescription)")
        image.tap()
        let confirm = velockApp.buttons.matching(NSPredicate(
            format: "label IN %@", ["确定", "确认", "完成", "Confirm", "Done"]
        )).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5) && confirm.isEnabled,
                      "Gallery confirmation is not enabled after selection: \(velockApp.debugDescription)")
        confirm.tap()
        let keepOriginal = velockApp.buttons.matching(NSPredicate(
            format: "label == '仅导入' OR label == 'Just import'"
        )).firstMatch
        // The confirmation is conditional on the import/delete preference.
        // Persistence is independently verified by the shell harness.
        if keepOriginal.waitForExistence(timeout: 3) && keepOriginal.isHittable {
            keepOriginal.tap()
        }
        let mediaAdd = velockApp.descendants(matching: .any)["tkBtn_images_add"]
        XCTAssertTrue(mediaAdd.waitForExistence(timeout: 30),
                      "Media import did not return to the gallery")
        let emptyGallery = velockApp.staticTexts["暂无图片或视频"]
        for _ in 0..<30 {
            if !emptyGallery.exists { break }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertFalse(emptyGallery.exists, "Gallery is still empty after import")
        attachScreenshot("media-import-completed")
    }

    private func typeVisibleKeyboardText(_ text: String) {
        for character in text {
            if character == " " {
                velockApp.keys["space"].tap()
            } else if character.isNumber {
                let key = velockApp.keys[String(character)].firstMatch
                if key.exists { key.tap() } else { velockApp.typeText(String(character)) }
            } else {
                let lower = velockApp.keys[String(character).lowercased()].firstMatch
                if lower.exists {
                    lower.tap()
                } else {
                    // iOS 26 exposes alphabetic keyboard keys with uppercase
                    // identifiers when shift is selected.
                    velockApp.keys[String(character).uppercased()].tap()
                }
            }
        }
    }

    /// End-to-end flow: initialize Velock → publish pairing identity →
    /// Sync creates a real one-time request → Velock approves it → Sync
    /// verifies, persists and consumes the signed response.
    ///
    /// The password is supplied at runtime with VELOCK_RUNTIME_PASSWORD and
    /// is never written to source, fixtures, attachments, or test output.
    func testCrossAppPairingFlow() {
        ensureVelockInitializedAndPairingEnabled(refreshRecoveryCard: false)
        let cardPageEnter = velockApp.buttons["进入沙盒空间"].firstMatch
        if cardPageEnter.waitForExistence(timeout: 5) {
            cardPageEnter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            unlockVelockIfNeeded()
        }
        seedVelockBusinessDataIfRequested()

        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
        createLocalWebDAVConnectionIfNeeded()

        tapHomeTab("同步", normalizedX: 0.125, screenshotName: "velock-sync-home")
        attachScreenshot("01_sync_home")

        // Re-pairing is explicit and limited to this harness's retained test
        // profile. Remove only the local configuration using production UI;
        // never erase the simulator, account, business files, or remote vault.
        // The row action menu exposes its tooltip as the button label.
        let retainedProfileActions = syncApp.buttons.matching(
            NSPredicate(format: "label == '同步配置操作'")
        )
        if retainedProfileActions.count == 1 && retainedProfileActions.firstMatch.exists {
            XCTAssertTrue(syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS 'Velock E2E'")
            ).firstMatch.exists, "Refusing to remove a non-E2E profile")
            retainedProfileActions.firstMatch.tap()
            let remove = syncApp.buttons["删除同步配置"].firstMatch
            XCTAssertTrue(remove.waitForExistence(timeout: 5))
            remove.tap()
            let confirm = syncApp.buttons["删除"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()
            XCTAssertTrue(retainedProfileActions.firstMatch.waitForNonExistence(timeout: 10))
        }

        // The redesigned sync home exposes the 格间 entry in the 格间 section:
        // the “开启格间备份” CTA, or a locked “已连接” tile when a profile is
        // already retained.
        let create = waitForAny(
            syncApp.buttons["velock-backup-enable"].firstMatch,
            syncApp.buttons.matching(
                NSPredicate(format: "label CONTAINS '开启格间备份'")
            ).firstMatch,
            syncApp.buttons["velock-already-paired"].firstMatch,
            timeout: 15
        )
        XCTAssertTrue(
            create.exists,
            "Sync home did not expose 格间 sync setup\n\(syncApp.debugDescription)"
        )
        create.tap()

        let dedicatedFlowMarker = syncApp.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS '开始连接格间' OR label CONTAINS '只需配对一次' OR label CONTAINS '已连接的格间备份'"
            )
        ).firstMatch
        var enteredDedicatedFlow = dedicatedFlowMarker.waitForExistence(timeout: 10)
        if !enteredDedicatedFlow {
            // The first Flutter semantics snapshot can still belong to the
            // retained home shell after an app install. Retry the same
            // production CTA once; never reset application data.
            create.tap()
            enteredDedicatedFlow = dedicatedFlowMarker.waitForExistence(timeout: 10)
        }
        if !enteredDedicatedFlow {
            print("SYNC_WIZARD_ENTRY_MISSING_BEGIN\n\(syncApp.debugDescription)\nSYNC_WIZARD_ENTRY_MISSING_END")
            attachScreenshot("sync-wizard-entry-missing")
            XCTFail("Sync did not enter the dedicated 格间 flow")
        }
        XCTAssertFalse(
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '选择数据集' OR label CONTAINS '同步文件夹'")
            ).firstMatch.exists,
            "The obsolete generic dataset flow is still visible"
        )
        attachScreenshot("02_sync_velock_entry")

        let inspect = waitForAny(
            syncApp.buttons["inspect-velock-readiness"].firstMatch,
            syncApp.buttons["开始连接格间"].firstMatch,
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '开始连接格间'")
            ).firstMatch
        )
        XCTAssertTrue(inspect.waitForExistence(timeout: 10), "Dedicated flow did not expose 开始连接格间")
        inspect.tap()

        let beginPairing = waitForAny(
            syncApp.buttons["begin-velock-pairing"].firstMatch,
            syncApp.buttons["开始配对"].firstMatch,
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '开始配对'")
            ).firstMatch
        )
        if !beginPairing.waitForExistence(timeout: 15) {
            print("PAIRING_READINESS_NOT_READY\n\(syncApp.debugDescription)\nPAIRING_READINESS_NOT_READY_END")
            attachScreenshot("pairing-readiness-not-ready")
            XCTFail("格间 did not expose a ready pairing descriptor")
            return
        }
        tutorialStage("begin-pairing")
        beginPairing.tap()

        // Sync writes a real one-time request and launches 格间 with the exact
        // request id. No test-only deep link or controller shortcut is used.
        // First-time URL launches require iOS's “Open in 格间?” consent.
        // Activating Velock directly dismisses that prompt without delivering
        // its URL, so it must never stand in for a successful deep-link launch.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<30 {
            if velockApp.state == .runningForeground { break }
            for owner in [syncApp!, springboard] {
                let open = owner.alerts.buttons.matching(
                    NSPredicate(format: "label IN %@", ["打开", "Open"])
                ).firstMatch
                if open.exists && open.isHittable { open.tap(); break }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        guard velockApp.wait(for: .runningForeground, timeout: 10) else {
            print("PAIRING_LAUNCH_FAILED\n\(syncApp.debugDescription)\n\(springboard.debugDescription)")
            attachScreenshot("pairing-launch-failed")
            XCTFail("iOS did not deliver the pairing deep link to 格间")
            return
        }
        tutorialStage("unlock-before-approval")
        if tutorialCaptureName != nil {
            // A resumed settings route can outlive its unlocked key session.
            // Follow the real user recovery: reopen, unlock, and revisit the
            // pending request instead of trying to approve on a stale route.
            ensureVelockInitializedAndPairingEnabled(refreshRecoveryCard: false)
        }
        unlockVelockIfNeeded()
        let approveRequest = velockApp.buttons["批准"].firstMatch
        guard approveRequest.waitForExistence(timeout: 15) else {
            print("PAIRING_APPROVAL_MISSING_BEGIN\n\(velockApp.debugDescription)\nPAIRING_APPROVAL_MISSING_END")
            attachScreenshot("pairing-approval-missing")
            syncApp.activate()
            print("PAIRING_SYNC_STATE_BEGIN\n\(syncApp.debugDescription)\nPAIRING_SYNC_STATE_END")
            attachScreenshot("pairing-sync-state")
            XCTFail("格间 did not expose the one-time request created by Sync")
            return
        }
        approveRequest.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
        XCTAssertTrue(
            velockApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '批准' AND label CONTAINS 'Velock Sync'")
            ).firstMatch.waitForExistence(timeout: 5)
        )
        let approvalButtons = velockApp.buttons.matching(
            NSPredicate(format: "label == '批准'")
        )
        XCTAssertEqual(approvalButtons.count, 1)
        tutorialStage("confirm-approval")
        approvalButtons.firstMatch.tap()
        // The settings page intentionally renders no empty-state row when
        // there are no pending requests. Confirm the approval dialog is gone
        // and the protected pairing control remains enabled instead of
        // waiting for a label that is never rendered.
        // The approval dialog closing is the only reliable UI transition here:
        // recovered accounts can return either to the pairing page or one
        // level back. The signed response itself is verified below by Sync;
        // do not mistake a route/semantics difference for persistence failure.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attachScreenshot("03_velock_pairing_approved")

        syncApp.activate()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 15))

        // With exactly one active WebDAV connection the new flow skips the old
        // seven-step wizard and opens the final review directly. The Sync app
        // discovers the signed approval on its own polling cycle, so give it a
        // generous window and walk any intermediate wizard step instead of
        // treating a slow poll as a failure.
        let finalize = syncApp.buttons["确认并创建"].firstMatch
        // A verified pairing still needs a remote target: the wizard asks for
        // one explicitly when this simulator has no connection yet.
        let createConnection = syncApp.buttons["去创建连接"].firstMatch
        if createConnection.waitForExistence(timeout: 10) && createConnection.isHittable {
            createConnection.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let protocolChoice = syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '选择协议' OR label CONTAINS '选择远端协议'")
            ).firstMatch
            if protocolChoice.waitForExistence(timeout: 10) { protocolChoice.tap() }
            let webDAV = syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS 'WebDAV'")
            ).firstMatch
            XCTAssertTrue(
                webDAV.waitForExistence(timeout: 10),
                "Wizard connection flow did not offer WebDAV\n\(syncApp.debugDescription)"
            )
            webDAV.tap()
            fillWebDAVConnectionForm()
            // The wizard keeps the verified pairing and asks to continue.
            let resume = syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '已验证'")
            ).firstMatch
            if resume.waitForExistence(timeout: 15) { resume.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        var reachedReview = finalize.waitForExistence(timeout: 45)
        if !reachedReview {
            for _ in 0..<3 {
                let advance = syncApp.buttons.matching(
                    NSPredicate(format: "label == '继续' OR label == '下一步'")
                ).firstMatch
                if advance.waitForExistence(timeout: 10) && advance.isHittable {
                    advance.tap()
                    RunLoop.current.run(until: Date().addingTimeInterval(2))
                }
                if finalize.waitForExistence(timeout: 20) {
                    reachedReview = true
                    break
                }
            }
        }
        if !reachedReview {
            print("SYNC_REVIEW_MISSING_BEGIN\n\(syncApp.debugDescription)\nSYNC_REVIEW_MISSING_END")
            attachScreenshot("sync-review-missing")
        }
        XCTAssertTrue(
            reachedReview,
            "Sync did not continue from approval to the final profile review"
        )
        tutorialStage("create-sync-profile")
        finalize.tap()

        let firstRunCompleted = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '首次同步完成' OR label == '同步完成' OR label CONTAINS '没有需要同步的新数据' OR label CONTAINS '首次同步失败'")
        ).firstMatch
        let durableProfile = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '格间数据' OR label CONTAINS 'Velock E2E'")
        ).firstMatch
        if tutorialCaptureName == "02-new-device-recovery" {
            // A profile row exists before its first download finishes. Wait for
            // the real result before foregrounding Velock for import.
            let downloadResult = syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '已下载' OR label CONTAINS '格间同步完成' OR label CONTAINS '当前没有新的数据需要同步' OR label CONTAINS '首次同步失败'")
            ).firstMatch
            XCTAssertTrue(downloadResult.waitForExistence(timeout: 60),
                          "Recovery did not finish its first download")
            attachScreenshot("tutorial-recovery-download-result")
        } else if tutorialCaptureName != nil {
            // Observe either UI result concurrently; do not leave a finished
            // screen idle for the fallback timeout in an instructional take.
            let result = waitForAny(firstRunCompleted, durableProfile, timeout: 30)
            XCTAssertTrue(result.exists, "Tutorial profile creation did not finish")
        } else {
            XCTAssertTrue(
                firstRunCompleted.waitForExistence(timeout: 60) || durableProfile.waitForExistence(timeout: 10),
                "Profile creation returned without a visible first-sync result or durable profile"
            )
        }
        XCTAssertFalse(
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '首次同步失败'")
            ).firstMatch.exists,
            "First sync reported failure"
        )
        if tutorialCaptureName == "01-first-setup" {
            // First-time setup ends on the actual sync result, not a second
            // app launch made only for automated recovery verification.
            attachScreenshot("tutorial-first-sync-result")
            return
        }
        // The inbound writer is registered by the real Velock dashboard. Bring
        // the companion app foreground after Sync delivers a batch so the
        // encrypted operations are actually imported into the recovered
        // account before the test declares success.
        let openCompanion = syncApp.buttons["打开格间"].firstMatch
        if openCompanion.waitForExistence(timeout: 2) && openCompanion.isHittable {
            openCompanion.tap()
        }
        if tutorialCaptureName == "02-new-device-recovery" { return }
        velockApp.activate()
        XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 15))
        unlockVelockIfNeeded()
        let restoredDashboard = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '凭证'")
        ).firstMatch
        XCTAssertTrue(restoredDashboard.waitForExistence(timeout: 20))
        attachScreenshot("04_sync_pairing_and_first_run_completed")
    }

    /// Uses the recovery-card QR saved by the source invocation to create the
    /// account on a clean simulator. This is deliberately a real Photos QR
    /// scan path so syncRecovery is carried through the same user flow.
    func testRecoverVelockAccountFromCardPhoto() {
        // Clear the iOS 26 Photos first-run tour before opening 格间's
        // scanner. Doing this after the scanner is presented backgrounds the
        // test app and destroys that route.
        if cleanTutorial && englishTutorial { tutorialPrepareEnglishSync() }
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        if englishTutorial { photos.launchArguments = ["-AppleLanguages", "(en)"] }
        photos.launch()
        XCTAssertTrue(photos.wait(for: .runningForeground, timeout: 10))
        for _ in 0..<3 {
            let photosContinue = photos.buttons.matching(NSPredicate(format: "label IN %@", ["继续", "Continue"])).firstMatch
            if !photosContinue.waitForExistence(timeout: 2) { break }
            photosContinue.tap()
        }
        photos.terminate()

        velockApp.terminate()
        if englishTutorial { velockApp.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"] }
        velockApp.launch()
        XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 20))
        let existingRecoveredSandbox = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'Velock E2E Replica' OR label CONTAINS '当前空间'")
        ).firstMatch
        if existingRecoveredSandbox.waitForExistence(timeout: 3) &&
            ProcessInfo.processInfo.environment["E2E_RECOVER_ADDITIONAL_ACCOUNT"] != "1" {
            XCTAssertEqual(ProcessInfo.processInfo.environment["E2E_ALLOW_EXISTING_RECOVERY"], "1",
                           "Fresh recovery requires an account-free target; existing account must not masquerade as recovery")
            print("E2E_RECOVERY_REUSED_EXISTING_ACCOUNT")
            unlockVelockIfNeeded()
            XCTAssertTrue(
                velockApp.buttons.matching(NSPredicate(format: "label CONTAINS '设置'")).firstMatch
                    .waitForExistence(timeout: 30),
                "Existing recovered account could not be unlocked"
            )
            attachScreenshot("replica_velock_recovered_from_qr")
            return
        }
        let recover = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '恢复一个账号' OR label CONTAINS 'Recover an Account'")
        ).firstMatch
        XCTAssertTrue(recover.waitForExistence(timeout: 15), "Recovery entry was not exposed")
        if tutorialReplicaCapture {
            do { try beginTutorialCapture("02-new-device-recovery") }
            catch { XCTFail("Could not start tutorial recording"); return }
        }
        tutorialHold(0.8, reason: "recovery-entry")
        recover.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let scan = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '从二维码恢复' OR label CONTAINS 'Recover from QR Code'")
        ).firstMatch
        XCTAssertTrue(scan.waitForExistence(timeout: 15), "Recovery page did not expose QR import")
        scan.tap()
        let fromPhotos = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '从相册' OR label CONTAINS 'From Photos'")
        ).firstMatch
        XCTAssertTrue(fromPhotos.waitForExistence(timeout: 15), "QR scanner did not expose Photos import")
        fromPhotos.tap()

        // The runner imports a fresh-dated, byte-identical source card.
        // Do not assume an old image imported without refreshing its date is first.
        // PHPicker is a remote UIKit surface. On iOS 26 it is drawn inside
        // the 格间 accessibility root and is not exposed as
        // com.apple.mobileslideshow.images. The first tile is the image just
        // imported by simctl; select it by the stable picker geometry.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        velockApp.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.32)).tap()
        // Selecting an image can leave Photos frontmost while the QR decoder
        // finishes asynchronously. Explicitly reactivate 格间 before querying
        // its Flutter semantics tree.
        velockApp.activate()
        XCTAssertTrue(
            velockApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '恢复账号' OR label == 'Recover Account'")
            ).firstMatch.waitForExistence(timeout: 15),
            "QR import did not return to the recovery form"
        )
        // Keep any existing space intact. A display-name collision must not
        // turn a failed recovery into a successful existing-account login.
        if ProcessInfo.processInfo.environment["E2E_RECOVER_ADDITIONAL_ACCOUNT"] == "1" {
            let nameField = velockApp.textFields.firstMatch
            XCTAssertTrue(nameField.exists)
            nameField.tap()
            nameField.typeText(" Restored")
        }
        // A simulator without enrolled Face ID refuses to recover while the
        // biometric shortcut is on, so the switch must be turned off before
        // submitting. Query the switch itself; the surrounding row is a label.
        let biometricSwitch = velockApp.switches.firstMatch
        // The decoded recovery form is already present. Presentation captures
        // must not pause three seconds probing an optional absent control.
        if cleanTutorial ? biometricSwitch.exists : biometricSwitch.waitForExistence(timeout: 3) {
            let isOn = (biometricSwitch.value as? String) == "1"
            if isOn { biometricSwitch.tap() }
            if !cleanTutorial { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
            if (biometricSwitch.value as? String) == "1" {
                biometricSwitch.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
                ).tap()
            }
        }
        let submit = tutorialNode(velockApp, ["恢复账号", "Recover Account"], buttons: true)
        XCTAssertTrue(submit.waitForExistence(timeout: 10), "Recovery form did not expose submit")
        submit.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(submit.waitForNonExistence(timeout: 90),
                      "Recovery form is still visible; a toast or existing account is not recovery success")
        // Recovery is only done when the authenticated dashboard shows up.
        // The vault picker also exposes buttons, so require a real dashboard
        // tab and refuse to accept a silent return to the picker: a false
        // positive here would hide a broken recovery entirely.
        let dashboardTab = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '首页' OR label CONTAINS '凭证' OR label CONTAINS 'Home' OR label CONTAINS 'Credentials'")
        ).firstMatch
        let pickerEntry = velockApp.buttons["创建一个沙盒空间"].firstMatch
        if !dashboardTab.waitForExistence(timeout: 30) || pickerEntry.exists {
            print("VELOCK_RECOVERY_END_STATE_BEGIN\n\(velockApp.debugDescription)\nVELOCK_RECOVERY_END_STATE_END")
            attachScreenshot("velock-recovery-end-state")
            XCTFail("Recovered account did not reach the authenticated dashboard")
            return
        }
        attachScreenshot("replica_velock_recovered_from_qr")
        tutorialHold(1.2, reason: "recovery-complete")
    }

    private func ensureVelockInitializedAndPairingEnabled(
        enablePairing: Bool = true,
        forceRecoveryCard: Bool = false,
        refreshRecoveryCard: Bool = true
    ) {
        let password = ProcessInfo.processInfo.environment["VELOCK_RUNTIME_PASSWORD"] ?? ""
        XCTAssertFalse(password.isEmpty, "Set VELOCK_RUNTIME_PASSWORD at runtime")

        velockApp.terminate()
        velockApp.launch()
        XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 20))
        // Recovery lands on the recovery-card confirmation page. Enter the
        // recovered sandbox before configuring pairing; do not recreate it.
        let recoveredEnter = velockApp.buttons["进入沙盒空间"].firstMatch
        if recoveredEnter.waitForExistence(timeout: 5) &&
            !velockApp.secureTextFields.firstMatch.exists &&
            !velockApp.descendants(matching: .any).matching(NSPredicate(format: "label == '请输入密码'")).firstMatch.exists {
            velockApp.activate()
            let topEnter = velockApp.buttons["进入"].firstMatch
            if topEnter.exists {
                velockApp.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.08)).tap()
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                if velockApp.buttons["进入沙盒空间"].firstMatch.exists {
                    velockApp.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.94)).tap()
                }
            } else {
                recoveredEnter.tap()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            _ = recoveredEnter.waitForNonExistence(timeout: 5)
            for _ in 0..<3 {
                let stillCard = velockApp.buttons["进入沙盒空间"].firstMatch
                if !stillCard.exists { break }
                stillCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1))
            }
            unlockVelockIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(4))
            if velockApp.buttons["进入沙盒空间"].firstMatch.exists {
                // Register-confirm can retain the page while the async login
                // effect is settling; retry the actual top-right action.
                velockApp.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.08)).tap()
                RunLoop.current.run(until: Date().addingTimeInterval(5))
            }
        }
        let createSandbox = velockApp.buttons["创建一个沙盒空间"]
        if createSandbox.waitForExistence(timeout: 3) {
            XCTAssertNotEqual(ProcessInfo.processInfo.environment["E2E_REQUIRE_RECOVERED_ACCOUNT"], "1",
                              "Recovered space disappeared; refusing to create an empty replacement vault")
            createSandbox.tap()
            let name = velockApp.textFields["名称"]
            let firstPassword = velockApp.descendants(matching: .any).matching(
                NSPredicate(format: "label == '密码'")
            ).firstMatch
            let repeatedPassword = velockApp.descendants(matching: .any).matching(
                NSPredicate(format: "label == '重复密码'")
            ).firstMatch
            XCTAssertTrue(name.waitForExistence(timeout: 10))
            name.tap()
            name.typeText(
                ProcessInfo.processInfo.environment["VELOCK_E2E_SANDBOX_NAME"]
                    ?? "Velock E2E Replica"
            )
            XCTAssertTrue(firstPassword.waitForExistence(timeout: 5))
            firstPassword.tap()
            firstPassword.typeText(password)
            XCTAssertTrue(repeatedPassword.waitForExistence(timeout: 5))
            repeatedPassword.tap()
            repeatedPassword.typeText(password)
            XCTAssertGreaterThanOrEqual(velockApp.switches.count, 2)
            velockApp.switches.element(boundBy: 1).tap()
            let submit = velockApp.buttons["创建沙盒空间"]
            XCTAssertTrue(submit.waitForExistence(timeout: 5))
            submit.tap()

            let saveAndEnter = velockApp.buttons["保存并进入"]
            XCTAssertTrue(saveAndEnter.waitForExistence(timeout: 15))
            // Keep a host-side copy of the actual recovery-card QR. The
            // following simulator invocation uses this exact card, rather
            // than a synthetic payload or the old VLSR1 handoff.
            persistRecoveryCardScreenshotIfRequested()
            XCTAssertTrue(saveAndEnter.isHittable, "Recovery-card save button is not hittable")
            saveAndEnter.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            allowPhotoAdditionIfRequested()
            if !velockApp.wait(for: .runningForeground, timeout: 5) {
                // Querying and dismissing the SpringBoard-owned Photos prompt can
                // leave the application inactive on newer simulator runtimes.
                // Bring the already-registered app back before inspecting its
                // post-registration account gate.
                velockApp.activate()
                XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 10))
            }
            if saveAndEnter.waitForExistence(timeout: 3) {
                saveAndEnter.tap()
            }
            // If Photos permission/save fails, production deliberately asks
            // whether to continue without saving the card. Choose the explicit
            // “进入沙盒空间” action so registration is not left half-finished.
            let continueWithoutCard = velockApp.buttons["进入沙盒空间"].firstMatch
            if continueWithoutCard.waitForExistence(timeout: 5) {
                continueWithoutCard.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(2))
            }
            // Registration may intentionally return to the password gate on
            // this iOS runtime. Do not use the localized dashboard tab as the
            // registration oracle; the durable next step is the settings page
            // exposing the pairing control plane.
            if !velockApp.wait(for: .runningForeground, timeout: 2) {
                velockApp.activate()
                XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 10))
            }
            unlockVelockIfNeeded()
            let settingsAfterRegistration = velockApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '设置'")
            ).firstMatch
            if !settingsAfterRegistration.waitForExistence(timeout: 30) {
                print("VELOCK_AFTER_REGISTRATION_BEGIN\n\(velockApp.debugDescription)\nVELOCK_AFTER_REGISTRATION_END")
                attachScreenshot("velock-registration-incomplete")
                XCTFail("Velock registration did not expose the authenticated app after saving the recovery card")
                return
            }
        }

        unlockVelockIfNeeded()
        if !enablePairing {
            return
        }
        if tutorialSourceCapturePending {
            tutorialSourceCapturePending = false
            do { try beginTutorialCapture("01-first-setup") }
            catch { XCTFail("Could not start tutorial capture"); return }
        }
        let settingsTab = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '设置'")
        ).firstMatch
        if settingsTab.waitForExistence(timeout: 10) {
            settingsTab.tap()
        }
        let syncSettings = velockApp.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS '云备份' OR label CONTAINS 'Cloud backup' OR label CONTAINS '实验性 - 数据同步' OR label CONTAINS 'Velock Sync' OR label CONTAINS '数据同步'"
            )
        ).firstMatch
        if !syncSettings.waitForExistence(timeout: 10) {
            // A freshly created account shows more settings rows, and the
            // Flutter list is lazy: the sync entry sits below the fold until
            // the list is scrolled, so it looks "missing" without this.
            for _ in 0..<5 where !syncSettings.exists {
                velockApp.swipeUp()
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            }
        }
        if !syncSettings.waitForExistence(timeout: 10) {
            print("PAIRING_SETTINGS_NOT_FOUND\n\(velockApp.debugDescription)\nPAIRING_SETTINGS_NOT_FOUND_END")
            try? velockApp.debugDescription.write(
                toFile: "/tmp/velock_settings_dump.txt",
                atomically: true,
                encoding: .utf8
            )
            attachScreenshot("pairing-settings-not-found")
            XCTFail("Velock settings did not expose the Velock Sync pairing entry")
            return
        }

        // An incremental source run may already have pairing enabled.  When
        // the caller needs a fresh replacement-device recovery card, rotate
        // the pairing switch in-place instead of wiping the simulator.  This
        // preserves the account and all business data while exercising the
        // same production card-generation path.
        if refreshRecoveryCard && !forceRecoveryCard && !syncSettings.label.contains("未启用"),
           ProcessInfo.processInfo.environment["E2E_RECOVERY_CARD_IMAGE"] != nil {
            syncSettings.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
            let disable = velockApp.buttons["停用"]
            if disable.waitForExistence(timeout: 5) {
                disable.tap()
            }
            XCTAssertTrue(
                syncSettings.waitForExistence(timeout: 10),
                "Pairing settings did not return after disabling the existing descriptor"
            )
        }
        syncSettings.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()

        // A restored second test device can legitimately request membership.
        // Approve only this harness's explicitly named synthetic device; never
        // dismiss or approve an arbitrary real-device authorization prompt.
        let joinPrompt = velockApp.staticTexts["批准新设备加入？"].firstMatch
        if joinPrompt.waitForExistence(timeout: 2) {
            let expectedName = ProcessInfo.processInfo.environment["VELOCK_E2E_SANDBOX_NAME"] ?? "Velock E2E Replica"
            XCTAssertTrue(expectedName.hasPrefix("Velock E2E"))
            let ownDevice = velockApp.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@ AND label CONTAINS '新 iPhone'", expectedName)
            ).firstMatch
            XCTAssertTrue(ownDevice.exists, "Refusing to approve an unrelated device")
            let approveJoin = velockApp.buttons["批准"].firstMatch
            XCTAssertTrue(approveJoin.exists && approveJoin.isHittable)
            approveJoin.tap()
            XCTAssertTrue(joinPrompt.waitForNonExistence(timeout: 15))
        }
        let pairingStatus = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '允许 Sync 连接' OR label CONTAINS 'Allow Sync' OR label CONTAINS '允许新的配对' OR label CONTAINS 'Allow new pairings'")
        ).firstMatch
        for _ in 0..<5 {
            if pairingStatus.waitForExistence(timeout: 1) && pairingStatus.isHittable { break }
            velockApp.swipeUp()
        }
        XCTAssertTrue(pairingStatus.waitForExistence(timeout: 5),
                      "Pairing control missing after navigation: \(velockApp.debugDescription)")
        // The cloud-backup page exposes the control as a real switch whose
        // value, not its label, says whether Sync connections are allowed.
        let enabledBefore = pairingStatus.elementType == .switch
            ? (pairingStatus.value as? String) == "1"
            : (!pairingStatus.label.contains("未启用") ||
               velockApp.descendants(matching: .any)["cloud-backup-status"].label.contains("已开启"))
        if pairingStatus.elementType == .switch && !enabledBefore {
            // The switch's accessibility frame also covers the status card
            // above it; the actual toggle sits at the trailing edge of the
            // bottom list row.
            pairingStatus.coordinate(withNormalizedOffset: CGVector(
                dx: 0.87,
                dy: 1 - 28 / max(pairingStatus.frame.height, 56)
            )).tap()
            let confirm = velockApp.buttons["确认"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                          "Enable confirmation missing: \(velockApp.debugDescription)")
            confirm.tap()
        } else if pairingStatus.elementType != .switch && !enabledBefore {
            pairingStatus.coordinate(
                withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)
            ).tap()
            let enable = velockApp.buttons["启用"]
            XCTAssertTrue(enable.waitForExistence(timeout: 5))
            enable.tap()
        }

        if forceRecoveryCard {
            let regenerate = velockApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '重新生成换机恢复卡'")
            ).firstMatch
            XCTAssertTrue(regenerate.waitForExistence(timeout: 10))
            regenerate.tap()
        }

        // Enabling pairing deliberately opens the replacement-device recovery
        // card page. The card is part of the actual recovery contract, not a
        // test detour: save it, dismiss the Photos permission if requested,
        // and only then assert that the pairing descriptor is published.
        let saveRecoveryCard = velockApp.buttons["保存恢复卡到相册"].firstMatch
        if forceRecoveryCard {
            XCTAssertTrue(
                saveRecoveryCard.waitForExistence(timeout: 30),
                "Forced recovery-card rotation did not open the card page"
            )
        }
        if saveRecoveryCard.waitForExistence(timeout: tutorialCaptureName == nil ? 30 : 2) {
            // This is the Sync-enabled replacement-device card. The initial
            // registration card intentionally has no syncRecovery extension.
            persistRecoveryCardScreenshotIfRequested()
            saveRecoveryCard.tap()
            allowPhotoAdditionIfRequested()
            XCTAssertTrue(
                saveRecoveryCard.waitForNonExistence(timeout: 30),
                "Velock did not return from the replacement-device recovery card"
            )
        }
        // After the card route, Velock offers to jump to Sync. The harness
        // drives Sync itself, so stay in Velock.
        let later = velockApp.buttons["稍后"].firstMatch
        if later.waitForExistence(timeout: 10) {
            later.tap()
        }

        // Once on, the status card reads 「已开启连接功能」 and the switch is
        // exposed on its own without the row label.
        let enabledSwitch = velockApp.switches.matching(
            NSPredicate(format: "value == '1'")
        ).firstMatch
        let enabledLabel = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '已开启连接功能' OR label CONTAINS '已启用'")
        ).firstMatch
        XCTAssertTrue(
            enabledSwitch.waitForExistence(timeout: 30) || enabledLabel.exists,
            "Velock did not publish its pairing descriptor: \(velockApp.debugDescription)"
        )
    }

    private func allowPhotoAdditionIfRequested() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = firstExisting(
            springboard.buttons["允许"],
            springboard.buttons["Allow"]
        )
        if allow.waitForExistence(timeout: 5) {
            allow.tap()
        }
    }

    private func persistRecoveryCardScreenshotIfRequested() {
        let path = ProcessInfo.processInfo.environment["E2E_RECOVERY_CARD_IMAGE"]
            ?? "/tmp/velock-source-card.png"
        // The QR is below the account details on the confirmation page. Keep
        // the card itself in view before capturing it; XCUIScreen writes to
        // the XCTest host filesystem, so the runner can feed it to Photos on
        // the replica simulator without exposing the QR in test logs.
        for _ in 0..<2 {
            velockApp.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        do {
            try XCUIScreen.main.screenshot().pngRepresentation.write(
                to: URL(fileURLWithPath: path)
            )
        } catch {
            XCTFail("Could not persist the source recovery-card screenshot: \(error)")
        }
    }

    private func unlockVelockIfNeeded() {
        // On iOS 26 the Flutter password field can disappear from the
        // accessibility tree while the app is being brought back from the
        // companion deep link. The login screen itself remains stable, so use
        // its production geometry as a fallback instead of silently treating
        // a locked app as authenticated.
        let enterSandbox = velockApp.buttons["进入沙盒空间"].firstMatch
        if enterSandbox.waitForExistence(timeout: 2) {
            let password = ProcessInfo.processInfo.environment["VELOCK_RUNTIME_PASSWORD"] ?? ""
            XCTAssertFalse(password.isEmpty, "Set VELOCK_RUNTIME_PASSWORD at runtime to run the unlock step")
            let field = velockApp.secureTextFields.firstMatch
            let semanticField = velockApp.descendants(matching: .any).matching(
                NSPredicate(format: "label == '请输入密码' OR label == 'Password'")
            ).firstMatch
            let targetField = field.waitForExistence(timeout: 3) ? field : semanticField
            if targetField.waitForExistence(timeout: 3) {
                targetField.tap()
                let secureAfterTap = velockApp.secureTextFields.firstMatch
                if secureAfterTap.waitForExistence(timeout: 3) {
                    secureAfterTap.typeText(password)
                } else {
                    velockApp.typeText(password)
                }
            } else {
                // The recovered confirmation page also exposes “进入沙盒空间”,
                // but has no password field. Do not send text to the application
                // itself: XCTest then fails with “Neither element nor any
                // descendant has keyboard focus”. Treat this as already unlocked.
                enterSandbox.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                return
            }
            enterSandbox.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            return
        }
        let labeledPassword = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["请输入密码", "Password"])
        ).firstMatch
        guard labeledPassword.waitForExistence(timeout: 8)
                || velockApp.secureTextFields.firstMatch.waitForExistence(timeout: 2)
                || velockApp.textFields.firstMatch.waitForExistence(timeout: 2) else {
            return
        }

        let password = ProcessInfo.processInfo.environment["VELOCK_RUNTIME_PASSWORD"] ?? ""
        XCTAssertFalse(password.isEmpty, "Set VELOCK_RUNTIME_PASSWORD at runtime to run the unlock step")

        let securePassword = velockApp.secureTextFields.firstMatch
        let field = securePassword.exists
            ? securePassword
            : (labeledPassword.exists ? labeledPassword : velockApp.textFields.firstMatch)
        field.tap()
        if field.elementType == .secureTextField || field.elementType == .textField {
            // Flutter can expose the focused password input as a generic
            // semantics element. Sending keys through the application mirrors
            // real keyboard input even when XCUIElement.typeText cannot resolve
            // that modern text-input automation type.
            field.typeText(password)
        } else {
            // Flutter's Cupertino password field is a GenericElement on iOS
            // 26. The element is still the real first responder, but tapping
            // individual AX keyboard keys is flaky when the keyboard is
            // being animated. Send the string to the application just as a
            // user typing into that focused field would.
            velockApp.typeText(password)
        }

        for button in [
            velockApp.buttons["tkBtn_lock_unlock"],
            velockApp.buttons["解锁"],
            velockApp.buttons["进入沙盒空间"],
            velockApp.buttons["Login"],
        ] {
            if button.waitForExistence(timeout: 3) {
                button.tap()
                return
            }
        }
        XCTFail("Velock password gate did not expose its submit action")
    }

    private func createLocalWebDAVConnectionIfNeeded() {
        // A retained pairing wizard hides the tab bar; leave it first so the
        // Connections tab can be reached.
        if syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '开始连接格间' OR label == '格间备份'")
        ).firstMatch.waitForExistence(timeout: 3) {
            for _ in 0..<3 {
                let back = syncApp.buttons.firstMatch
                if back.exists && back.isHittable {
                    syncApp.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.06, dy: 0.09)
                    ).tap()
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                if syncApp.staticTexts["连接"].exists || syncApp.buttons["连接"].exists {
                    break
                }
            }
        }
        let connectionsTab = firstExisting(
            syncApp.staticTexts["Connections"],
            syncApp.staticTexts["连接"],
            syncApp.buttons["Connections"],
            syncApp.buttons["连接"]
        )
        XCTAssertTrue(connectionsTab.waitForExistence(timeout: 15), "Connections tab was not exposed\n\(syncApp.debugDescription)")
        connectionsTab.tap()
        // “新建连接” is also the page title/action on an empty page, so it
        // cannot indicate that a connection already exists. The page can
        // also still be loading (the empty-state marker is not rendered
        // yet), so poll for either the empty-state marker or an existing
        // connection tile instead of assuming after three seconds.
        let emptyState = syncApp.descendants(matching: .any)["还没有远端连接"]
        let existingConnection = syncApp.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS 'WebDAV · ' OR label CONTAINS '已连接服务' OR label CONTAINS 'Google Drive · ' OR label CONTAINS 'OneDrive · '"
            )
        ).firstMatch
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if emptyState.exists || existingConnection.exists {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        if existingConnection.exists {
            print("E2E_CONNECTION_EXISTS label=\(existingConnection.label)")
            return
        }
        XCTAssertTrue(
            emptyState.waitForExistence(timeout: 10),
            "Connections page showed neither empty state nor an existing connection: \(syncApp.debugDescription)"
        )
        let addConnection = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '添加远端连接'")
        ).firstMatch
        XCTAssertTrue(addConnection.waitForExistence(timeout: 5))
        addConnection.tap()

        let protocolChoice = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '选择协议' OR label CONTAINS '选择远端协议'")
        ).firstMatch
        XCTAssertTrue(protocolChoice.waitForExistence(timeout: 5))
        protocolChoice.tap()
        let webDAV = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'WebDAV'")
        ).firstMatch
        XCTAssertTrue(webDAV.waitForExistence(timeout: 5))
        webDAV.tap()

        fillWebDAVConnectionForm()
    }

    /// Fills and saves the WebDAV connection form on the current screen.
    /// 选择云端位置 → 添加云端位置 → WebDAV, filled with this run's anonymous
    /// local WsgiDAV endpoint over HTTP.
    private func fillWebDAVConnectionForm() {
        let httpsSwitch = syncApp.switches.firstMatch
        XCTAssertTrue(httpsSwitch.waitForExistence(timeout: 5))
        httpsSwitch.tap()
        let allowHTTP = syncApp.buttons["仍然使用 HTTP"]
        XCTAssertTrue(allowHTTP.waitForExistence(timeout: 5))
        allowHTTP.tap()

        let address = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '服务器地址'")
        ).firstMatch
        let port = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '端口' OR label CONTAINS 'Port' OR label CONTAINS 'port'")
        ).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        if !port.waitForExistence(timeout: 5) {
            print("WEBDAV_FORM_UI_BEGIN\n\(syncApp.debugDescription)\nWEBDAV_FORM_UI_END")
            XCTFail("WebDAV port field was not exposed by the iOS form")
            return
        }
        address.tap()
        syncApp.typeText("127.0.0.1")
        port.tap()
        syncApp.typeText(webDAVPort)
        let save = syncApp.buttons["保存"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(syncApp.descendants(matching: .any)["新建连接"].waitForExistence(timeout: 20))
    }

    private func openSelectedFolderProfileList(screenshotName: String) {
        tapHomeTab("同步", normalizedX: 0.125, screenshotName: screenshotName)
        let create = largestButton(in: syncApp, containing: "新建同步")
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        tapFirstContaining("同步文件夹")
    }

    /// Taps this run's local WebDAV endpoint inside the "选择远端连接"
    /// action sheet used by the folder-sync flows.
    ///
    /// The action label embeds the saved URL (name line plus target label),
    /// so the current run's port is the only stable discriminator. The
    /// sheet title can render before the action rows settle, so poll the
    /// port-scoped predicate and capture the sheet tree when it never
    /// matches instead of failing blind.
    private func tapRemoteConnectionInPicker(context: String) {
        XCTAssertTrue(
            syncApp.staticTexts["选择远端连接"].waitForExistence(timeout: 10),
            "Remote connection sheet did not open in \(context): \(syncApp.debugDescription)"
        )
        writeDebugTree(syncApp.debugDescription, name: "picker-raw-\(context)")

        let connection = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "127.0.0.1:\(webDAVPort)")
        ).firstMatch
        if !connection.waitForExistence(timeout: 20) {
            writeDebugTree(syncApp.debugDescription, name: "picker-missing-\(context)")
            print("PICKER_MISSING_BEGIN[\(context)]\n\(syncApp.debugDescription)\nPICKER_MISSING_END")
            XCTFail("WebDAV connection on port \(webDAVPort) was not selectable in \(context)")
        }
        connection.tap()
    }

    private func selectFixtureFolder(named folderName: String) {
        let pickerMarker = syncApp.descendants(matching: .any).matching(
            NSPredicate(
                format: "label IN %@",
                ["浏览", "Browse", "最近项目", "Recents", "在我的 iPhone 上", "On My iPhone"]
            )
        ).firstMatch
        XCTAssertTrue(pickerMarker.waitForExistence(timeout: 15), "System directory picker did not appear")

        // The document picker remembers the last selected directory. If it is
        // already inside the requested fixture folder, use that visible location
        // instead of requiring the host/folder breadcrumb cells again.
        let alreadyInsideFolder = syncApp.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "\(folderName), 操作菜单")
        ).firstMatch
        if alreadyInsideFolder.waitForExistence(timeout: 2) {
            let open = syncApp.buttons["打开"]
            XCTAssertTrue(open.waitForExistence(timeout: 10))
            open.tap()
            return
        }

        let localStorage = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "identifier CONTAINS 'com.apple.FileProvider.LocalStorage'")
        ).firstMatch
        if !localStorage.exists {
            let browse = syncApp.tabBars["DOC.browsingModeTabBar"].buttons["浏览"]
            XCTAssertTrue(browse.waitForExistence(timeout: 5))
            browse.tap()
        }

        let fixtureHost = syncApp.cells.matching(
            NSPredicate(format: "identifier BEGINSWITH 'CrossAppUITestHost'")
        ).firstMatch
        if !fixtureHost.waitForExistence(timeout: 10) {
            writeDebugTree(syncApp.debugDescription, name: "document-picker")
        }
        XCTAssertTrue(fixtureHost.waitForExistence(timeout: 10))
        fixtureHost.tap()

        let folder = syncApp.cells.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", folderName)
        ).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.tap()

        let open = syncApp.buttons["打开"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
    }

    private func prepareFixtureHost() {
        let fixtureApp = XCUIApplication(bundleIdentifier: fixtureHostBundleID)
        fixtureApp.launch()
        XCTAssertTrue(fixtureApp.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(
            fixtureApp.descendants(matching: .any)["fixture-details"]
                .waitForExistence(timeout: 10),
            "Fixture host did not prepare its shared Documents folders"
        )
        fixtureApp.terminate()
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func durableCompletedStatus(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'completed'")
        ).firstMatch
    }

    private func captureValue(named name: String, in report: String) -> String? {
        let prefix = "\(name): "
        return report.split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasPrefix(prefix) })?
            .dropFirst(prefix.count)
            .description
    }

    private func waitForAny(_ candidates: XCUIElement..., timeout: TimeInterval = 10) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let match = candidates.first(where: { $0.exists }) {
                return match
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return candidates[0]
    }

    private func writeDebugTree(_ value: String, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["E2E_DEBUG_TREE_DIR"],
              !directory.isEmpty else {
            return
        }
        let path = "\(directory)/\(name).txt"
        try? value.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func largestButton(in app: XCUIApplication, containing label: String) -> XCUIElement {
        let matches = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", label)
        )
        var best = matches.firstMatch
        var bestArea: CGFloat = -1
        for index in 0..<matches.count {
            let candidate = matches.element(boundBy: index)
            let area = candidate.frame.width * candidate.frame.height
            if candidate.exists && area > bestArea {
                best = candidate
                bestArea = area
            }
        }
        return best
    }

    private func firstExisting(_ candidates: XCUIElement...) -> XCUIElement {
        for candidate in candidates {
            if candidate.exists {
                return candidate
            }
        }
        return candidates[0]
    }

    private enum UIOutcome: String {
        case success
        case failure
        case timedOut
    }

    private func waitForOutcome(
        success: XCUIElement,
        failure: XCUIElement,
        timeout: TimeInterval
    ) -> UIOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if success.exists {
                return .success
            }
            if failure.exists {
                return .failure
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.20))
        } while Date() < deadline
        return .timedOut
    }

    /// Read-only on-device check of the file-sync storage page: the writable
    /// folder entry must exist on the real app, and a new folder may be chosen
    /// as long as the confirmation is never accepted. No sync, no relocation,
    /// no server write is performed by this test.
    func testFileSyncStorageFolderEntryIsUsable() {
        let artifactRoot = ProcessInfo.processInfo.environment["E2E_ARTIFACT_DIR"]
        func capture(_ name: String) {
            attachScreenshot(name)
            guard let root = artifactRoot else { return }
            try? XCUIScreen.main.screenshot().pngRepresentation.write(
                to: URL(fileURLWithPath: root).appendingPathComponent(name + ".png"))
        }
        func text(_ needle: String) -> XCUIElement {
            syncApp.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", needle)).firstMatch
        }
        func tapText(_ needle: String, timeout: TimeInterval = 10) -> Bool {
            let element = text(needle)
            guard element.waitForExistence(timeout: timeout) && element.isHittable else {
                print("FOLDER_ENTRY_MISSING \(needle)")
                capture("folder-entry-missing")
                return false
            }
            element.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
            return true
        }

        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
        tapHomeTab("文件同步", normalizedX: 0.5, screenshotName: "file-sync-tab")

        if text("检查保存位置").waitForExistence(timeout: 5) {
            _ = tapText("检查保存位置")
        } else if tapText("文件同步") {
            _ = tapText("检查保存位置")
        }
        capture("storage-help-open")

        XCTAssertTrue(
            text("保存位置").waitForExistence(timeout: 10),
            "Storage page did not open: \(syncApp.debugDescription)")
        XCTAssertTrue(
            text("选择可写入文件夹").waitForExistence(timeout: 10),
            "The writable folder entry is missing on the real page")
        XCTAssertFalse(
            text("尚不支持直接迁移").exists,
            "The stale 'migration not supported' copy is still shown")

        guard tapText("选择可写入文件夹") else { return }
        capture("writable-folder-picker")

        // Browsing is read-only: this only lists the connection's folders.
        let share = syncApp.buttons["USB_HDD_8T"].firstMatch
        XCTAssertTrue(
            share.waitForExistence(timeout: 20),
            "The connection folder list did not load: \(syncApp.debugDescription)")
        capture("writable-folder-connection-root")
        share.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        let folder = syncApp.buttons["111"].firstMatch
        XCTAssertTrue(
            folder.waitForExistence(timeout: 20),
            "The user's 111 folder is not visible: \(syncApp.debugDescription)")
        XCTAssertTrue(
            syncApp.buttons["222"].firstMatch.exists,
            "The user's 222 folder is not visible")
        capture("writable-folder-inside-share")

        // Selecting and confirming is verified, but never accepted: no profile
        // is saved, no sync runs and no server write happens in this test.
        folder.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let useThisFolder = text("使用这个文件夹")
        XCTAssertTrue(
            useThisFolder.waitForExistence(timeout: 10) && useThisFolder.isHittable,
            "The picker cannot confirm a folder")
        useThisFolder.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        XCTAssertTrue(
            text("更改这个任务的保存位置？").waitForExistence(timeout: 10),
            "The relocation confirmation did not appear: \(syncApp.debugDescription)")
        XCTAssertTrue(
            text("不会删除或迁移旧文件夹里的数据").exists,
            "The confirmation does not state that old data is kept")
        capture("relocation-confirmation")
        if text("取消").waitForExistence(timeout: 5) {
            text("取消").tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        }
        XCTAssertTrue(
            text("保存位置").exists,
            "Cancelling left the storage page")
        capture("relocation-cancelled")
    }


    // MARK: - Whole-app tour of Sync (runs after the backup stage of e2e.sh)

    /// Walks every user-facing area of Sync on top of a finished Velock backup:
    /// backup details/manage/history, a plain two-way file sync location from
    /// creation to removal (both directions plus a propagated deletion, checked
    /// on the real files), connection management, every settings entry, and a
    /// final backup. File evidence is checked here on the host paths and again
    /// by app_tour.sh. Requires E2E_WEBDAV_ROOT and E2E_PLAIN_LOCAL_DIR.
    func testSyncAppTour() {
        let env = ProcessInfo.processInfo.environment
        guard let webdavRoot = env["E2E_WEBDAV_ROOT"], let localDir = env["E2E_PLAIN_LOCAL_DIR"],
              let plainRoot = env["E2E_PLAIN_WEBDAV_ROOT"] else {
            XCTFail("E2E_WEBDAV_ROOT, E2E_PLAIN_WEBDAV_ROOT and E2E_PLAIN_LOCAL_DIR are required")
            return
        }
        // File sync goes to a second server: the Velock backup owns the first
        // server's root, and a plain mirror may never overlap a backup folder.
        let plainPort = env["E2E_PLAIN_PORT"] ?? "18992"
        let remoteName = env["E2E_PLAIN_REMOTE_NAME"] ?? "plain-e2e"
        let localFolderName = URL(fileURLWithPath: localDir).lastPathComponent
        let remoteDir = URL(fileURLWithPath: plainRoot).appendingPathComponent(remoteName)
        let local = URL(fileURLWithPath: localDir)

        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))

        // E2E_TOUR_FROM=B|C|D resumes a failed tour at a later area.
        let from = env["E2E_TOUR_FROM"] ?? "A"
        if from <= "A" {
        // ── A. 格间备份：首页、详情、记录、管理、诊断
        tourStep("A1 backup home")
        waitLabel(["上次备份已完成"], "backup home is not in the completed state", timeout: 60)
        tourBackupNow()
        tourTap(syncApp.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'velock-backup-details-'")).firstMatch, "details")
        tourStep("A2 backup details")
        tourTap(tourBegins("云端保存位置"), "cloud location")
        tourWait(element(syncApp, "folder-view-toggle"), "backup folder browser")
        tourWait(syncApp.buttons["velock-sync"], "the velock-sync folder in the backup location")
        tourStep("A2 backup folder browser")
        tourTap(element(syncApp, "folder-view-toggle"), "list view")
        tourStep("A2 list view")
        tourTap(element(syncApp, "folder-view-toggle"), "grid view")
        tourTap(element(syncApp, "connection-info"), "connection info")
        tourStep("A2 connection info")
        tourDismissSheet()
        tourBack()
        tourTap(tourBegins("传输记录"), "transfer history")
        let run = syncApp.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'history-run-'")).firstMatch
        tourWait(run, "a history row")
        tourStep("A3 history")
        tourTap(run, "history row")
        tourStep("A3 run details")
        tourDismissSheet()
        tourBack()
        tourTap(tourBegins("管理"), "manage")
        tourStep("A4 manage")
        tourTap(element(syncApp, "manage-change-location"), "change location")
        tourWait(element(syncApp, "use-backup-folder"), "backup folder picker")
        tourStep("A4 backup folder picker")
        tourCreateRemoteFolder("tour-backup-candidate", button: "new-backup-folder")
        waitLabel(["已进入新文件夹"], "created-folder note", contains: true)
        tourStep("A4 created folder (not used)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: webdavRoot)
            .appendingPathComponent("tour-backup-candidate").path), "new backup folder missing on the server")
        tourBack() // up to the connection root
        tourBack() // leave the picker without choosing
        tourWait(element(syncApp, "manage-change-location"), "back on manage")
        tourBack()
        tourTap(tourBegins("暂停备份"), "pause backup")
        waitLabel(["已暂停", "继续备份"], "backup did not pause")
        tourStep("A5 paused")
        tourTap(tourBegins("继续备份"), "resume backup")
        tourWait(tourBegins("暂停备份"), "backup did not resume")
        tourTap(element(syncApp, "backup-diagnostics"), "diagnostics")
        waitLabel(["已同步的数据"], "diagnostics page")
        tourStep("A6 diagnostics")
        tourBack()
        tourBack()
        tourTap(element(syncApp, "velock-cloud-restore"), "restore guide")
        tourStep("A7 restore guide (entry only)")
        tourBack()

        }
        if from <= "B" {
        // ── B. 文件同步：新建位置、首次双向、增量双向、详情、草稿、暂停、删除传播、删除位置
        tourTab("文件同步")
        // A resumed tour may find the location of a failed attempt; it owns the
        // local folder, so remove it first (keeps both sides' files).
        let leftover = syncApp.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'plain-location-open-'")).firstMatch
        if leftover.waitForExistence(timeout: 3) {
            leftover.tap()
            tourScrollTo(element(syncApp, "plain-remove"))
            tourTap(element(syncApp, "plain-remove"), "remove leftover location")
            tourTap(element(syncApp, "plain-remove-confirm"), "confirm leftover removal")
        }
        tourStep("B1 file sync empty")
        tourTap(element(syncApp, "plain-location-create"), "add location")
        tourTap(element(syncApp, "plain-pick-local"), "pick local folder")
        tourPickHostFolder(localFolderName)
        waitLabel([localFolderName + "\n已选择"], "local folder not selected")
        tourStep("B2 step 1 done")
        tourTap(element(syncApp, "plain-wizard-next-1"), "next 1")
        tourTap(element(syncApp, "plain-add-another-connection"), "add a connection from the wizard")
        tourWait(element(syncApp, "protocol-webDav"), "protocols for file sync")
        tourStep("B3 protocols for file sync")
        tourAddWebDAV(port: plainPort, name: "E2E Files")
        let connection = syncApp.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'plain-remote-' AND label BEGINSWITH 'E2E Files'")).firstMatch
        tourWait(connection, "the new connection back in the wizard", timeout: 30)
        tourStep("B3 new connection in the wizard")
        tourTap(connection, "the file sync connection")
        tourWait(element(syncApp, "use-backup-folder"), "remote folder picker")
        tourStep("B3 remote picker")
        tourCreateRemoteFolder(remoteName, button: "new-backup-folder")
        waitLabel(["已进入新文件夹"], "created remote folder", contains: true)
        // Something only the remote has, so the first sync also downloads.
        tourWrite(remoteDir.appendingPathComponent("from-remote.txt"), "made on the server before the first sync")
        tourStep("B3 created remote folder")
        tourTap(element(syncApp, "use-backup-folder"), "use remote folder")
        tourStep("B4 step 2 done")
        tourTap(element(syncApp, "plain-wizard-next-2"), "next 2")
        tourWait(tourOption("双向同步"), "direction options")
        tourStep("B5 step 3")
        tourTap(element(syncApp, "plain-wizard-create"), "create")
        tourWaitFiles("first sync",
                      present: [remoteDir.appendingPathComponent("hello.txt"),
                                remoteDir.appendingPathComponent("docs/readme.md"),
                                remoteDir.appendingPathComponent("photos/proof.png"),
                                local.appendingPathComponent("from-remote.txt")])
        waitLabel(["已是最新", "同步完成"], "first sync did not finish", timeout: 60)
        tourStep("B6 first sync done")
        tourCompareBytes(local.appendingPathComponent("photos/proof.png"), remoteDir.appendingPathComponent("photos/proof.png"))

        tourWrite(local.appendingPathComponent("local-later.txt"), "added on the phone after the first sync")
        tourWrite(remoteDir.appendingPathComponent("docs/remote-later.txt"), "added on the server after the first sync")
        tourTap(syncApp.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'plain-location-run-'")).firstMatch, "sync now")
        tourWaitFiles("second sync",
                      present: [remoteDir.appendingPathComponent("local-later.txt"),
                                local.appendingPathComponent("docs/remote-later.txt")])
        waitLabel(["已是最新", "同步完成"], "second sync did not finish", timeout: 60)
        tourStep("B7 second sync done")

        // Both sides edit the same file: keep-both renames the phone's copy.
        tourWrite(local.appendingPathComponent("hello.txt"), "edited on the phone")
        tourWrite(remoteDir.appendingPathComponent("hello.txt"), "edited on the server")
        tourTap(syncApp.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'plain-location-run-'")).firstMatch, "sync a conflict")
        let conflictDeadline = Date().addingTimeInterval(90)
        func conflictCopies() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: local.path)) ?? []).filter { $0.hasPrefix("hello (") }
        }
        while conflictCopies().isEmpty && Date() < conflictDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertEqual(conflictCopies().count, 1, "keep-both did not save the phone's copy")
        XCTAssertEqual(try? String(contentsOf: local.appendingPathComponent("hello.txt"), encoding: .utf8), "edited on the server")
        if let copy = conflictCopies().first {
            XCTAssertEqual(try? String(contentsOf: local.appendingPathComponent(copy), encoding: .utf8), "edited on the phone")
        }
        waitLabel(["冲突 1"], "conflict badge on the card", timeout: 30)
        tourStep("B7 conflict kept both")

        tourTap(syncApp.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'plain-location-open-'")).firstMatch, "location details")
        tourWait(element(syncApp, "plain-local-folder"), "location detail page")
        tourStep("B8 location details")
        tourTap(syncApp.staticTexts.matching(NSPredicate(format: "label == '打开'")).element(boundBy: 1), "open remote folder")
        tourWait(tourEntry("local-later.txt"), "remote folder in the in-app browser")
        tourStep("B8 remote folder opened")
        tourBackUntil(element(syncApp, "plain-local-folder"), "back on location details")
        syncApp.staticTexts.matching(NSPredicate(format: "label == '打开'")).element(boundBy: 0).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        tourStep("B8 local folder opened (system Files)")
        if syncApp.state != .runningForeground {
            syncApp.activate()
            XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 10))
        } else {
            tourDismissSheet()
        }
        tourWait(element(syncApp, "plain-local-folder"), "location details after opening the local folder")

        tourTap(tourOption("仅上传"), "upload only (draft)")
        tourWait(syncApp.buttons.matching(NSPredicate(format: "label == '保存'")).firstMatch, "save button for the draft")
        tourStep("B9 draft")
        tourBack()
        tourTap(syncApp.buttons.matching(NSPredicate(format: "identifier == 'plain-draft-save' OR label == '保存'")).element(boundBy: 0), "save on leave")
        waitLabel(["仅上传"], "saved direction is not shown on the card")
        tourStep("B9 saved upload only")
        tourTap(syncApp.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'plain-location-open-'")).firstMatch, "location details")
        tourTap(tourOption("双向同步"), "two-way (draft)")
        tourTap(syncApp.buttons.matching(NSPredicate(format: "label == '保存'")).firstMatch, "save")
        tourGone(syncApp.buttons.matching(NSPredicate(format: "label == '保存'")).firstMatch, "save button stays after saving")
        tourStep("B9 back to two-way")

        tourTap(element(syncApp, "plain-detail-pause"), "pause")
        waitLabel(["继续同步"], "location did not pause")
        tourStep("B10 paused")
        tourTap(element(syncApp, "plain-detail-run"), "resume")
        tourWait(element(syncApp, "plain-detail-pause"), "location did not resume")

        tourScrollTo(element(syncApp, "plain-conflicts"))
        tourTap(element(syncApp, "plain-conflicts"), "conflict history")
        tourStep("B11 conflict history")
        tourTap(syncApp.buttons.matching(NSPredicate(format: "identifier == 'plain-conflicts-clear' OR label == '清除记录'")).firstMatch, "clear conflict records")
        tourGone(element(syncApp, "plain-conflicts"), "conflict records were not cleared")
        tourStep("B11 conflict records cleared")

        try? FileManager.default.removeItem(at: local.appendingPathComponent("local-later.txt"))
        tourScrollTo(element(syncApp, "plain-detail-run"), up: true)
        tourTap(element(syncApp, "plain-detail-run"), "sync after a local deletion")
        let deletionReview = element(syncApp, "plain-confirm-deletions")
        let deadline = Date().addingTimeInterval(60)
        while FileManager.default.fileExists(atPath: remoteDir.appendingPathComponent("local-later.txt").path) && Date() < deadline {
            if deletionReview.exists { tourStep("B12 deletion review"); deletionReview.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteDir.appendingPathComponent("local-later.txt").path),
                       "a local deletion did not reach the server")
        waitLabel(["已是最新", "同步完成"], "deletion sync did not finish", timeout: 60)
        tourStep("B12 deletion synced")

        tourScrollTo(element(syncApp, "plain-remove"))
        tourTap(element(syncApp, "plain-remove"), "delete location")
        tourStep("B13 delete location?")
        tourTap(element(syncApp, "plain-remove-confirm"), "confirm delete location")
        tourWait(element(syncApp, "plain-location-create"), "empty file sync page after removal")
        tourStep("B13 location removed")
        for kept in [remoteDir.appendingPathComponent("hello.txt"), local.appendingPathComponent("hello.txt")] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "removing the location deleted \(kept.lastPathComponent)")
        }

        }
        if from <= "C" {
        // ── C. 设置：连接、传输记录、语言、后台、诊断、关于
        tourTab("设置")
        tourStep("C1 settings")
        tourTap(element(syncApp, "manage-cloud-locations"), "connections")
        let row = syncApp.buttons.matching(NSPredicate(format: "label CONTAINS %@", "127.0.0.1:\(webDAVPort)")).firstMatch
        let filesRow = syncApp.buttons.matching(NSPredicate(format: "label CONTAINS %@", "127.0.0.1:\(plainPort)")).firstMatch
        tourWait(row, "WebDAV connection row")
        tourStep("C2 connections")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        tourTap(tourExact(["连接说明"], buttons: false), "connection info (menu)")
        tourStep("C2 connection info")
        tourDismissSheet()
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        tourTap(tourExact(["修改连接"], buttons: false), "edit connection")
        tourTap(element(syncApp, "webdav_name"), "name field")
        let current = (element(syncApp, "webdav_name").value as? String) ?? ""
        syncApp.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        syncApp.typeText("E2E Backup")
        tourStep("C3 renamed")
        tourTap(element(syncApp, "webdav-save"), "save connection")
        let renamed = syncApp.buttons.matching(NSPredicate(format: "label BEGINSWITH 'E2E Backup'")).firstMatch
        tourWait(renamed, "renamed connection", timeout: 30)
        tourStep("C3 renamed connection")
        tourWait(filesRow, "file sync connection row")
        filesRow.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        tourWait(element(syncApp, "folder-view-toggle"), "connection browser")
        tourStep("C4 connection browser")
        tourTap(element(syncApp, "folder-view-toggle"), "list view")
        tourStep("C4 list view")
        tourTap(element(syncApp, "folder-view-toggle"), "grid view")
        tourCreateRemoteFolder("tour-folder", button: "remote-browser-new-folder")
        tourWait(tourEntry("tour-folder"), "new folder in the browser")
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: plainRoot)
            .appendingPathComponent("tour-folder").path), "browser folder missing on the server")
        tourStep("C4 created folder")
        tourTap(tourEntry("\(remoteName)"), "open the sync folder")
        tourWait(tourEntry("hello.txt"), "synced files in the browser")
        tourStep("C4 synced folder on the server")
        tourTap(element(syncApp, "remote-browser-reload"), "reload")
        tourBack() // parent folder
        tourWait(tourEntry("tour-folder"), "connection root")
        tourBack()
        tourTap(syncApp.buttons["检查连接状态"].firstMatch, "check connections")
        waitLabel(["\n已连接\n"], "connection is not reported as connected", timeout: 20, contains: true)
        tourTap(syncApp.buttons["新建连接"].firstMatch, "new connection")
        for name in ["WebDAV", "Google Drive", "OneDrive", "百度网盘", "阿里云盘"] {
            waitLabel([name], "protocol \(name) is missing", contains: true)
        }
        tourStep("C5 protocols")
        tourBack()
        tourBack()
        tourTap(tourExact(["所有传输记录"], buttons: false), "all history")
        waitLabel(["最近同步"], "activity page")
        tourStep("C6 activity")
        tourBack()
        tourTap(element(syncApp, "sync-language-setting"), "language")
        tourTap(element(syncApp, "sync-language-en"), "English")
        tourBack()
        waitLabel(["Settings"], "English UI did not apply")
        tourStep("C7 English")
        tourTap(element(syncApp, "sync-language-setting"), "language")
        tourTap(element(syncApp, "sync-language-zh"), "简体中文")
        tourBack()
        waitLabel(["设置"], "Chinese UI did not come back")
        tourTap(element(syncApp, "global-background-enabled"), "background off")
        tourStep("C8 background toggled")
        tourTap(element(syncApp, "global-background-enabled"), "background on")
        tourDismissSheet()
        tourScrollTo(tourExact(["导出脱敏诊断"], buttons: false))
        tourTap(tourBegins("导出脱敏诊断"), "diagnostics")
        tourWait(element(syncApp, "copy-sanitized-diagnostics"), "sanitized diagnostics")
        tourStep("C9 sanitized diagnostics")
        tourTap(tourExact(["完成"], buttons: true), "done")
        tourScrollTo(tourBegins("关于与开源许可"))
        tourTap(tourBegins("关于与开源许可"), "licenses")
        waitLabel(["Velock Sync"], "license page")
        tourStep("C10 licenses")
        tourBack()

        }
        // ── D. 改名后的连接仍能备份
        tourTab("格间")
        tourBackupNow()
        tourStep("D1 final backup")
    }

    /// A file or folder tile/row in the remote browsers (labelled by its name).
    private func tourEntry(_ name: String) -> XCUIElement {
        syncApp.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + "\n")).firstMatch
    }

    /// A PlainOptionRow (title, newline, full description).
    private func tourOption(_ title: String) -> XCUIElement {
        syncApp.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", title + "\n")).firstMatch
    }

    private func tourStep(_ name: String) {
        print("TOUR_STEP \(name)")
        attachScreenshot("tour-" + name)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    private func tourBegins(_ prefix: String) -> XCUIElement {
        syncApp.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func tourExact(_ labels: [String], buttons: Bool) -> XCUIElement {
        (buttons ? syncApp.buttons : syncApp.descendants(matching: .any))
            .matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    private func tourWait(_ target: XCUIElement, _ what: String, timeout: TimeInterval = 15) {
        if !target.waitForExistence(timeout: timeout) { failWithTree("TOUR missing: \(what)") }
    }

    private func tourGone(_ target: XCUIElement, _ what: String, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while target.exists && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        if target.exists { failWithTree("TOUR: \(what)") }
    }

    private func tourTap(_ target: XCUIElement, _ what: String, timeout: TimeInterval = 15) {
        tourWait(target, what, timeout: timeout)
        if !target.isHittable { tourScrollTo(target) }
        target.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    private func waitLabel(_ labels: [String], _ message: String, timeout: TimeInterval = 15, contains: Bool = false) {
        let predicates = labels.map {
            contains ? NSPredicate(format: "label CONTAINS %@", $0)
                     : NSPredicate(format: "label == %@ OR label BEGINSWITH %@", $0, $0 + "\n")
        }
        let target = syncApp.descendants(matching: .any)
            .matching(NSCompoundPredicate(orPredicateWithSubpredicates: predicates)).firstMatch
        if !target.waitForExistence(timeout: timeout) { failWithTree("TOUR: \(message)") }
    }

    private func tourTab(_ label: String) {
        let tab = syncApp.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
            .allElementsBoundByIndex.last { $0.frame.minY > syncApp.frame.height * 0.85 }
        guard let tab else { failWithTree("TOUR: tab \(label) missing"); return }
        tab.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    /// The header back control (返回 / 上一步 / Back), whichever is showing.
    private func tourBack() {
        let back = syncApp.buttons.matching(NSPredicate(
            format: "identifier == 'app-back' OR label BEGINSWITH '返回' OR label BEGINSWITH '上一步' OR label BEGINSWITH 'Back' OR label BEGINSWITH 'Parent folder'")).firstMatch
        tourTap(back, "back button")
    }

    /// Steps back (folder browsers go up a level first) until [target] shows.
    private func tourBackUntil(_ target: XCUIElement, _ what: String) {
        for _ in 0..<4 {
            if target.waitForExistence(timeout: 2) { return }
            tourBack()
        }
        tourWait(target, what)
    }

    /// Closes whatever dialog or sheet is up through its own close button.
    private func tourDismissSheet() {
        let close = syncApp.buttons.matching(NSPredicate(
            format: "label IN %@", ["完成", "关闭", "知道了", "好", "取消", "Done", "Close", "OK"])).firstMatch
        if close.waitForExistence(timeout: 3) {
            close.tap()
        } else {
            syncApp.swipeDown(velocity: .fast)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    private func tourScrollTo(_ target: XCUIElement, up: Bool = false) {
        for _ in 0..<8 {
            if target.exists && target.isHittable { return }
            up ? syncApp.swipeDown(velocity: .slow) : syncApp.swipeUp(velocity: .slow)
            // Let the scroll settle; a tap during momentum is swallowed.
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
    }

    private func tourCreateRemoteFolder(_ name: String, button: String) {
        tourTap(element(syncApp, button), "new folder button")
        // The name field opens focused (keyboard up); it has no AX identifier.
        tourWait(element(syncApp, "confirm-new-backup-folder"), "new folder dialog")
        tourWait(syncApp.keyboards.firstMatch, "keyboard for the folder name")
        syncApp.typeText(name)
        tourStep("new folder dialog \(name)")
        tourTap(element(syncApp, "confirm-new-backup-folder"), "create folder")
    }

    private func tourAddWebDAV(port: String, name: String, host: String = "127.0.0.1") {
        tourTap(element(syncApp, "protocol-webDav"), "WebDAV")
        tourTap(element(syncApp, "webdav_https"), "https switch")
        tourTap(element(syncApp, "webdav-allow-http"), "allow http", timeout: 5)
        tourTap(element(syncApp, "webdav_address"), "address")
        syncApp.typeText(host)
        tourTap(element(syncApp, "webdav_port"), "port")
        syncApp.typeText(port)
        tourScrollTo(element(syncApp, "webdav_name"))
        tourTap(element(syncApp, "webdav_name"), "name")
        syncApp.typeText(name)
        tourStep("WebDAV form \(name)")
        tourScrollTo(element(syncApp, "webdav-save"))
        tourTap(element(syncApp, "webdav-save"), "save WebDAV")
    }

    private func tourBackupNow() {
        tourTap(element(syncApp, "backup-primary-action"), "backup now")
        waitForCompletedBackup(timeout: 120)
        tourStep("backup completed")
    }

    /// System folder picker → 我的iPhone → CrossAppUITestHost → [folder] → 打开.
    private func tourPickHostFolder(_ folder: String) {
        // iPhone: the picker opens on Recents and needs 浏览 twice to reach the
        // sidebar. iPad: the sidebar is already showing and there is no 浏览.
        let browse = syncApp.buttons.matching(NSPredicate(format: "label IN %@", ["浏览", "Browse"])).firstMatch
        let sidebar = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'DOC.sidebar.item.'")).firstMatch
        let deadline = Date().addingTimeInterval(20)
        while !browse.exists && !sidebar.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        if browse.exists {
            browse.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            browse.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        } else if !sidebar.exists {
            failWithTree("TOUR missing: system folder picker")
        }
        tourTap(syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'DOC.sidebar.item.' AND (label CONTAINS 'iPhone' OR label CONTAINS 'iPad')")).firstMatch,
                "On My iPhone")
        tourTap(syncApp.cells.matching(NSPredicate(format: "label BEGINSWITH 'CrossAppUITestHost'")).firstMatch, "host app folder")
        tourTap(syncApp.cells.matching(NSPredicate(format: "label BEGINSWITH %@", folder + ",")).firstMatch, "local folder \(folder)")
        tourStep("B2 system picker inside \(folder)")
        tourTap(syncApp.buttons["DOCPicker.actionButton"], "open (choose folder)")
    }

    private func tourWrite(_ url: URL, _ text: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertNoThrow(try Data(text.utf8).write(to: url), "could not write \(url.lastPathComponent)")
    }

    private func tourWaitFiles(_ what: String, present: [URL], timeout: TimeInterval = 90) {
        let deadline = Date().addingTimeInterval(timeout)
        let failure = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["同步没有完成", "上次同步失败"])).firstMatch
        while Date() < deadline {
            if present.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { return }
            if failure.exists { failWithTree("TOUR: \(what) failed in the app") ; return }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        let missing = present.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.path)
        failWithTree("TOUR: \(what) did not produce \(missing)")
    }

    private func tourCompareBytes(_ a: URL, _ b: URL) {
        XCTAssertEqual(try? Data(contentsOf: a), try? Data(contentsOf: b), "\(a.lastPathComponent) differs between the two sides")
    }


    // MARK: - App Store screenshots (store_shots.sh)

    /// Builds the demo state for one language and saves raw App Store
    /// screenshots into E2E_SHOT_DIR. E2E_SHOT_LOCATIONS lists the sync
    /// locations as "localFolder>remoteFolder>two|up|down;…"; E2E_SHOT_WIZARD is
    /// "localFolder>remoteFolder" for the step-3 screenshot; E2E_SHOT_VELOCK=0
    /// skips the Velock screens (iPad has no paired Velock). The remote
    /// connection is the one whose name is E2E_SHOT_CLOUD_NAME; it is added
    /// (E2E_SHOT_CLOUD_HOST / _PORT) when missing.
    func testStoreShots() {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: env["E2E_SHOT_DIR"] ?? "/tmp/store-shots")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // E2E_SHOT_LANG is the app's language storage value (zh, en, ja, zh-Hant…).
        // Every label the test waits for arrives translated through E2E_SHOT_L_*
        // (store_shots.sh looks them up), so nothing below is language-specific.
        let lang = env["E2E_SHOT_LANG"] ?? "zh"
        let rtl = env["E2E_SHOT_RTL"] == "1"
        let velock = env["E2E_SHOT_VELOCK"] != "0"
        let cloudName = env["E2E_SHOT_CLOUD_NAME"] ?? "Nextcloud"
        func labels(_ key: String) -> [String] {
            (env["E2E_SHOT_L_" + key] ?? "").split(separator: "|").map(String.init)
        }
        func label(_ key: String) -> String { labels(key).first ?? key }
        func shot(_ name: String) {
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: out.appendingPathComponent(name + ".png"))
            attachScreenshot("shot-" + name)
        }
        // Tabs by position (0 Velock, 1 Files, 2 Settings), mirrored while the
        // app is in a right-to-left language (it may still be in the previous
        // run's language until the language step below).
        var mirrored = false
        func selectedTab() -> XCUIElement? {
            syncApp.descendants(matching: .any).matching(NSPredicate(format: "selected == true"))
                .allElementsBoundByIndex.first { $0.frame.minY > syncApp.frame.height * 0.85 }
        }
        func anyTab(_ index: Int) {
            let frame = syncApp.frame
            let pad = UIDevice.current.userInterfaceIdiom == .pad
            let column = mirrored ? 2 - index : index
            let x = frame.width * (CGFloat(column) + 0.5) / 3
            // A tap right after launch can be swallowed: retry until the tab
            // in that column reports itself selected.
            for _ in 0..<4 {
                syncApp.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: x, dy: frame.height - (pad ? 45 : 59)))
                    .tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                let selected = syncApp.descendants(matching: .any)
                    .matching(NSPredicate(format: "selected == true")).allElementsBoundByIndex
                    .contains { $0.frame.minY > frame.height * 0.85 && $0.frame.minX <= x && $0.frame.maxX >= x }
                if selected { return }
            }
            failWithTree("tab \(index) did not open")
        }
        func done(_ message: String) {
            waitLabel(labels("DONE"), message, timeout: 90)
        }

        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))

        // Language first, so every later label is in the target language.
        // The app opens on the Velock tab: on the right means right-to-left.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        if let tab = selectedTab() { mirrored = tab.frame.midX > syncApp.frame.width / 2 }
        anyTab(2)
        tourTap(element(syncApp, "sync-language-setting"), "language")
        let choice = element(syncApp, "sync-language-" + lang)
        tourScrollTo(choice)
        tourTap(choice, "pick language")
        mirrored = rtl
        tourBack()

        // Start from no sync locations.
        anyTab(1)
        let open = syncApp.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'plain-location-open-'")).firstMatch
        while open.waitForExistence(timeout: 3) {
            open.tap()
            tourScrollTo(element(syncApp, "plain-remove"))
            tourTap(element(syncApp, "plain-remove"), "remove location")
            tourTap(element(syncApp, "plain-remove-confirm"), "confirm removal")
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        }

        func startWizard(local: String, remote: String) {
            let add = element(syncApp, "plain-location-add")
            tourTap(add, "add location")
            tourTap(element(syncApp, "plain-pick-local"), "pick local folder")
            tourPickHostFolder(local)
            tourTap(element(syncApp, "plain-wizard-next-1"), "next 1")
            let connection = syncApp.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH 'plain-remote-' AND label BEGINSWITH %@", cloudName)).firstMatch
            if !connection.waitForExistence(timeout: 5) {
                // With no connection yet the wizard shows plain-add-connection instead.
                let first = element(syncApp, "plain-add-connection")
                tourTap(first.exists ? first : element(syncApp, "plain-add-another-connection"), "add connection")
                tourAddWebDAV(port: env["E2E_SHOT_CLOUD_PORT"] ?? "8080", name: cloudName,
                              host: env["E2E_SHOT_CLOUD_HOST"] ?? "cloud.local")
            }
            tourTap(connection, "cloud connection", timeout: 30)
            tourTap(tourEntry(remote), "remote folder \(remote)", timeout: 20)
            tourTap(element(syncApp, "use-backup-folder"), "use remote folder")
            tourTap(element(syncApp, "plain-wizard-next-2"), "next 2")
        }
        let directions = ["up": label("UP"), "down": label("DOWN")]
        for spec in (env["E2E_SHOT_LOCATIONS"] ?? "").split(separator: ";") {
            let parts = spec.split(separator: ">").map(String.init)
            startWizard(local: parts[0], remote: parts[1])
            if let d = directions[parts[2]] {
                tourTap(tourOption(d), "direction \(parts[2])")
            }
            // Longer languages push the button below the fold.
            tourScrollTo(element(syncApp, "plain-wizard-create"))
            tourTap(element(syncApp, "plain-wizard-create"), "create")
            done("first sync of \(parts[0])")
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }

        // 1 · Velock backup home, 2 · file sync home
        if velock {
            anyTab(0)
            waitLabel(labels("BACKUP_DONE"), "backup is not completed", timeout: 30)
            shot("1-velock-home")
        }
        anyTab(1)
        done("locations")
        shot("2-file-sync")

        // 4 · location details (first location)
        anyTab(1)
        tourTap(open, "location details")
        tourWait(element(syncApp, "plain-local-folder"), "location details")
        shot("4-location-detail")
        tourBack()

        // 5 · cloud folder browser, 6 · storage types
        anyTab(2)
        tourTap(element(syncApp, "manage-cloud-locations"), "connections")
        let row = syncApp.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", cloudName)).firstMatch
        tourWait(row, "cloud connection row")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        if let folder = env["E2E_SHOT_BROWSE"] {
            tourTap(tourEntry(folder), "browse \(folder)", timeout: 20)
        }
        // List rows show sizes and dates and keep long names on one line.
        let toggle = element(syncApp, "folder-view-toggle")
        tourWait(toggle, "view toggle")
        if labels("LIST").contains(where: { toggle.label.hasPrefix($0) }) { toggle.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot("5-browser")
        tourBackUntil(element(syncApp, "connection-new"), "connections list")
        shot("6-connections")
        tourTap(element(syncApp, "connection-new"), "new connection")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot("7-protocols")
        tourBack(); tourBack()

        // 8 · Velock backup details
        if velock {
            anyTab(0)
            tourTap(syncApp.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'velock-backup-details-'")).firstMatch, "details")
            shot("8-velock-detail")
            tourBack()
        }

        // Last, so nothing has to back out of the wizard.
        // 3 · wizard step 3
        if let wizard = env["E2E_SHOT_WIZARD"] {
            anyTab(1)
            let parts = wizard.split(separator: ">").map(String.init)
            startWizard(local: parts[0], remote: parts[1])
            tourWait(tourOption(label("TWO")), "step 3")
            shot("3-wizard")
        }
    }

    /// Developer probe: replays E2E_PROBE steps (";"-separated: id:<identifier>,
    /// label:<contains>, exact:<label>, type:<text>, wait:<seconds>, xy:<x>,<y>,
    /// relaunch) on the running Sync app without relaunching it, then writes the
    /// filtered tree and a screenshot under E2E_PROBE_OUT.
    func testProbeSyncSteps() {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: env["E2E_PROBE_OUT"] ?? "/tmp/sync-probe")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if syncApp.state == .runningForeground || syncApp.state == .runningBackground {
            syncApp.activate()
        } else {
            syncApp.launch()
        }
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
        var log = ""
        for raw in (env["E2E_PROBE"] ?? "").split(separator: ";") {
            let step = String(raw)
            let (kind, arg) = step.firstIndex(of: ":").map {
                (String(step[..<$0]), String(step[step.index(after: $0)...]))
            } ?? (step, "")
            var target: XCUIElement?
            switch kind {
            case "id": target = element(syncApp, arg)
            case "label":
                target = syncApp.descendants(matching: .any).matching(
                    NSPredicate(format: "label CONTAINS %@", arg)).firstMatch
            case "begins":
                target = syncApp.descendants(matching: .any).matching(
                    NSPredicate(format: "label BEGINSWITH %@", arg)).firstMatch
            case "back":
                target = syncApp.buttons.matching(
                    NSPredicate(format: "label BEGINSWITH '返回' OR label BEGINSWITH 'Back'")).firstMatch
            case "exact":
                target = syncApp.descendants(matching: .any).matching(
                    NSPredicate(format: "label == %@", arg)).firstMatch
            case "type": syncApp.typeText(arg)
            case "wait": RunLoop.current.run(until: Date().addingTimeInterval(Double(arg) ?? 1))
            case "relaunch": syncApp.terminate(); syncApp.launch()
            case "xy":
                let parts = arg.split(separator: ",").compactMap { Double($0) }
                syncApp.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: parts[0], dy: parts[1])).tap()
            default: log += "unknown step \(step)\n"
            }
            if let target {
                if target.waitForExistence(timeout: 10) {
                    target.tap()
                    log += "tapped \(step)\n"
                } else {
                    log += "MISSING \(step)\n"
                    break
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        }
        var tree = ""
        func walk(_ node: XCUIElementSnapshot) {
            if !node.identifier.isEmpty || !node.label.isEmpty {
                let f = node.frame
                let label = node.label.replacingOccurrences(of: "\n", with: "⏎")
                tree += "\(node.elementType.rawValue) | \(label.prefix(80)) | \(node.identifier) | \(Int(f.midX)),\(Int(f.midY))\n"
            }
            node.children.forEach(walk)
        }
        for app in [syncApp!, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            if let snap = try? app.snapshot() { walk(snap) }
            tree += "----\n"
        }
        try? (log + tree).write(to: out.appendingPathComponent("tree.txt"), atomically: true, encoding: .utf8)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: out.appendingPathComponent("screen.png"))
    }
}
