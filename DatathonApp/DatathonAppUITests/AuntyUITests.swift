import XCTest

/// Drives the AI Aunty against the dev server as Aunty Grace (seeded Elder of
/// Saltbush Creek). Needs the group's Aunty switched on in the Elder portal, or
/// with `PUT /api/groups/:id/aunty/settings`.
///
/// Writes to Grace's own private thread and clears it again at the end; it
/// touches no shared demo data.
///
/// Uses the app's default server. To point it elsewhere, set `MYMOB_BASE_URL`
/// in the scheme's Test action environment -- `xcodebuild`'s `TEST_RUNNER_`
/// prefix does not reach the UI-test runner process, so a CLI run cannot
/// override it that way.
///
/// One test, one sign-in: the OTP screen is flaky when a run signs in twice.
final class AuntyUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"]
        if let base = ProcessInfo.processInfo.environment["MYMOB_BASE_URL"] {
            app.launchArguments += ["-baseURL", base]
        }
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

    private func signInAsGrace() {
        XCTAssertTrue(app.buttons["Add a person"].waitForExistence(timeout: 10))
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
        enterPIN("2468")
        XCTAssertTrue(app.staticTexts["Enter the PIN again"].waitForExistence(timeout: 5))
        enterPIN("2468")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    private func openAunty() {
        XCTAssertTrue(app.tabBars.buttons["Community"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Community"].tap()
        let group = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Saltbush Creek'")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 15))
        group.tap()
        let aunty = app.buttons["Yarn with Aunty"]
        XCTAssertTrue(aunty.waitForExistence(timeout: 10))
        aunty.tap()
    }

    /// Open the yarn, see what she says she is, ask a health question, and get
    /// the clinic handover rather than advice.
    func testYarnShowsDisclaimerThenHandsHealthOverToTheClinic() throws {
        signInAsGrace()
        openAunty()

        // She names herself as a computer and promises privacy before anyone types.
        let disclaimer = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'not a real Elder'")).firstMatch
        XCTAssertTrue(disclaimer.waitForExistence(timeout: 15),
                      "Disclaimer missing: is the Aunty switched on for Saltbush Creek?")
        XCTAssertTrue(disclaimer.label.contains("Elders can't read it"))
        snapshot("01-aunty-opened")

        let field = app.textFields["Tell Aunty what's going on…"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        _ = field.wait(for: \.hasFocus, toEqual: true, timeout: 5)
        app.typeText("my sugar test came back high, what should i do")
        snapshot("02-question-typed")
        app.buttons["Send to Aunty"].tap()

        // `.combine` on the handover panel makes it an `.other` element, not a
        // static text, so match on any descendant's label.
        let handover = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'for the clinic'")).firstMatch
        XCTAssertTrue(handover.waitForExistence(timeout: 30),
                      "No clinic handover came back. On screen:\n\(app.debugDescription)")
        snapshot("03-clinic-handover")

        // Leave Grace's thread as we found it.
        app.buttons["Clear this yarn"].tap()
        app.buttons["Clear it"].tap()
        XCTAssertTrue(app.staticTexts["Hello bub. What's going on for you today?"]
            .waitForExistence(timeout: 10))
        snapshot("04-cleared")
    }
}
