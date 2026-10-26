import XCTest

final class VaoPushUITests: XCTestCase {
    @MainActor private func tap(_ app: XCUIApplication, _ labels: [String], timeout: TimeInterval = 8) {
        for label in labels {
            let button = app.buttons[label].firstMatch
            if button.waitForExistence(timeout: timeout / Double(labels.count)) { button.tap(); return }
        }
        XCTFail("Missing button: \(labels.joined(separator: ", "))")
    }

    @MainActor func testUnreachableServerOffersLocalRemoval() throws {
        guard let name = ProcessInfo.processInfo.environment["VAO_UI_REMOVE_OLD_SERVER_NAME"] else {
            throw XCTSkip("Explicit disposable or retired connection name required")
        }
        let app = XCUIApplication()
        app.launch()
        tap(app, ["设置", "Settings"])
        let server = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        server.tap()
        let remove = app.buttons["remove-server"]
        for _ in 0..<6 {
            if remove.isHittable { break }
            app.swipeUp()
        }
        remove.tap()
        app.buttons["confirm-remove-server"].firstMatch.tap()
        let force = app.buttons["force-remove-local-server"].firstMatch
        XCTAssertTrue(force.waitForExistence(timeout: 35))
        let warning = XCTAttachment(screenshot: app.screenshot())
        warning.name = "Remote Removal Failed Offers Explicit Local Choice"
        warning.lifetime = .keepAlways; add(warning)
        force.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10) || app.navigationBars["Settings"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch.exists)
        let removed = XCTAttachment(screenshot: app.screenshot())
        removed.name = "Retired Connection Removed Locally"
        removed.lifetime = .keepAlways; add(removed)
    }

    @MainActor func testAboutPageAndExternalLinks() throws {
        let app = XCUIApplication()
        app.launch()
        tap(app, ["设置", "Settings"])
        let about = app.buttons["settings-about"].firstMatch
        for _ in 0..<6 {
            if about.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(about.waitForExistence(timeout: 8))
        about.tap()
        XCTAssertTrue(app.staticTexts["push.vaovao.app"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["github.com/loewe1631/Vao-Push"].exists)
        let website = app.links["about-website-link"].firstMatch
        let github = app.links["about-github-link"].firstMatch
        XCTAssertTrue(website.isHittable)
        XCTAssertTrue(github.isHittable)
        let page = XCTAttachment(screenshot: app.screenshot())
        page.name = "About With Website And GitHub Icons"
        page.lifetime = .keepAlways; add(page)
        website.tap()
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 12))
        let websiteOpened = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        websiteOpened.name = "Website Link Opened"
        websiteOpened.lifetime = .keepAlways; add(websiteOpened)
        app.activate()
        XCTAssertTrue(github.waitForExistence(timeout: 8))
        github.tap()
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 12))
        let githubOpened = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        githubOpened.name = "GitHub Link Opened"
        githubOpened.lifetime = .keepAlways; add(githubOpened)
        app.activate()
    }

    @MainActor func testInterfaceLanguageSwitch() throws {
        let app = XCUIApplication()
        app.launch()
        tap(app, ["设置", "Settings"])
        let picker = app.buttons["interface-language"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        tap(app, ["English"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Add Server"].exists)
        let english = XCTAttachment(screenshot: app.screenshot())
        english.name = "English Settings"; english.lifetime = .keepAlways; add(english)
        app.buttons["interface-language"].tap()
        tap(app, ["中文"])
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["添加服务器"].exists)
        let chinese = XCTAttachment(screenshot: app.screenshot())
        chinese.name = "Chinese Settings"; chinese.lifetime = .keepAlways; add(chinese)
        // Preserve the previous default of following the device language.
        app.buttons["interface-language"].tap()
        tap(app, ["跟随系统", "System"])
    }

    @MainActor func testHTTPServerConnection() throws {
        guard let address = ProcessInfo.processInfo.environment["VAO_UI_HTTP_URL"] else { throw XCTSkip("An isolated HTTP server is required") }
        let app = XCUIApplication()
        app.launch()
        tap(app, ["设置", "Settings"])
        app.buttons["add-server"].tap()
        let name = app.textFields["server-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap(); name.typeText("HTTP Acceptance")
        let endpoint = app.textFields["server-address"]
        endpoint.tap(); endpoint.typeText(address)
        let device = app.textFields["registration-device-name"]
        device.tap(); device.typeText("iPad HTTP Acceptance")
        app.buttons["save-server"].tap()
        XCTAssertTrue(app.buttons["HTTP Acceptance"].waitForExistence(timeout: 25))
        app.buttons["HTTP Acceptance"].tap()
        XCTAssertTrue(app.buttons["copy-message-url"].waitForExistence(timeout: 15))
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "HTTP Bound Device"; evidence.lifetime = .keepAlways; add(evidence)
    }

    @MainActor func testNotificationTapOpensDetails() throws {
        guard let title = ProcessInfo.processInfo.environment["VAO_UI_NOTIFICATION_TITLE"],
              let body = ProcessInfo.processInfo.environment["VAO_UI_NOTIFICATION_BODY"] else { throw XCTSkip("An authorized iPad notification is required") }
        let app = XCUIApplication()
        app.launch()
        tap(app, ["卡片", "Cards"])
        if ProcessInfo.processInfo.environment["VAO_UI_NOTIFICATION_WARM"] == "1" {
            XCUIDevice.shared.press(.home)
        } else {
            app.terminate()
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()
        print("VAO_NOTIFICATION_TEST_READY")
        let notification = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        if !notification.waitForExistence(timeout: 12) {
            // The user may disable banners while keeping notifications in Notification Center.
            let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.01))
            let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.85))
            top.press(forDuration: 0.1, thenDragTo: bottom)
            let focusGroup = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND (label CONTAINS %@ OR label CONTAINS %@)", "Vao Push", "专注", "Focus")).firstMatch
            if focusGroup.waitForExistence(timeout: 3) { focusGroup.tap() }
        }
        if !notification.waitForExistence(timeout: 20) {
            print("SPRINGBOARD_HIERARCHY " + springboard.debugDescription)
            XCTFail("The iPad notification did not appear"); return
        }
        notification.tap()
        if !app.wait(for: .runningForeground, timeout: 3), notification.exists {
            // A grouped notification first expands its stack.
            notification.tap()
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        let details = app.navigationBars["消息详情"].exists ? app.navigationBars["消息详情"] : app.navigationBars["Message Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts[title].exists)
        XCTAssertTrue(app.staticTexts[body].exists)
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Notification Opens Exact Message"; evidence.lifetime = .keepAlways; add(evidence)
        details.buttons.firstMatch.tap()
        let messages = app.navigationBars.matching(NSPredicate(format: "identifier == %@ OR identifier == %@", "消息", "Messages")).firstMatch
        XCTAssertTrue(messages.waitForExistence(timeout: 8))
    }
}
