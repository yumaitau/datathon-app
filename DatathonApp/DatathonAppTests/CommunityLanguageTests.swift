import Foundation
import Testing
@testable import DatathonApp

/// Downloaded community translations reach the app's lookup paths, with English fallback.
/// (Swift's `String(localized:)` resolves without going through `Bundle`, so app code uses
/// `localizedString(_:locale:)` for strings it formats itself.)
@Suite(.serialized)
struct CommunityLanguageTests {
    init() {
        CommunityBundle.install()
        StringOverrides.shared.replace(with: ["Settings": "⟦test-settings⟧"])
    }

    @Test func bundleLookupUsesOverride() {
        #expect(Bundle.main.localizedString(forKey: "Settings", value: nil, table: nil) == "⟦test-settings⟧")
    }

    @Test func nsLocalizedStringUsesOverride() {
        #expect(NSLocalizedString("Settings", comment: "") == "⟦test-settings⟧")
    }

    @Test func appHelperUsesOverride() {
        #expect(localizedString("Settings", locale: Locale(identifier: "qaa")) == "⟦test-settings⟧")
    }

    @Test func untranslatedKeysFallBackToEnglish() {
        #expect(localizedString("Notifications", locale: Locale(identifier: "qaa")) == "Notifications")
    }
}
