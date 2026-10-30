import Foundation
import Observation

/// Device-wide settings (shared by all profiles on the device).
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var baseURL: String { didSet { defaults.set(baseURL, forKey: "baseURL") } }
    /// "en", "demo" (the built-in placeholder pseudo-translation) or a community language code
    /// from the server, e.g. an ISO 639-3 code. Community strings arrive as downloaded packs.
    var language: String { didSet { defaults.set(language, forKey: "language") } }
    var forceSatellite: Bool { didSet { defaults.set(forceSatellite, forKey: "forceSatellite") } }
    var simulateOffline: Bool { didSet { defaults.set(simulateOffline, forKey: "simulateOffline") } }
    var muteSorryBusiness: Bool { didSet { defaults.set(muteSorryBusiness, forKey: "muteSorryBusiness") } }

    static let defaultBaseURL = "http://localhost:3000"
    /// Locale identifier the String Catalog uses for the placeholder demo language.
    static let demoLocaleIdentifier = "fr"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        baseURL = defaults.string(forKey: "baseURL") ?? Self.defaultBaseURL
        language = defaults.string(forKey: "language") ?? "en"
        forceSatellite = defaults.bool(forKey: "forceSatellite")
        simulateOffline = defaults.bool(forKey: "simulateOffline")
        muteSorryBusiness = defaults.bool(forKey: "muteSorryBusiness")
    }

    var locale: Locale {
        switch language {
        case "en": Locale(identifier: "en_AU")
        case "demo": Locale(identifier: Self.demoLocaleIdentifier)
        // The catalog has no localization for community languages, so lookups fall back
        // to English and the downloaded pack overrides them.
        default: Locale(identifier: language)
        }
    }
}
