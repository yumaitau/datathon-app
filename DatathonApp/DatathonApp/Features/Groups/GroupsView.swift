import SwiftData
import SwiftUI

struct GroupsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ProfileStore.self) private var profiles
    @State private var joining = false

    var body: some View {
        let memberships = profiles.me?.memberships ?? []
        let active = memberships.filter(\.isActive)
        let pending = memberships.filter(\.isPending)

        List {
            if let pid = profiles.activeProfileId {
                NoticesSection(profileId: pid)
            }

            if active.isEmpty && pending.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No communities yet", systemImage: "person.3")
                    } description: {
                        Text("Join your community with an invite code from an Elder, or search by name.")
                    } actions: {
                        Button("Join a community") { joining = true }.buttonStyle(.borderedProminent)
                    }
                }
            }

            if !active.isEmpty {
                Section("Your communities") {
                    ForEach(active) { m in
                        NavigationLink(value: m) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.groupName).font(.headline)
                                    Text(LocalizedStringKey(m.groupType.capitalized)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if profiles.isElder(of: m.groupId) {
                                    Badge(text: "Elder", systemImage: "checkmark.shield")
                                }
                            }
                        }
                    }
                }
            }

            if !pending.isEmpty {
                Section {
                    ForEach(pending) { m in
                        HStack {
                            Text(m.groupName)
                            Spacer()
                            Badge(text: "Pending", systemImage: "hourglass", tint: .orange)
                        }
                    }
                } header: {
                    Text("Waiting for approval")
                } footer: {
                    Text("An Elder will review your request. You'll see the community here once you're approved.")
                }
            }
        }
        .navigationTitle("Community")
        .navigationDestination(for: Membership.self) { m in GroupFeedView(membership: m) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { joining = true } label: { Label("Join a community", systemImage: "plus") }
            }
        }
        .refreshable { await env.refresh() }
        .sheet(isPresented: $joining) { NavigationStack { JoinGroupView() } }
        .connectivityBanner(profileId: profiles.activeProfileId)
    }
}

/// Urgent and sorry business notices delivered by the satellite lite sync.
private struct NoticesSection: View {
    @Query private var items: [CachedItem]
    @Environment(AppSettings.self) private var settings

    init(profileId: String) {
        let kind = CacheKind.notice
        _items = Query(filter: #Predicate<CachedItem> { $0.profileId == profileId && $0.kind == kind },
                       sort: \.sortDate, order: .reverse)
    }

    var body: some View {
        let notices = items.compactMap { $0.decode(LiteNotice.self) }.prefix(5)
        if !notices.isEmpty {
            Section("Notices") {
                ForEach(notices) { n in
                    VStack(alignment: .leading, spacing: 4) {
                        if n.kind == "sorry_business" {
                            Badge(text: "Sorry business", tint: .gray)
                        } else {
                            Badge(text: "Urgent", systemImage: "exclamationmark.circle", tint: .red)
                        }
                        if let t = n.title { Text(t).font(.headline) }
                        Text(n.body).font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

struct JoinGroupView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var query = ""
    @State private var results: [GroupSummary] = []
    @State private var busy = false
    @State private var error: String?
    @State private var joinedName: String?

    var body: some View {
        Form {
            Section {
                TextField("Invite code", text: $code, prompt: Text(verbatim: "SALT-2026"))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.title3.monospaced())
                Button("Request to join") { Task { await join(code: code) } }
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            } header: {
                Text("Have an invite code?")
            } footer: {
                Text("Elders share invite codes. An Elder still approves every new member.")
            }

            Section("Or search") {
                TextField("Community name", text: $query)
                    .onSubmit { Task { await search() } }
                    .submitLabel(.search)
                ForEach(results) { g in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(g.name).font(.headline)
                            HStack(spacing: 4) {
                                if let parent = g.parentName { Text(parent) }
                                if let count = g.memberCount { Text("· \(count) members") }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Request") { Task { await join(groupId: g.id) } }
                            .buttonStyle(.bordered)
                    }
                }
            }

            if let error { Section { ErrorBanner(message: error) } }
        }
        .navigationTitle("Join a community")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .disabled(!network.isOnline)
        .overlay(alignment: .bottom) {
            if !network.isOnline {
                Text("Joining needs a connection.").padding().background(.thinMaterial, in: Capsule()).padding()
            }
        }
        .alert("Request sent", isPresented: Binding(get: { joinedName != nil }, set: { if !$0 { joinedName = nil; dismiss() } })) {
            Button("OK") {}
        } message: {
            Text("An Elder of \(joinedName ?? "") will review your request.")
        }
    }

    private func search() async {
        guard !query.isEmpty else { return }
        error = nil
        do {
            let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            results = try await env.api.get("/api/groups/search?q=\(q)")
        } catch { self.error = error.localizedDescription }
    }

    private func join(code: String? = nil, groupId: String? = nil) async {
        busy = true; error = nil
        defer { busy = false }
        var body: [String: String] = [:]
        if let code { body["joinCode"] = code.trimmingCharacters(in: .whitespaces).uppercased() }
        if let groupId { body["groupId"] = groupId }
        do {
            let membership: Membership = try await env.api.post("/api/groups/join", body)
            await env.refresh()
            if let me = env.profiles.me, !me.memberships.contains(where: { $0.id == membership.id }) {
                env.profiles.updateMemberships(me.memberships + [membership])
            }
            joinedName = membership.groupName
        } catch { self.error = error.localizedDescription }
    }
}
