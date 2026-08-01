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

    private var syncApp: XCUIApplication!
    private var velockApp: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        syncApp = XCUIApplication(bundleIdentifier: syncBundleID)
        velockApp = XCUIApplication(bundleIdentifier: velockBundleID)
    }

    override func tearDown() {
        syncApp?.terminate()
        velockApp?.terminate()
        syncApp = nil
        velockApp = nil
    }

    /// Diagnostic only. This is intentionally excluded from the final E2E run.
    /// It records the accessibility hierarchy used to build stable black-box
    /// selectors for the Selected Folder flow.
    func testProbeSelectedFolderNavigation() {
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
        print("E2E_PROBE_HOME_BEGIN\n\(syncApp.debugDescription)\nE2E_PROBE_HOME_END")

        let connectionsTab = syncApp.staticTexts["Connections"]
        XCTAssertTrue(connectionsTab.waitForExistence(timeout: 10))
        XCTAssertTrue(connectionsTab.isHittable)
        connectionsTab.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print("E2E_PROBE_CONNECTIONS_BEGIN\n\(syncApp.debugDescription)\nE2E_PROBE_CONNECTIONS_END")
        XCTAssertTrue(
            syncApp.descendants(matching: .any)["没有连接的服务"]
                .waitForExistence(timeout: 5),
            "Connections page did not render its empty state"
        )

        let addConnection = syncApp.buttons.element(boundBy: 0)
        XCTAssertTrue(addConnection.exists && addConnection.isHittable)
        addConnection.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print("E2E_PROBE_NEW_CONNECTION_BEGIN\n\(syncApp.debugDescription)\nE2E_PROBE_NEW_CONNECTION_END")

        let protocolChoice = syncApp.buttons["选择协议"]
        XCTAssertTrue(protocolChoice.waitForExistence(timeout: 5))
        protocolChoice.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print("E2E_PROBE_PROTOCOLS_BEGIN\n\(syncApp.debugDescription)\nE2E_PROBE_PROTOCOLS_END")

        let webDAV = syncApp.buttons.matching(
            NSPredicate(format: "label CONTAINS 'WebDAV 协议'")
        ).firstMatch
        XCTAssertTrue(webDAV.waitForExistence(timeout: 5))
        webDAV.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print("E2E_PROBE_WEBDAV_BEGIN\n\(syncApp.debugDescription)\nE2E_PROBE_WEBDAV_END")
    }

    /// Upload-side setup through the real UI. This intentionally stops after
    /// persisting the WebDAV connection so later probes can inspect the next
    /// product surface without coupling connection diagnosis to folder-picker
    /// diagnosis.
    func testCreateWebDAVConnection() {
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))

        let connectionsTab = syncApp.staticTexts["Connections"]
        XCTAssertTrue(connectionsTab.waitForExistence(timeout: 10))
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

        let protocolChoice = syncApp.buttons["选择协议"]
        XCTAssertTrue(protocolChoice.waitForExistence(timeout: 5))
        protocolChoice.tap()

        let webDAV = syncApp.buttons.matching(
            NSPredicate(format: "label CONTAINS 'WebDAV 协议'")
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

    /// Diagnostic only. Opens the real iOS directory picker after choosing the
    /// persisted WebDAV connection, then records both app hierarchies so the
    /// production E2E can use stable labels instead of coordinates.
    func testProbeSelectedFolderPicker() {
        prepareFixtureHost()
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
        let syncTab = syncApp.descendants(matching: .any)["Sync"].firstMatch
        if syncTab.waitForExistence(timeout: 5) {
            syncTab.tap()
        }

        let existingProfile = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH '同步文件夹'")
        ).firstMatch
        if existingProfile.waitForExistence(timeout: 3) {
            attachScreenshot("selected_folder_profile_reused")
            return
        }

        let create = syncApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '新建同步配置'")
        ).firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10), "Home did not expose the create action")
        create.tap()

        let selectedFolder = syncApp.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Selected Folder'")
        ).firstMatch
        XCTAssertTrue(
            selectedFolder.waitForExistence(timeout: 10),
            "Wizard did not expose the Selected Folder dataset"
        )
        selectedFolder.tap()

        XCTAssertTrue(
            syncApp.descendants(matching: .any)["同步文件夹"]
                .waitForExistence(timeout: 10)
        )
        let addFolder = syncApp.buttons["添加同步文件夹"]
        XCTAssertTrue(addFolder.waitForExistence(timeout: 10), "Selected Folder page did not expose add")
        addFolder.tap()

        XCTAssertTrue(syncApp.staticTexts["选择远端连接"].waitForExistence(timeout: 10))
        let connection = syncApp.descendants(matching: .any)["新建连接"]
        XCTAssertTrue(connection.waitForExistence(timeout: 10), "Persisted WebDAV connection was not selectable")
        connection.tap()

        let documents = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        let pickerMarker = syncApp.descendants(matching: .any).matching(
            NSPredicate(
                format: "label IN %@",
                ["浏览", "Browse", "最近项目", "Recents", "在我的 iPhone 上", "On My iPhone"]
            )
        ).firstMatch
        XCTAssertTrue(
            pickerMarker.waitForExistence(timeout: 10),
            "The directory picker did not expose system file-browser content"
        )
        XCTAssertFalse(
            syncApp.staticTexts["创建同步文件夹失败。"].exists,
            "Selected Folder creation reported an error instead of presenting the picker"
        )
        let localStorage = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "identifier CONTAINS 'com.apple.FileProvider.LocalStorage'")
        ).firstMatch
        if !localStorage.exists {
            let browse = syncApp.tabBars["DOC.browsingModeTabBar"].buttons["浏览"]
            XCTAssertTrue(browse.waitForExistence(timeout: 5), "The picker did not expose its Browse tab")
            browse.tap()
        }
        let fixtureHost = syncApp.cells.matching(
            NSPredicate(format: "identifier BEGINSWITH 'CrossAppUITestHost'")
        ).firstMatch
        XCTAssertTrue(fixtureHost.waitForExistence(timeout: 10), "The Files browser did not expose the fixture host")
        fixtureHost.tap()

        let source = syncApp.cells.matching(
            NSPredicate(format: "identifier BEGINSWITH 'VelockSync-E2E-Source'")
        ).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), "The fixture host did not expose the Source folder")
        source.tap()

        let open = syncApp.buttons["打开"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "The directory picker did not expose its Open action")
        open.tap()

        XCTAssertTrue(
            syncApp.staticTexts["已创建“同步文件夹”。"]
                .waitForExistence(timeout: 20),
            "Selecting Source did not create the Selected Folder profile"
        )
        XCTAssertFalse(
            syncApp.staticTexts["创建同步文件夹失败。"].exists,
            "Selected Folder creation failed after choosing Source"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print("E2E_PROBE_PROFILE_BEGIN\n\(syncApp.debugDescription)\nE2E_PROBE_PROFILE_END")
        print("E2E_PROBE_PICKER_DOCUMENTS_BEGIN\n\(documents.debugDescription)\nE2E_PROBE_PICKER_DOCUMENTS_END")
        attachScreenshot("selected_folder_profile_created")
    }

    /// Diagnostic only. Opens the persisted Selected Folder profile from the
    /// Sync home screen and records its black-box controls.
    func testProbeExistingSelectedFolderProfile() {
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))

        let profile = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH '同步文件夹'")
        ).firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 10), "Sync home did not expose the persisted profile")
        profile.tap()

        let syncNow = syncApp.buttons["立即同步"]
        XCTAssertTrue(syncNow.waitForExistence(timeout: 10), "Profile detail did not expose immediate sync")
        syncNow.tap()

        let confirm = syncApp.buttons["确认并同步"]
        if confirm.waitForExistence(timeout: 1) {
            print("E2E_PROBE_FIRST_SYNC_CONFIRMATION_BEGIN\n\(syncApp.debugDescription)\nE2E_PROBE_FIRST_SYNC_CONFIRMATION_END")
            confirm.tap()
        }
        attachScreenshot("selected_folder_first_sync_started")

        let completed = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH '同步完成：上传 '")
        ).firstMatch
        let syncFailure = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label == '同步失败；请检查连接、授权与网络。'")
        ).firstMatch
        let syncResult = waitForOutcome(
            success: completed,
            failure: syncFailure,
            timeout: 60
        )
        if syncResult == .timedOut {
            // The successful sync can finish in well under one second, so the
            // transient Material banner may appear and disappear between two
            // XCTest accessibility snapshots.  The persisted profile summary
            // is the durable, user-visible confirmation for that case.
            let back = syncApp.buttons["Back"]
            if back.exists && back.isHittable {
                back.tap()
            }
            let persistedProfile = syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH '同步文件夹'")
            ).firstMatch
            if persistedProfile.waitForExistence(timeout: 5) {
                persistedProfile.tap()
            }
            let recentSuccess = durableCompletedStatus(in: syncApp)
            if recentSuccess.waitForExistence(timeout: 10) {
                print("E2E_FIRST_SYNC_DURABLE_STATUS=\(recentSuccess.label)")
                attachScreenshot("selected_folder_first_sync_completed")
                return
            }
        }

        guard syncResult == .success else {
            print("E2E_PROBE_FIRST_SYNC_FAILURE_BEGIN\n\(syncApp.debugDescription)\nE2E_PROBE_FIRST_SYNC_FAILURE_END")
            attachScreenshot("selected_folder_first_sync_failure")
            XCTFail("First Selected Folder sync did not complete successfully: \(syncResult)")
            return
        }

        let completionLabel = completed.label
        print("E2E_FIRST_SYNC_RESULT=\(completionLabel)")
        let pattern = #"同步完成：上传 ([0-9]+) 批，下载 ([0-9]+) 批。"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(completionLabel.startIndex..., in: completionLabel)
        let match = regex.firstMatch(in: completionLabel, range: range)
        XCTAssertNotNil(match, "Completion message did not expose batch counts: \(completionLabel)")
        if let match {
            let uploadRange = Range(match.range(at: 1), in: completionLabel)!
            let downloadRange = Range(match.range(at: 2), in: completionLabel)!
            let uploads = Int(completionLabel[uploadRange])!
            let downloads = Int(completionLabel[downloadRange])!
            XCTAssertGreaterThanOrEqual(uploads, 1, "First sync must upload at least one batch")
            XCTAssertEqual(downloads, 0, "Empty remote must not download on first sync")
        }
        attachScreenshot("selected_folder_first_sync_completed")
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

    /// Exports the persisted upload-side profile's recovery package without
    /// placing either the passphrase or package in XCTest output/attachments.
    /// The package is written to a caller-provided, mode-0600 temporary file so
    /// a second simulator invocation can consume it.
    func testExportRecoveryPackageSecurely() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let passphrase = environment["E2E_RECOVERY_PASSPHRASE"], !passphrase.isEmpty,
              let outputPath = environment["E2E_RECOVERY_PACKAGE_FILE"], !outputPath.isEmpty else {
            XCTFail("Secure recovery runtime inputs are missing")
            return
        }

        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))

        let profile = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH '同步文件夹'")
        ).firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 10), "Upload-side profile is unavailable")

        let actions = syncApp.buttons["同步配置操作"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()

        let exportRecovery = syncApp.descendants(matching: .any)["生成恢复包"]
        XCTAssertTrue(exportRecovery.waitForExistence(timeout: 5))
        exportRecovery.tap()

        // Flutter currently exposes these obscured Material fields as regular
        // XCUI text fields on this simulator runtime. Prefer their visible
        // labels and retain secure-field queries for native/engine variants.
        let recoveryFields = [
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label == '恢复口令'")
            ).firstMatch,
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label == '再次输入恢复口令'")
            ).firstMatch,
        ]
        for field in recoveryFields {
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(passphrase)
        }

        let generate = syncApp.buttons["生成"]
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        generate.tap()
        XCTAssertTrue(
            syncApp.staticTexts["一次性恢复包"].waitForExistence(timeout: 20),
            "Recovery package was not generated"
        )

        let packageElement = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'VLSR1.' OR value BEGINSWITH 'VLSR1.'")
        ).firstMatch
        XCTAssertTrue(packageElement.waitForExistence(timeout: 10), "Recovery package content is unavailable")
        let package = [packageElement.value as? String, packageElement.label]
            .compactMap { $0 }
            .first(where: { $0.hasPrefix("VLSR1.") })
        guard let package, package.hasPrefix("VLSR1.") else {
            XCTFail("Recovery package content has an invalid format")
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
            XCTFail("Could not persist the secure recovery handoff")
            return
        }

        let close = syncApp.buttons["我已安全保存"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        print("E2E_RECOVERY_EXPORT=completed")
    }

    /// Fresh-replica flow: create a local WebDAV connection, recover the
    /// existing vault into the Replica fixture folder, and perform the first
    /// download. Sensitive values are read from runtime/file inputs only.
    func testRecoverReplicaAndDownload() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let passphrase = environment["E2E_RECOVERY_PASSPHRASE"], !passphrase.isEmpty,
              let packagePath = environment["E2E_RECOVERY_PACKAGE_FILE"], !packagePath.isEmpty,
              let vaultID = environment["E2E_VAULT_ID"], !vaultID.isEmpty else {
            XCTFail("Replica recovery runtime inputs are missing")
            return
        }
        let package = try String(contentsOfFile: packagePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard package.hasPrefix("VLSR1.") else {
            XCTFail("Secure recovery handoff has an invalid format")
            return
        }

        prepareFixtureHost()
        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
        createLocalWebDAVConnectionIfNeeded()

        let homeTab = waitForAny(
            syncApp.staticTexts["Sync"],
            syncApp.buttons["Sync"],
            syncApp.staticTexts["Home"],
            syncApp.staticTexts["首页"],
            timeout: 5
        )
        if homeTab.exists && homeTab.isHittable {
            homeTab.tap()
        }

        let recoveredProfileCard = syncApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '已恢复的同步文件夹'")
        ).firstMatch
        if !recoveredProfileCard.waitForExistence(timeout: 2) {
            let create = waitForAny(
                syncApp.buttons.matching(
                    NSPredicate(format: "label CONTAINS '新建同步配置'")
                ).firstMatch,
                syncApp.buttons["新建"],
                timeout: 10
            )
            XCTAssertTrue(create.exists, "Replica home did not expose profile creation")
            create.tap()

            let selectedFolder = syncApp.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Selected Folder'")
            ).firstMatch
            XCTAssertTrue(selectedFolder.waitForExistence(timeout: 10))
            selectedFolder.tap()

            let recover = syncApp.buttons["通过恢复包加入已有空间"]
            XCTAssertTrue(recover.waitForExistence(timeout: 10), "Selected Folder did not expose recovery")
            recover.tap()

            XCTAssertTrue(syncApp.staticTexts["选择远端连接"].waitForExistence(timeout: 10))
            let connection = syncApp.descendants(matching: .any)["新建连接"]
            XCTAssertTrue(connection.waitForExistence(timeout: 10))
            connection.tap()

            let vaultField = syncApp.textFields["Vault ID"]
            XCTAssertTrue(vaultField.waitForExistence(timeout: 5))
            vaultField.tap()
            vaultField.typeText(vaultID)

            let packageField = firstExisting(
                syncApp.textViews["恢复包（VLSR1.）"],
                syncApp.textFields["恢复包（VLSR1.）"]
            )
            XCTAssertTrue(packageField.waitForExistence(timeout: 5))
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

            // Recovery completion can leave the wizard route in a transient
            // state long after the profile has been persisted. A clean relaunch
            // is deterministic and verifies that recovery survived process
            // death before the first download starts.
            syncApp.terminate()
            syncApp.launch()
            XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 30))
        }

        let profile = waitForAny(
            syncApp.buttons.matching(
                NSPredicate(format: "label CONTAINS '已恢复的同步文件夹'")
            ).firstMatch,
            syncApp.staticTexts["已恢复的同步文件夹"],
            timeout: 10
        )
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        profile.tap()

        let syncNow = syncApp.buttons["立即同步"]
        XCTAssertTrue(syncNow.waitForExistence(timeout: 10))
        syncNow.tap()

        let completed = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH '同步完成：上传 '")
        ).firstMatch
        let failure = syncApp.descendants(matching: .any)["同步失败；请检查连接、授权与网络。"]
        let confirmation = syncApp.staticTexts["确认加入已有同步空间"]
        if confirmation.waitForExistence(timeout: 3) {
            let confirm = syncApp.buttons["确认并同步"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()
        }
        let result = waitForOutcome(success: completed, failure: failure, timeout: 60)
        if result == .timedOut {
            let recentSuccess = durableCompletedStatus(in: syncApp)
            if recentSuccess.waitForExistence(timeout: 15) {
                print("E2E_REPLICA_DURABLE_STATUS=completed")
            }
            // The transient completion banner and Flutter semantics can both
            // disappear between XCTest snapshots. The restored file hash is
            // the authoritative durable outcome for a fresh replica.
            attachScreenshot("replica_download_completed")
            verifyReplicaFixtureIntegrity()
            return
        }
        guard result == .success else {
            XCTFail("Replica first sync did not complete successfully")
            return
        }

        let completionLabel = completed.label
        let pattern = #"同步完成：上传 ([0-9]+) 批，下载 ([0-9]+) 批。"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(completionLabel.startIndex..., in: completionLabel)
        guard let match = regex.firstMatch(in: completionLabel, range: range),
              let uploadRange = Range(match.range(at: 1), in: completionLabel),
              let downloadRange = Range(match.range(at: 2), in: completionLabel),
              let uploads = Int(completionLabel[uploadRange]),
              let downloads = Int(completionLabel[downloadRange]) else {
            XCTFail("Replica completion did not expose batch counts")
            return
        }
        XCTAssertEqual(uploads, 0, "Replica recovery must not publish a new batch")
        XCTAssertGreaterThanOrEqual(downloads, 1, "Replica recovery must download at least one batch")
        print("E2E_REPLICA_UPLOAD_BATCHES=\(uploads)")
        print("E2E_REPLICA_DOWNLOAD_BATCHES=\(downloads)")
        attachScreenshot("replica_download_completed")
        verifyReplicaFixtureIntegrity()
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

    /// End-to-end flow: initialize Velock → publish pairing identity →
    /// Sync creates a real one-time request → Velock approves it → Sync
    /// verifies, persists and consumes the signed response.
    ///
    /// The password is supplied at runtime with VELOCK_RUNTIME_PASSWORD and
    /// is never written to source, fixtures, attachments, or test output.
    func testCrossAppPairingFlow() {
        ensureVelockInitializedAndPairingEnabled()

        syncApp.launch()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 20))
        createLocalWebDAVConnectionIfNeeded()

        let syncTab = syncApp.descendants(matching: .any)["Sync"].firstMatch
        if syncTab.waitForExistence(timeout: 5) {
            syncTab.tap()
        }
        attachScreenshot("01_sync_home")

        let existingProfile = syncApp.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS 'Velock' AND label CONTAINS 'Profile'"
            )
        ).firstMatch
        XCTAssertFalse(
            existingProfile.exists,
            "Pairing E2E requires a clean Sync app without an existing Velock profile"
        )

        let create = waitForAny(
            syncApp.buttons["sync-profile-create"],
            syncApp.buttons["新建同步配置"],
            syncApp.buttons["新建"]
        )
        if create.exists {
            create.tap()
        } else {
            // Flutter semantics can be absent from an iOS snapshot while the visible
            // control is still rendered; this is the fixed simulator fallback.
            syncApp.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.86)).tap()
        }

        // Flutter's semantics snapshot may omit the ListTile text even though the
        // wizard is rendered. Capture the rendered page and use the stable second
        // card position as a fallback (the first card is Selected Folder).
        attachScreenshot("02_sync_wizard")
        let dataset = firstExisting(
            syncApp.buttons.matching(
                NSPredicate(format: "label CONTAINS 'Velock managed data'")
            ).firstMatch,
            syncApp.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'Velock managed data'")
            ).firstMatch,
            syncApp.buttons["Velock managed data"]
        )
        if dataset.waitForExistence(timeout: 3) {
            dataset.tap()
        } else {
            // iPhone 17 Pro Max wizard layout: the Velock card is the second
            // card below the explanatory text. Keep this as a UI-only fallback;
            // no production accessibility or business code is changed.
            // The second card occupies approximately y=306...394 in the
            // 956-point simulator window; tap its center rather than the
            // gap below it.
            syncApp.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.365)).tap()
        }
        attachScreenshot("02_sync_velock_dataset")

        XCTAssertFalse(
            syncApp.staticTexts["Velock 版本不受支持"].waitForExistence(timeout: 2),
            "Installed Velock build does not expose Exchange V1"
        )

        let beginPairing = firstExisting(
            syncApp.buttons["begin-velock-pairing"],
            syncApp.buttons["开始配对"],
            syncApp.staticTexts["开始配对"]
        )
        XCTAssertTrue(beginPairing.waitForExistence(timeout: 10), "Ready flow should expose 开始配对")
        beginPairing.tap()

        // submitPairingRequest writes the real UUID request and launches this
        // app with that exact requestId. Never synthesize a test deep link.
        XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 20))
        unlockVelockIfNeeded()
        let approveRequest = velockApp.buttons["批准"]
        XCTAssertTrue(
            approveRequest.waitForExistence(timeout: 15),
            "Velock did not expose the one-time request created by Sync"
        )
        approveRequest.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
        XCTAssertTrue(
            velockApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '批准这台 Velock Sync'" )
            ).firstMatch.waitForExistence(timeout: 5)
        )
        // Flutter's Cupertino dialog is not exposed as an XCUI `.alert`. While
        // it is presented, the underlying row action is removed from the
        // accessibility tree, leaving the modal confirmation as the sole
        // matching button.
        let approvalButtons = velockApp.buttons.matching(
            NSPredicate(format: "label == '批准'")
        )
        XCTAssertEqual(approvalButtons.count, 1)
        let confirmApproval = approvalButtons.firstMatch
        confirmApproval.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
        XCTAssertFalse(
            velockApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '批准这台 Velock Sync'")
            ).firstMatch.waitForExistence(timeout: 5),
            "Velock approval confirmation did not dismiss"
        )
        XCTAssertTrue(
            velockApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '暂无待审批请求'")
            ).firstMatch.waitForExistence(timeout: 30),
            "Velock did not persist the signed approval"
        )
        attachScreenshot("04_velock_pairing_approved")

        syncApp.activate()
        XCTAssertTrue(syncApp.wait(for: .runningForeground, timeout: 15))
        let checkApproval = syncApp.buttons["检查批准结果"]
        XCTAssertTrue(checkApproval.waitForExistence(timeout: 10))
        checkApproval.tap()

        XCTAssertTrue(
            syncApp.staticTexts["步骤 4 / 7 · 选择远端连接"]
                .waitForExistence(timeout: 10)
        )
        let connection = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "http://127.0.0.1:\(webDAVPort)")
        ).firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 10))
        connection.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()

        let confirmTarget = syncApp.buttons["确认目标"]
        XCTAssertTrue(confirmTarget.waitForExistence(timeout: 10))
        confirmTarget.tap()
        let confirmBackground = syncApp.buttons["继续"]
        XCTAssertTrue(confirmBackground.waitForExistence(timeout: 10))
        confirmBackground.tap()
        let finalize = syncApp.buttons["确认并创建"]
        XCTAssertTrue(finalize.waitForExistence(timeout: 10))
        finalize.tap()

        XCTAssertTrue(
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS 'Profile 已保存，配对响应已安全消费。'")
            ).firstMatch.waitForExistence(timeout: 20),
            "Sync did not persist the profile and consume the signed response"
        )
        attachScreenshot("05_sync_pairing_completed")
    }

    private func ensureVelockInitializedAndPairingEnabled() {
        let password = ProcessInfo.processInfo.environment["VELOCK_RUNTIME_PASSWORD"] ?? ""
        XCTAssertFalse(password.isEmpty, "Set VELOCK_RUNTIME_PASSWORD at runtime")

        velockApp.launch()
        XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 20))
        let createSandbox = velockApp.buttons["创建一个沙盒空间"]
        if createSandbox.waitForExistence(timeout: 3) {
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
            saveAndEnter.tap()
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
            let home = velockApp.descendants(matching: .any)["首页"]
            if !home.waitForExistence(timeout: 8) {
                // A process transition around the Photos permission can finish
                // registration but return to the account gate. Treat that as
                // a durable registration and authenticate with the same
                // runtime-only password before continuing.
                if !velockApp.wait(for: .runningForeground, timeout: 2) {
                    velockApp.activate()
                    XCTAssertTrue(velockApp.wait(for: .runningForeground, timeout: 10))
                }
                unlockVelockIfNeeded()
            }
            XCTAssertTrue(
                home.waitForExistence(timeout: 30),
                "Velock registration did not complete after saving the recovery card"
            )
        }

        unlockVelockIfNeeded()
        let settingsTab = velockApp.staticTexts["设置"]
        if settingsTab.waitForExistence(timeout: 10) {
            settingsTab.tap()
        }
        let syncSettings = velockApp.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS 'Velock Sync' AND label CONTAINS '独立应用配对与审批'"
            )
        ).firstMatch
        XCTAssertTrue(syncSettings.waitForExistence(timeout: 10))
        syncSettings.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()

        let pairingStatus = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '允许新的配对'")
        ).firstMatch
        XCTAssertTrue(pairingStatus.waitForExistence(timeout: 10))
        if pairingStatus.label.contains("未启用") {
            pairingStatus.coordinate(
                withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)
            ).tap()
            let enable = velockApp.buttons["启用"]
            XCTAssertTrue(enable.waitForExistence(timeout: 5))
            enable.tap()
        }
        XCTAssertTrue(
            velockApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '已启用'")
            ).firstMatch.waitForExistence(timeout: 15),
            "Velock did not publish its pairing descriptor"
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

    private func unlockVelockIfNeeded() {
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

        let field = labeledPassword.exists
            ? labeledPassword
            : (velockApp.secureTextFields.firstMatch.exists
                ? velockApp.secureTextFields.firstMatch
                : velockApp.textFields.firstMatch)
        field.tap()
        if labeledPassword.exists {
            // Flutter can expose the focused password input as a generic
            // semantics element. Sending keys through the application mirrors
            // real keyboard input even when XCUIElement.typeText cannot resolve
            // that modern text-input automation type.
            velockApp.typeText(password)
        } else {
            field.typeText(password)
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
        let connectionsTab = syncApp.staticTexts["Connections"]
        XCTAssertTrue(connectionsTab.waitForExistence(timeout: 10))
        connectionsTab.tap()
        if syncApp.descendants(matching: .any)["新建连接"].waitForExistence(timeout: 3) {
            return
        }

        XCTAssertTrue(syncApp.descendants(matching: .any)["没有连接的服务"].waitForExistence(timeout: 10))
        let addConnection = syncApp.buttons.element(boundBy: 0)
        XCTAssertTrue(addConnection.waitForExistence(timeout: 5))
        addConnection.tap()

        let protocolChoice = syncApp.buttons["选择协议"]
        XCTAssertTrue(protocolChoice.waitForExistence(timeout: 5))
        protocolChoice.tap()
        let webDAV = syncApp.buttons.matching(
            NSPredicate(format: "label CONTAINS 'WebDAV 协议'")
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
        XCTAssertGreaterThanOrEqual(fields.count, 2)
        let address = fields.element(boundBy: 0)
        address.tap()
        address.typeText("127.0.0.1")
        let port = fields.element(boundBy: 1)
        port.tap()
        port.typeText(webDAVPort)
        let save = syncApp.buttons["保存"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(syncApp.descendants(matching: .any)["新建连接"].waitForExistence(timeout: 20))
    }

    private func selectFixtureFolder(named folderName: String) {
        let pickerMarker = syncApp.descendants(matching: .any).matching(
            NSPredicate(
                format: "label IN %@",
                ["浏览", "Browse", "最近项目", "Recents", "在我的 iPhone 上", "On My iPhone"]
            )
        ).firstMatch
        XCTAssertTrue(pickerMarker.waitForExistence(timeout: 15), "System directory picker did not appear")

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
}
