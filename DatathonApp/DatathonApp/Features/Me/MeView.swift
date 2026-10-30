import SwiftData
import SwiftUI

struct MeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ProfileStore.self) private var profiles
    @Environment(SyncEngine.self) private var sync
    @State private var confirmRemove = false

    var body: some View {
        List {
            if let profile = profiles.activeProfile {
                Section {
                    HStack(spacing: 14) {
                        InitialsAvatar(initials: profile.initials, size: 56)
                        VStack(alignment: .leading) {
                            Text(profile.name).font(.title3.bold())
                            Text(verbatim: profile.phoneNumber).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                NavigationLink { CarersView() } label: { Label("Carers", systemImage: "person.2") }
                NavigationLink { SyncQueueView() } label: { Label("Waiting to send", systemImage: "tray.and.arrow.up") }
                NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") }
            }

            Section {
                Button { profiles.lock() } label: { Label("Switch person", systemImage: "person.2.circle") }
                Button("Remove me from this phone", role: .destructive) { confirmRemove = true }
            } footer: {
                if let last = sync.lastSyncAt {
                    Text("Last synced \(last.formatted(.relative(presentation: .named)))")
                }
            }
        }
        .localizedNavigationTitle("Me")
        .confirmationDialog("Remove your profile from this phone?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let id = profiles.activeProfileId {
                    env.cache.deleteAll(profileId: id)
                    env.sync.resetCursors(profileId: id)
                    try? env.container.mainContext.save()
                    profiles.remove(id)
                }
            }
        } message: {
            Text("Your saved information is deleted from this phone. Your account and communities stay as they are.")
        }
    }
}

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(CommunityLanguages.self) private var languages
    @Environment(NetworkMonitor.self) private var network
    @Environment(SyncEngine.self) private var sync

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Language", selection: Binding(
                    get: { languages.pending ?? settings.language },
                    set: { code in
                        Task {
                            await languages.choose(code, settings: settings, api: env.api,
                                                   canDownload: network.isOnline && !network.isSatelliteMode)
                        }
                    }
                )) {
                    Text(verbatim: "English").tag("en")
                    ForEach(languages.available) { language in
                        // Language names are shown as their communities write them.
                        Text(verbatim: language.status == "draft" ? "\(language.displayName) (draft)" : language.displayName)
                            .tag(language.code)
                    }
                    Text("Demo language (placeholder)").tag("demo")
                }
            } footer: {
                Text("Community languages are written and approved by each community's Elders and language custodians. Anything not yet translated shows in English.")
            }

            Section {
                Toggle("Mute sorry business notifications", isOn: $settings.muteSorryBusiness)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Notifications never show health details, because phones are often shared.")
            }

            Section {
                TextField("Server address", text: $settings.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Reset to default") { settings.baseURL = AppSettings.defaultBaseURL }
            } header: {
                Text("Server")
            }

            Section {
                Toggle("Force satellite mode", isOn: $settings.forceSatellite)
                Toggle("Simulate offline", isOn: $settings.simulateOffline)
                NavigationLink { NetworkLogView() } label: { Label("Network log", systemImage: "list.bullet.rectangle") }
                Button("Sync now") { Task { await env.refresh() } }
                    .disabled(sync.isSyncing)
                LabeledContent("Connection") {
                    Text(network.isOnline ? LocalizedStringKey("Online") : LocalizedStringKey("Offline"))
                }
                LabeledContent("Interface") { Text(verbatim: network.interfaceName) }
                LabeledContent("Ultra-constrained path") {
                    Text(network.isUltraConstrained ? LocalizedStringKey("Yes") : LocalizedStringKey("No"))
                }
                LabeledContent("Link quality") { Text(verbatim: network.linkQuality) }
                if let error = sync.lastError {
                    LabeledContent("Last sync error") { Text(error).font(.caption) }
                }
            } header: {
                Text("Developer")
            } footer: {
                Text("Satellite mode sends one small batched request to /api/sync/lite, loads no images and never polls.")
            }
        }
        .localizedNavigationTitle("Settings")
        .task {
            // Pick up newly published community languages; skipped over satellite.
            guard network.isOnline, !network.isSatelliteMode else { return }
            await languages.refresh(api: env.api, active: settings.language)
        }
        .onChange(of: settings.simulateOffline) { _, offline in
            if !offline { Task { await env.refresh() } }
        }
    }
}

struct NetworkLogView: View {
    @Environment(NetworkLog.self) private var log
    @State private var syncOnly = true

    var body: some View {
        let entries = syncOnly ? log.entries.filter(\.isSync) : log.entries
        List {
            Section {
                Toggle("Sync requests only", isOn: $syncOnly)
            }
            if let lite = log.entries.first(where: { $0.lite && $0.status != nil }) {
                Section("Latest satellite sync") {
                    LabeledContent("Sent") { Text(verbatim: Format.bytes(lite.bytesSent)) }
                    LabeledContent("Received") { Text(verbatim: Format.bytes(lite.bytesReceived)) }
                    if let c = lite.compressedBytes {
                        LabeledContent("Over the air (gzip)") { Text(verbatim: Format.bytes(c)).bold() }
                    }
                }
            }
            Section {
                if entries.isEmpty {
                    Text("No requests yet.").foregroundStyle(.secondary)
                }
                ForEach(entries) { e in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(verbatim: "\(e.method) \(e.path)").font(.footnote.monospaced().weight(.semibold))
                            Spacer()
                            if e.lite { Badge(text: "Satellite", systemImage: "antenna.radiowaves.left.and.right", tint: .indigo) }
                        }
                        HStack(spacing: 10) {
                            Text(verbatim: e.status.map { "HTTP \($0)" } ?? "—")
                            Text("↑ \(Format.bytes(e.bytesSent))")
                            Text("↓ \(Format.bytes(e.bytesReceived))")
                            Text(verbatim: "\(e.durationMs) ms")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        if e.payloadBytes != nil || e.compressedBytes != nil {
                            HStack(spacing: 10) {
                                if let p = e.payloadBytes { Text("Payload \(Format.bytes(p))") }
                                if let c = e.compressedBytes { Text("Gzip \(Format.bytes(c))") }
                            }
                            .font(.caption.monospacedDigit())
                        }
                        if let err = e.error { Text(err).font(.caption).foregroundStyle(.red) }
                        Text(e.date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("Requests")
            }
        }
        .localizedNavigationTitle("Network log")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Clear") { log.clear() } }
        }
    }
}

struct SyncQueueView: View {
    @Environment(SyncEngine.self) private var sync
    @Environment(NetworkMonitor.self) private var network
    @Query private var mutations: [PendingMutation]

    init() {
        let pid = AppEnvironment.shared.profiles.activeProfileId ?? ""
        _mutations = Query(filter: #Predicate<PendingMutation> { $0.profileId == pid }, sort: \.createdAt)
    }

    var body: some View {
        List {
            if mutations.isEmpty {
                ContentUnavailableView("Everything is sent", systemImage: "checkmark.icloud")
            }
            ForEach(mutations) { m in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(label(for: m.type)).font(.headline)
                        Spacer()
                        if m.state == "rejected" {
                            Badge(text: "Not accepted", tint: .red)
                        } else {
                            Badge(text: "Queued", systemImage: "clock", tint: .orange)
                        }
                    }
                    Text(m.createdAt, format: .dateTime.hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: m.clientMutationId).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    if let err = m.lastError { Text(err).font(.caption).foregroundStyle(.red) }
                    if m.state == "rejected" {
                        Button("Dismiss") { sync.discard(m) }.font(.caption)
                    }
                }
            }
        }
        .localizedNavigationTitle("Waiting to send")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Send now") { Task { await sync.flush() } }
                    .disabled(!network.isOnline || sync.isSyncing)
            }
        }
    }

    private func label(for type: String) -> LocalizedStringKey {
        switch type {
        case "rsvp": "RSVP"
        case "confirmAppointment": "Appointment confirmation"
        case "createPost": "Post"
        case "createComment": "Comment"
        case "reaction": "Reaction"
        default: LocalizedStringKey(type)
        }
    }
}
