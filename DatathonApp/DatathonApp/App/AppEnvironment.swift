import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications

enum AppTab: Hashable {
    case community, calendar, me
}

/// Cross-screen navigation intents (e.g. a notification tap opening appointments).
@Observable
final class Router {
    var tab: AppTab = .community
}

/// Owns the app's long-lived services. A singleton so the UIApplicationDelegate can reach them.
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    let container: ModelContainer
    let settings: AppSettings
    let profiles: ProfileStore
    let network: NetworkMonitor
    let log: NetworkLog
    let api: APIClient
    let sync: SyncEngine
    let router = Router()
    let push: PushManager
    let languages = CommunityLanguages()

    init() {
        if ProcessInfo.processInfo.arguments.contains("-uiTestReset") {
            // UI tests start from an empty device: no profiles, default settings.
            let d = UserDefaults.standard
            for key in d.dictionaryRepresentation().keys { d.removeObject(forKey: key) }
        }
        container = Self.makeContainer()
        let settings = AppSettings()
        let profiles = ProfileStore()
        let network = NetworkMonitor(settings: settings)
        let log = NetworkLog()
        let api = APIClient(log: log,
                            baseURL: { settings.baseURL },
                            tokenProvider: { profiles.token },
                            forceOffline: { settings.simulateOffline })
        let sync = SyncEngine(context: container.mainContext,
                              transport: api,
                              profileId: { profiles.isUnlocked ? profiles.activeProfileId : nil },
                              currentUser: { profiles.currentUserRef },
                              isOnline: { network.isOnline },
                              isSatellite: { network.isSatelliteMode })
        api.onUnauthorized = { profiles.markNeedsSignIn() }
        self.settings = settings
        self.profiles = profiles
        self.network = network
        self.log = log
        self.api = api
        self.sync = sync
        push = PushManager(api: api, router: router)
        CommunityBundle.install()
        languages.activate(settings.language)
    }

    private static func makeContainer() -> ModelContainer {
        let schema = Schema([CachedItem.self, PendingMutation.self])
        do {
            return try ModelContainer(for: schema)
        } catch {
            // A cache is disposable; never fail launch because of it.
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
    }

    var cache: CacheStore { CacheStore(context: container.mainContext) }

    /// Refresh `Me` and run a sync. Skips the extra `/api/me` call and language
    /// downloads in satellite mode.
    func refresh() async {
        guard profiles.isUnlocked else { return }
        if network.isOnline && !network.isSatelliteMode {
            if let me: Me = try? await api.get("/api/me") { profiles.setMe(me) }
            await languages.refresh(api: api, active: settings.language)
        }
        await sync.flush()
        if let m = sync.membershipsFromSync { profiles.updateMemberships(m) }
    }
}

/// APNs registration and notification routing. Previews are generic and composed by the server.
final class PushManager: NSObject, UNUserNotificationCenterDelegate {
    private let api: APIClient
    private let router: Router
    private var apnsToken: String?

    init(api: APIClient, router: Router) {
        self.api = api
        self.router = router
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    var deviceId: String { UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device" }

    func requestAuthorizationAndRegister() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        await registerDevice()
    }

    func didRegister(token: Data) {
        apnsToken = token.map { String(format: "%02x", $0) }.joined()
        Task { await registerDevice() }
    }

    /// Links this device (and its APNs token, if any) to whichever profile is active.
    func registerDevice() async {
        struct Body: Encodable { let deviceId: String; let apnsToken: String? }
        let _: OKResponse? = try? await api.post("/api/devices", Body(deviceId: deviceId, apnsToken: apnsToken))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { router.tab = .calendar }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Create services (and the notification delegate) before a launch-from-notification is delivered.
        _ = AppEnvironment.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppEnvironment.shared.push.didRegister(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator or missing entitlement: the device is still registered without a token.
    }
}
