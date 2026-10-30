import SwiftUI

/// Elder-only member list: remove people, and appoint language custodians who can draft
/// translations of the community's languages (Elders approve them).
struct MembersView: View {
    let groupId: String
    let groupName: String
    @Environment(AppEnvironment.self) private var env
    @Environment(NetworkMonitor.self) private var network
    @State private var members: [GroupMember]?
    @State private var error: String?
    @State private var working: Set<String> = []
    @State private var removing: GroupMember?
    @State private var search = ""

    private var shown: [GroupMember] {
        let all = members ?? []
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.user.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            if !network.isOnline || network.isSatelliteMode {
                Section { Label("Managing members needs normal coverage.", systemImage: "wifi.exclamationmark") }
            }
            if let error { Section { ErrorBanner(message: error) } }
            if let members {
                Section {
                    ForEach(shown) { m in row(m) }
                } header: {
                    Text("\(members.count) members")
                } footer: {
                    Text("Language custodians draft translations of your community's languages. Elders approve them before anyone sees them.")
                }
            } else if network.isOnline {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search members"))
        .localizedNavigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog("Remove this person from the group?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let m = removing { run(m.id) { try await post("/api/memberships/\(m.id)/remove") } }
            }
        } message: {
            Text("They stop seeing \(groupName). They can ask to join again.")
        }
    }

    @ViewBuilder
    private func row(_ m: GroupMember) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(m.user.name).font(.headline)
                if m.isElder { Badge(text: "Elder", tint: .green) }
                if m.canTranslate { Badge(text: "Language custodian", tint: .blue) }
                if m.user.isMinor == true { Badge(text: "Under 18", tint: .purple) }
            }
            if !m.isElder {
                HStack {
                    Button {
                        run(m.id) { try await post("/api/memberships/\(m.id)/custodian", ["canTranslate": !m.canTranslate]) }
                    } label: {
                        Text(m.canTranslate ? LocalizedStringKey("Stop language custodian") : LocalizedStringKey("Make language custodian"))
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Remove", role: .destructive) { removing = m }
                        .buttonStyle(.bordered)
                }
                .disabled(working.contains(m.id))
                .font(.subheadline)
            }
        }
        .padding(.vertical, 2)
    }

    private func run(_ id: String, _ action: @escaping () async throws -> Void) {
        working.insert(id)
        Task {
            defer { working.remove(id) }
            do {
                try await action()
                error = nil
                await load()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func post(_ path: String, _ body: [String: Bool] = [:]) async throws {
        let _: OKResponse = try await env.api.post(path, body)
    }

    private func load() async {
        guard network.isOnline, !network.isSatelliteMode else { return }
        do {
            members = try await env.api.get("/api/groups/\(groupId)/members")
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
