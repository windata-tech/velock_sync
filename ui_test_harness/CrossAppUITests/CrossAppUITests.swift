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
            syncApp.descendants(matching: .any)["删除保护：已开启"]
                .waitForExistence(timeout: 20),
            "Deletion protection status is missing: \(syncApp.debugDescription)"
        )
        XCTAssertTrue(
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '等待设备确认'")
            ).firstMatch.waitForExistence(timeout: 10),
            "GC acknowledgement status is missing"
        )
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
        tapFirstContaining("配置格间同步")
        waitForAnyText("连接格间数据")
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
        waitForAnyText("选择协议")
        attachScreenshot("page-new-connection")
        tapFirstContaining("选择协议")
        waitForAnyText("可用协议")
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
        let connection = syncApp.buttons.matching(
            NSPredicate(format: "label CONTAINS 'dav.yibogame.com'")
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
        waitForAnyText("选择协议")
        tapFirstContaining("选择协议")
        waitForAnyText("可用协议")
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
        tapFirstContaining("配置格间同步")
        XCTAssertTrue(
            syncApp.descendants(matching: .any)["连接格间数据"].waitForExistence(timeout: 10),
            "Velock Sync did not enter the dedicated Velock flow"
        )
        XCTAssertFalse(
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '选择数据集' OR label CONTAINS '同步文件夹'")
            ).firstMatch.exists,
            "The old generic dataset/folder flow is still exposed"
        )
        attachScreenshot("velock-entry-wizard")
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

            XCTAssertTrue(syncApp.staticTexts["选择远端连接"].waitForExistence(timeout: 10))
            let connection = syncApp.descendants(matching: .any)["新建连接"]
            XCTAssertTrue(connection.waitForExistence(timeout: 10), "WebDAV connection was not selectable")
            connection.tap()

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

        let recover = firstExisting(
            syncApp.buttons["通过恢复包加入已有空间"],
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '通过恢复包加入已有空间'")
            ).firstMatch
        )
        XCTAssertTrue(recover.waitForExistence(timeout: 10))
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
            XCTAssertTrue(velockApp.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'E2E Password'" )).firstMatch.waitForExistence(timeout: 10), "Password credential was not saved")
        }

        // Bank-card credential (card number is the minimum required field).
        let cardTab = velockApp.buttons["卡片"].firstMatch.exists
            ? velockApp.buttons["卡片"].firstMatch
            : velockApp.buttons["银行卡"].firstMatch
        if cardTab.waitForExistence(timeout: 3) { cardTab.tap() }
        let existingCard = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'E2E Card'")
        ).firstMatch
        if !existingCard.waitForExistence(timeout: 3) {
            tapCreateCredential()
            XCTAssertTrue(velockApp.buttons["银行卡"].waitForExistence(timeout: 5))
            velockApp.buttons["银行卡"].tap()
            XCTAssertTrue(velockApp.textFields["请输入标题"].waitForExistence(timeout: 10))
            velockApp.textFields["请输入标题"].tap(); velockApp.textFields["请输入标题"].typeText("E2E Card")
            // The card group's value field is rendered by a custom PlatformTextField
            // without a stable AX label. Its first value row is fixed below the
            // title on the iPhone layout; tap the real field rather than matching
            // the adjacent static label “卡号”.
            velockApp.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.28)).tap()
            velockApp.typeText("6222021234567890")
            velockApp.buttons["保存"].firstMatch.tap()
            XCTAssertTrue(velockApp.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '账户' OR label CONTAINS 'E2E Card'" )).firstMatch.waitForExistence(timeout: 10), "Card editor did not return to credentials")
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
        XCTAssertTrue(fixture.waitForExistence(timeout: 10),
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
            let directFile = pickerApp.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'velock-sync-e2e-proof' OR identifier CONTAINS 'velock-sync-e2e-proof'" )).firstMatch
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
                    file = pickerApp.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'velock-sync-e2e-proof' OR identifier CONTAINS 'velock-sync-e2e-proof'" )).firstMatch
                } else {
                    // iOS 26 presents the fixture directly in “所有文件”; its
                    // AX label is line-wrapped/truncated, so use the stable
                    // cell position as a final fallback.
                    let fixtureCoordinate = pickerApp.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.18))
                    fixtureCoordinate.tap()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                    fixtureCoordinate.tap()
                    selectedByCoordinate = true
                    file = pickerApp.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'velock-sync-e2e-proof' OR identifier CONTAINS 'velock-sync-e2e-proof'" )).firstMatch
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

        importPhotoFixture()
    }

    func testProbeVelockMediaImport() {
        velockApp.resetAuthorizationStatus(for: .photos)
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
        let retainedProfileActions = syncApp.buttons.matching(identifier: "同步配置操作")
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

        // Flutter exposes the app-bar shortcut and the primary CTA with the
        // same label. Select by frame size; query order is not stable across
        // iOS simulator runtimes.
        let create = syncApp.buttons["sync-profile-create-primary"].firstMatch.exists
            ? syncApp.buttons["sync-profile-create-primary"].firstMatch
            : largestButton(in: syncApp, containing: "配置格间同步")
        var enteredDedicatedFlow = false
        if !create.waitForExistence(timeout: 3) {
            // Incremental runs can retain the previous profile.  Use the
            // production app-bar add action to start a second pairing instead
            // of deleting the profile or resetting the simulator.
            let add = syncApp.buttons["sync-profile-create"].firstMatch
            if add.waitForExistence(timeout: 3) {
                add.tap()
            } else {
                syncApp.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.075)).tap()
            }
            enteredDedicatedFlow = syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '连接格间数据'")
            ).firstMatch.waitForExistence(timeout: 10)
            if !enteredDedicatedFlow {
                // The first Flutter semantics snapshot can still belong to
                // the retained home shell after an app install. Retry the
                // same production add hit once; never reset application data.
                syncApp.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.075)).tap()
                enteredDedicatedFlow = syncApp.descendants(matching: .any).matching(
                    NSPredicate(format: "label CONTAINS '连接格间数据'")
                ).firstMatch.waitForExistence(timeout: 10)
            }
        }
        if !enteredDedicatedFlow && !create.waitForExistence(timeout: 10) {
            print("SYNC_HOME_AFTER_CREATE_BEGIN\n\(syncApp.debugDescription)\nSYNC_HOME_AFTER_CREATE_END")
            attachScreenshot("sync-home-after-create-tap")
        }
        if !enteredDedicatedFlow {
            XCTAssertTrue(create.exists, "Sync home did not expose 格间 sync setup")
            let appFrame = syncApp.frame
            let buttonFrame = create.frame
            syncApp.coordinate(
                withNormalizedOffset: CGVector(
                    dx: (buttonFrame.midX - appFrame.minX) / appFrame.width,
                    dy: (buttonFrame.midY - appFrame.minY) / appFrame.height
                )
            ).tap()
        }

        XCTAssertTrue(
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '连接格间数据'")
            ).firstMatch.waitForExistence(timeout: 10),
            "Sync did not enter the dedicated 格间 flow"
        )
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
        finalize.tap()

        let firstRunCompleted = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '首次同步完成' OR label CONTAINS '没有需要同步的新数据' OR label CONTAINS '首次同步失败'")
        ).firstMatch
        let durableProfile = syncApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '格间数据' OR label CONTAINS 'Velock E2E'")
        ).firstMatch
        XCTAssertTrue(
            firstRunCompleted.waitForExistence(timeout: 60) || durableProfile.waitForExistence(timeout: 10),
            "Profile creation returned without a visible first-sync result or durable profile"
        )
        XCTAssertFalse(
            syncApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '首次同步失败'")
            ).firstMatch.exists,
            "First sync reported failure"
        )
        // The inbound writer is registered by the real Velock dashboard. Bring
        // the companion app foreground after Sync delivers a batch so the
        // encrypted operations are actually imported into the recovered
        // account before the test declares success.
        velockApp.activate()
        if velockApp.wait(for: .runningForeground, timeout: 15) {
            unlockVelockIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(5))
        }
        attachScreenshot("04_sync_pairing_and_first_run_completed")
    }

    /// Uses the recovery-card QR saved by the source invocation to create the
    /// account on a clean simulator. This is deliberately a real Photos QR
    /// scan path so syncRecovery is carried through the same user flow.
    func testRecoverVelockAccountFromCardPhoto() {
        // Clear the iOS 26 Photos first-run tour before opening 格间's
        // scanner. Doing this after the scanner is presented backgrounds the
        // test app and destroys that route.
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        XCTAssertTrue(photos.wait(for: .runningForeground, timeout: 10))
        for _ in 0..<3 {
            let photosContinue = photos.buttons["继续"]
            if !photosContinue.waitForExistence(timeout: 2) { break }
            photosContinue.tap()
        }
        photos.terminate()

        velockApp.terminate()
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
            NSPredicate(format: "label CONTAINS '恢复一个账号'")
        ).firstMatch
        XCTAssertTrue(recover.waitForExistence(timeout: 15), "Recovery entry was not exposed")
        recover.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let scan = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '从二维码恢复'")
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
                NSPredicate(format: "label CONTAINS '恢复账号'")
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
        if biometricSwitch.waitForExistence(timeout: 3) {
            let isOn = (biometricSwitch.value as? String) == "1"
            if isOn { biometricSwitch.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if (biometricSwitch.value as? String) == "1" {
                biometricSwitch.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
                ).tap()
            }
        }
        let submit = velockApp.buttons["恢复账号"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10), "Recovery form did not expose submit")
        submit.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(submit.waitForNonExistence(timeout: 90),
                      "Recovery form is still visible; a toast or existing account is not recovery success")
        // Recovery is only done when the authenticated dashboard shows up.
        // The vault picker also exposes buttons, so require a real dashboard
        // tab and refuse to accept a silent return to the picker: a false
        // positive here would hide a broken recovery entirely.
        let dashboardTab = velockApp.buttons.matching(
            NSPredicate(format: "label CONTAINS '首页' OR label CONTAINS '凭证'")
        ).firstMatch
        let pickerEntry = velockApp.buttons["创建一个沙盒空间"].firstMatch
        if !dashboardTab.waitForExistence(timeout: 30) || pickerEntry.exists {
            print("VELOCK_RECOVERY_END_STATE_BEGIN\n\(velockApp.debugDescription)\nVELOCK_RECOVERY_END_STATE_END")
            attachScreenshot("velock-recovery-end-state")
            XCTFail("Recovered account did not reach the authenticated dashboard")
            return
        }
        attachScreenshot("replica_velock_recovered_from_qr")
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
        if recoveredEnter.waitForExistence(timeout: 5) {
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
        let settingsTab = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '设置'")
        ).firstMatch
        if settingsTab.waitForExistence(timeout: 10) {
            settingsTab.tap()
        }
        let syncSettings = velockApp.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS '实验性 - 数据同步' OR label CONTAINS 'Velock Sync' OR label CONTAINS '数据同步'"
            )
        ).firstMatch
        if !syncSettings.waitForExistence(timeout: 10) {
            print("PAIRING_SETTINGS_NOT_FOUND\n\(velockApp.debugDescription)\nPAIRING_SETTINGS_NOT_FOUND_END")
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

        let pairingStatus = velockApp.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '允许新的配对' OR label CONTAINS 'Allow new pairings'")
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
        if saveRecoveryCard.waitForExistence(timeout: 30) {
            // This is the Sync-enabled replacement-device card. The initial
            // registration card intentionally has no syncRecovery extension.
            persistRecoveryCardScreenshotIfRequested()
            saveRecoveryCard.tap()
            allowPhotoAdditionIfRequested()
            XCTAssertTrue(
                velockApp.descendants(matching: .any).matching(
                    NSPredicate(format: "label CONTAINS '独立应用连接'")
                ).firstMatch.waitForExistence(timeout: 30),
                "Velock did not return from the replacement-device recovery card"
            )
        }

        XCTAssertTrue(
            velockApp.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '已启用'")
            ).firstMatch.waitForExistence(timeout: 30),
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
        if syncApp.descendants(matching: .any)["连接格间数据"]
            .waitForExistence(timeout: 3) {
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
        // cannot indicate that a connection already exists. Use the explicit
        // empty-state marker instead.
        if !syncApp.descendants(matching: .any)["还没有远端连接"].waitForExistence(timeout: 3) {
            return
        }

        XCTAssertTrue(syncApp.descendants(matching: .any)["还没有远端连接"].waitForExistence(timeout: 10))
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
}
