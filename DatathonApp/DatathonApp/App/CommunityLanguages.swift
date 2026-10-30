import Foundation
import ObjectiveC
import Observation

/// A language offered by the server: English, or a community-owned language.
struct LanguageInfo: Codable, Identifiable, Hashable {
    let code: String
    let name: String
    let endonym: String?
    let status: String
    let approved: Int?
    let total: Int?
    var id: String { code }
    var displayName: String { endonym ?? name }
}

/// Approved app strings for one language, keyed by the String Catalog's source key.
struct LanguagePack: Codable {
    let code: String
    let version: String
    let strings: [String: String]
}

/// Strings consulted before the built-in catalog. Read from any thread by the bundle override.
final class StringOverrides: @unchecked Sendable {
    static let shared = StringOverrides()
    private let lock = NSLock()
    private var strings: [String: String] = [:]

    func replace(with strings: [String: String]) {
        lock.withLock { self.strings = strings }
    }

    func value(for key: String) -> String? {
        lock.withLock { strings[key] }
    }
}

/// `Bundle.main` stand-in that serves community translations first and falls back to
/// the String Catalog (English), so an untranslated string never appears blank.
final class CommunityBundle: Bundle, @unchecked Sendable {
    private static var installed = false

    /// Swaps the main bundle's class once at launch; all lookups then pass through here.
    static func install() {
        guard !installed else { return }
        installed = true
        // SwiftUI resolves `Text`, `Button`, `Toggle` and section labels through these
        // locale- and markdown-aware lookups rather than `localizedString(forKey:value:table:)`.
        // SHORTCUT: some are private Foundation selectors. Fine for the datathon build; before
        // App Store submission, replace with a reviewed approach (e.g. resolving keys through
        // `localizedString(_:locale:)` in views). Missing selectors are skipped safely.
        hookString("localizedStringForKey:value:table:localization:")
        hookString("localizedStringForKey:value:table:localizations:")
        hookString("_localizedStringForKey:value:table:localizations:")
        hookMarkdownString("_localizedStringForKey:value:table:bundleLocalizations:localization:preventMarkdownParsing:")
        hookAttributed("localizedAttributedStringForKey:value:table:")
        hookAttributedLocalized("localizedAttributedStringForKey:value:table:localization:")
        object_setClass(Bundle.main, CommunityBundle.self)
    }

    static func translated(_ key: NSString, table: NSString?) -> String? {
        guard table == nil || table == "Localizable" else { return nil }
        return StringOverrides.shared.value(for: key as String)
    }

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let translated = Self.translated(key as NSString, table: tableName as NSString?) { return translated }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }

    /// `(key, value, table, localization(s)) -> NSString`
    private static func hookString(_ name: String) {
        let sel = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(Bundle.self, sel) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, AnyObject?) -> NSString
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let block: @convention(block) (AnyObject, NSString, NSString?, NSString?, AnyObject?) -> NSString = { bundle, key, value, table, loc in
            if let t = translated(key, table: table) { return t as NSString }
            return original(bundle, sel, key, value, table, loc)
        }
        class_addMethod(CommunityBundle.self, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }

    /// `(key, value, table, bundleLocalizations, localization, preventMarkdownParsing) -> NSString`
    private static func hookMarkdownString(_ name: String) {
        let sel = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(Bundle.self, sel) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, AnyObject?, AnyObject?, ObjCBool) -> NSString
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let block: @convention(block) (AnyObject, NSString, NSString?, NSString?, AnyObject?, AnyObject?, ObjCBool) -> NSString = { bundle, key, value, table, all, loc, noMarkdown in
            if let t = translated(key, table: table) { return t as NSString }
            return original(bundle, sel, key, value, table, all, loc, noMarkdown)
        }
        class_addMethod(CommunityBundle.self, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }

    /// `(key, value, table) -> NSAttributedString`
    private static func hookAttributed(_ name: String) {
        let sel = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(Bundle.self, sel) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?) -> NSAttributedString
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let block: @convention(block) (AnyObject, NSString, NSString?, NSString?) -> NSAttributedString = { bundle, key, value, table in
            if let t = translated(key, table: table) { return NSAttributedString(string: t) }
            return original(bundle, sel, key, value, table)
        }
        class_addMethod(CommunityBundle.self, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }

    /// `(key, value, table, localization) -> NSAttributedString`
    private static func hookAttributedLocalized(_ name: String) {
        let sel = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(Bundle.self, sel) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, NSString?) -> NSAttributedString
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let block: @convention(block) (AnyObject, NSString, NSString?, NSString?, NSString?) -> NSAttributedString = { bundle, key, value, table, loc in
            if let t = translated(key, table: table) { return NSAttributedString(string: t) }
            return original(bundle, sel, key, value, table, loc)
        }
        class_addMethod(CommunityBundle.self, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }
}

/// Community languages: the list the server offers, and downloaded packs cached on disk
/// so a chosen language keeps working offline and in satellite mode.
@Observable
final class CommunityLanguages {
    private(set) var available: [LanguageInfo] = []
    private(set) var lastError: String?
    /// A language whose pack is downloading after being chosen.
    private(set) var pending: String?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var activeStrings: [String: String] = [:]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Languages", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        available = (try? load([LanguageInfo].self, from: "languages.json")) ?? []
    }

    func isCommunityLanguage(_ code: String) -> Bool {
        code != "en" && code != "demo"
    }

    /// Applies cached strings for `code` (or clears them for English and the built-in demo).
    func activate(_ code: String) {
        let strings = isCommunityLanguage(code) ? ((try? load(LanguagePack.self, from: "\(code).json"))?.strings ?? [:]) : [:]
        guard strings != activeStrings else { return }
        activeStrings = strings
        StringOverrides.shared.replace(with: strings)
    }

    /// Chooses a language: downloads its pack first (when there's normal coverage), then
    /// switches, so the UI redraws once with the new strings already in place.
    func choose(_ code: String, settings: AppSettings, api: APIClient, canDownload: Bool) async {
        if isCommunityLanguage(code) && canDownload {
            pending = code
            await refresh(api: api, active: code)
            pending = nil
        }
        activate(code)
        settings.language = code
    }

    /// Fetches the language list and the active language's strings. Never call over satellite:
    /// translations are not essential, so they wait for normal coverage. Updated strings for
    /// the current language apply to screens drawn after this, without resetting navigation.
    func refresh(api: APIClient, active code: String) async {
        do {
            let list: [LanguageInfo] = try await api.get("/api/i18n")
            available = list.filter { $0.code != "en" }
            try save(available, to: "languages.json")
            if isCommunityLanguage(code) {
                let pack: LanguagePack = try await api.get("/api/i18n/\(code)?platform=ios")
                try save(pack, to: "\(code).json")
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        activate(code)
    }

    private func load<T: Decodable>(_ type: T.Type, from file: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: directory.appendingPathComponent(file)))
    }

    private func save<T: Encodable>(_ value: T, to file: String) throws {
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(file), options: .atomic)
    }
}
