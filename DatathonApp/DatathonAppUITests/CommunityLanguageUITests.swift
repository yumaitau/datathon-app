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

        // UIKit chrome (tab bar) and SwiftUI text (section header, toggle) use the pack.
        // Which seeded strings are approved depends only on each key (see server seed).
        XCTAssertTrue(app.tabBars.buttons["⟦Cómmúñíty⟧"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["⟦Nótífíçátíóñs⟧"].exists)
        XCTAssertTrue(app.switches["⟦Fórçé sátéllíté módé⟧"].exists)
        // Not translated in the pack: shown in English rather than blank, in chrome and SwiftUI alike.
        XCTAssertTrue(app.navigationBars.staticTexts["Settings"].exists)
        let languageRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Language'")).firstMatch
        XCTAssertTrue(languageRow.exists)
        snapshot("02-community-language")

        // Back to English.
        languageRow.tap()
        app.buttons["English"].tap()
        XCTAssertTrue(app.staticTexts["Notifications"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Community"].exists)
    }

    /// Elder members screen: custodian badge from the seed, appoint and stand down a custodian
    /// (restoring the original state on the server).
    func testElderAppointsLanguageCustodian() throws {
        signInAsGrace()
        let group = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Saltbush Creek'")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 15))
        group.tap()
        app.buttons["Elder review"].tap()
        let members = app.buttons["Members"]
        XCTAssertTrue(members.waitForExistence(timeout: 15))
        members.tap()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        app.typeText("Leah Thompson")
        // Seeded custodian: badge shown, and her button offers to stand her down.
        XCTAssertTrue(app.staticTexts["Leah Thompson"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Language custodian"].exists, "Seeded custodian badge missing")
        XCTAssertTrue(app.buttons["Stop language custodian"].exists)
        snapshot("03-members")

        // Sam isn't a custodian: appoint him, then stand him down to restore the seed.
        search.buttons["Clear text"].tap()
        app.typeText("Sam Thompson")
        XCTAssertTrue(app.staticTexts["Sam Thompson"].waitForExistence(timeout: 10))
        let appoint = app.buttons["Make language custodian"]
        XCTAssertTrue(appoint.waitForExistence(timeout: 5))
        appoint.tap()
        let stop = app.buttons["Stop language custodian"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "Appointment not shown")
        XCTAssertTrue(app.staticTexts["Language custodian"].exists)
        stop.tap()
        XCTAssertTrue(app.buttons["Make language custodian"].waitForExistence(timeout: 10))
    }
}
