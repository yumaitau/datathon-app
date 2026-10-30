import XCTest

/// Picks the seeded community language (fictional "Plains demo language", code `qaa`)
/// from the server and checks its downloaded strings replace the built-in English.
/// The String Catalog has no `qaa` localization, so translated text here can only come
/// from the server's pack; strings the pack lacks must fall back to English.
/// Read-only on the server.
final class CommunityLanguageUITests: XCTestCase {
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

    private func signInAsGrace() {
        XCTAssertTrue(app.staticTexts["Who's using MyMob?"].waitForExistence(timeout: 10))
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

    func testCommunityLanguageReplacesStringsWithEnglishFallback() throws {
        signInAsGrace()
        XCTAssertTrue(app.tabBars.buttons["Me"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Me"].tap()
        app.buttons["Settings"].tap()

        // The server's community language appears in the picker, named in the language.
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Language'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let community = app.buttons["Pláíñs démó"]
        XCTAssertTrue(community.waitForExistence(timeout: 10), "Community language not offered: is the server seeded?")
        snapshot("01-language-picker")
        community.tap()

        // UIKit chrome (navigation title, tab bar) and SwiftUI text both use the pack.
        XCTAssertTrue(app.navigationBars.staticTexts["⟦Séttíñgs⟧"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["⟦Cómmúñíty⟧"].exists)
        XCTAssertTrue(app.staticTexts["⟦Nótífíçátíóñs⟧"].exists)
        XCTAssertTrue(app.switches["⟦Fórçé sátéllíté módé⟧"].exists)
        // Not yet translated in the pack: shown in English rather than blank.
        XCTAssertTrue(app.switches["Mute sorry business notifications"].exists)
        snapshot("02-community-language")

        // Back to English.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '⟦Láñgúágé⟧'")).firstMatch.tap()
        app.buttons["English"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Notifications"].exists)
    }
}
