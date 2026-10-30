import XCTest

/// Drives the real app against the dev server as Aunty Grace (seeded Elder). Read-only on the
/// server: it signs in, browses, opens the Elder queue, switches satellite mode and language,
/// and re-locks, but never approves, rejects or posts.
final class ElderFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"]
        app.launch()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func enterPIN(_ digits: String) {
        for d in digits { app.buttons[String(d)].tap() }
    }

    private func allowNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    func testElderSignInModerationSatelliteAndLanguage() throws {
        // Sign in with OTP and set a PIN.
        XCTAssertTrue(app.staticTexts["Who's using MyMob?"].waitForExistence(timeout: 10))
        snapshot("01-switcher")
        app.buttons["Add a person"].tap()
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Aunty Grace'")).firstMatch.tap()
        app.buttons["Send code"].tap()
        let code = app.textFields["6-digit code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10), "OTP send failed: is the server running?")
        code.tap()
        _ = code.wait(for: \.hasFocus, toEqual: true, timeout: 5)
        app.typeText("123456")
        app.buttons["Verify"].tap()
        XCTAssertTrue(app.staticTexts["Choose a 4-digit PIN"].waitForExistence(timeout: 10))
        snapshot("02-choose-pin")
        enterPIN("2468")
        XCTAssertTrue(app.staticTexts["Enter the PIN again"].waitForExistence(timeout: 5))
        enterPIN("2468")
        allowNotificationsIfAsked()

        // Community list shows the Elder's group with the Elder badge.
        let group = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Saltbush Creek'")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 15))
        snapshot("03-community")
        group.tap()

        // Feed: pinned posts first, Elder review entry point.
        XCTAssertTrue(app.staticTexts["Pinned"].waitForExistence(timeout: 15))
        snapshot("04-feed")
        app.buttons["Elder review"].tap()
        XCTAssertTrue(app.staticTexts["Join requests"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Approve"].firstMatch.exists)
        snapshot("05-elder-review")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Satellite mode: banner, lite sync in the network log.
        app.tabBars.buttons["Me"].tap()
        app.buttons["Settings"].tap()
        let satellite = app.switches["Force satellite mode"]
        XCTAssertTrue(satellite.waitForExistence(timeout: 5))
        satellite.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let banner = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Satellite mode: essentials only'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        app.buttons["Sync now"].tap()
        app.buttons["Network log"].tap()
        let liteRow = app.staticTexts["POST /api/sync/lite"]
        XCTAssertTrue(liteRow.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Latest satellite sync"].waitForExistence(timeout: 10))
        snapshot("06-network-log")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        satellite.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()

        // Demo language toggle changes strings in-app.
        app.collectionViews.firstMatch.swipeDown()
        app.collectionViews.firstMatch.swipeDown()
        let language = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Language'")).firstMatch
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        language.tap()
        app.buttons["Demo language (placeholder)"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["⟦Séttíñgs⟧"].waitForExistence(timeout: 5))
        snapshot("07-demo-language")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '⟦Láñgúágé⟧'")).firstMatch.tap()
        app.buttons["English"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Settings"].waitForExistence(timeout: 5))

        // Switch person locks back to the switcher; PIN unlocks again.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Switch person"].tap()
        let grace = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Aunty Grace Walker'")).firstMatch
        XCTAssertTrue(grace.waitForExistence(timeout: 5))
        grace.tap()
        enterPIN("1111")
        XCTAssertTrue(app.staticTexts["That PIN didn't match. Try again."].waitForExistence(timeout: 5))
        enterPIN("2468")
        XCTAssertTrue(app.tabBars.buttons["Community"].waitForExistence(timeout: 10))
        snapshot("08-unlocked")
    }
}
