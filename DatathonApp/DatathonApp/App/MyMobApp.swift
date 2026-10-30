import SwiftData
import SwiftUI

@main
struct MyMobApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let env = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .environment(env.settings)
                .environment(env.profiles)
                .environment(env.network)
                .environment(env.sync)
                .environment(env.router)
                .environment(env.log)
                .environment(env.languages)
                .modelContainer(env.container)
        }
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(ProfileStore.self) private var profiles
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let profile = profiles.activeProfile, !profiles.isLocked {
                if profile.needsSignIn {
                    NavigationStack { SignInFlowView(mode: .reauth(profile)) }
                } else {
                    MainTabView()
                        .id(profile.id) // fresh view state per person
                }
            } else {
                ProfileSwitcherView()
            }
        }
        .overlay {
            // Hide content in the app switcher snapshot on shared phones.
            if scenePhase != .active {
                Color(.systemBackground).ignoresSafeArea()
                    .overlay { Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary) }
            }
        }
        .environment(\.locale, settings.locale)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: profiles.lock()
            case .active: Task { await env.refresh() }
            default: break
            }
        }
        .onChange(of: network.isOnline) { _, online in
            if online { Task { await env.refresh() } }
        }
        .onChange(of: network.isSatelliteMode) { _, _ in
            // One foreground sync on entering or leaving satellite mode; no polling.
            Task { await env.refresh() }
        }
        .onChange(of: profiles.unlockCount) { _, _ in
            guard profiles.isUnlocked else { return }
            Task {
                await env.refresh()
                await env.push.requestAuthorizationAndRegister()
            }
        }
    }
}

struct MainTabView: View {
    @Environment(Router.self) private var router
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.locale) private var locale

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab(localizedString("Community", locale: locale), systemImage: "person.3", value: AppTab.community) {
                NavigationStack { GroupsView() }
                    .connectivityBanner(profileId: profiles.activeProfileId)
            }
            Tab(localizedString("Calendar", locale: locale), systemImage: "calendar", value: AppTab.calendar) {
                NavigationStack { AppointmentsView() }
                    .connectivityBanner(profileId: profiles.activeProfileId)
            }
            Tab(localizedString("Me", locale: locale), systemImage: "person.crop.circle", value: AppTab.me) {
                NavigationStack { MeView() }
                    .connectivityBanner(profileId: profiles.activeProfileId)
            }
        }
    }
}
