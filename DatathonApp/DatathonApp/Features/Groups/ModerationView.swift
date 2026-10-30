import SwiftUI

/// Elder review queue for one group: join requests, clinic access and reported comments.
/// Posts publish straight away; Elders moderate them from the post's ••• menu.
struct ModerationView: View {
    let groupId: String
    let groupName: String
    @Environment(AppEnvironment.self) private var env
    @Environment(NetworkMonitor.self) private var network
    @State private var queue: ModerationQueue?
    @State private var error: String?
    @State private var working: Set<String> = []

    var body: some View {
        List {
            if !network.isOnline || network.isSatelliteMode {
                Section {
                    Label("Elder review needs normal coverage.", systemImage: "wifi.exclamationmark")
                }
            }
            if let error { Section { ErrorBanner(message: error) } }

            Section {
                NavigationLink {
                    MembersView(groupId: groupId, groupName: groupName)
                } label: {
                    Label("Members", systemImage: "person.2")
                }
            }

            if let queue {
                if queue.memberships.isEmpty && queue.providerRequests.isEmpty && queue.reports.isEmpty {
                    Section {
                        ContentUnavailableView("All caught up", systemImage: "checkmark.circle",
                                               description: Text("Nothing is waiting for your review."))
                    }
                }
                joinRequests(queue.memberships)
                providers(queue.providerRequests)
                reports(queue.reports)
            } else if network.isOnline {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .localizedNavigationTitle("Elder review")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder
    private func joinRequests(_ members: [PendingMember]) -> some View {
        if !members.isEmpty {
            Section {
                ForEach(members) { m in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(m.user.name).font(.headline)
                            if m.user.isMinor == true {
                                Badge(text: "Under 18", tint: .purple)
                            }
                        }
                        Text(m.createdAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                        if m.user.isMinor == true {
                            Label(m.guardianConsent == true ? LocalizedStringKey("Guardian has consented") : LocalizedStringKey("Waiting for guardian consent"),
                                  systemImage: m.guardianConsent == true ? "checkmark.seal" : "exclamationmark.triangle")
                                .font(.caption)
                        }
                        decisionButtons(id: m.id,
                                        approve: { try await act("/api/memberships/\(m.id)/approve") },
                                        reject: { try await act("/api/memberships/\(m.id)/reject") })
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Join requests")
            } footer: {
                Text("Wants to join \(groupName).")
            }
        }
    }

    @ViewBuilder
    private func providers(_ requests: [ProviderRequest]) -> some View {
        if !requests.isEmpty {
            Section {
                ForEach(requests) { r in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(r.provider.name).font(.headline)
                        if let type = r.provider.type { Text(LocalizedStringKey(type.capitalized)).font(.caption).foregroundStyle(.secondary) }
                        if let address = r.provider.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                        if let message = r.message, !message.isEmpty { Text("“\(message)”").font(.subheadline).italic() }
                        decisionButtons(id: r.id,
                                        approve: { try await act("/api/provider-access/\(r.id)/decide", body: ["decision": "approved"]) },
                                        reject: { try await act("/api/provider-access/\(r.id)/decide", body: ["decision": "rejected"]) })
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Clinic and service access")
            } footer: {
                Text("Approving lets this service post events to the group. It never gives them the group feed or anyone's health information.")
            }
        }
    }

    @ViewBuilder
    private func reports(_ reports: [Report]) -> some View {
        if !reports.isEmpty {
            Section("Reported comments") {
                ForEach(reports) { r in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(r.comment.body).font(.subheadline)
                        Text("\(r.comment.author.name) · Reason: \(r.reason)").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button {
                                run(r.id) { try await act("/api/reports/\(r.id)/dismiss") }
                            } label: { Label("Keep comment", systemImage: "checkmark") }
                                .buttonStyle(.bordered)
                            Button(role: .destructive) {
                                run(r.id) { try await act("/api/comments/\(r.comment.id)/hide") }
                            } label: { Label("Hide comment", systemImage: "eye.slash") }
                                .buttonStyle(.bordered)
                        }
                        .disabled(working.contains(r.id))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func decisionButtons(id: String, approve: @escaping () async throws -> Void, reject: @escaping () async throws -> Void) -> some View {
        HStack {
            Button("Approve") { run(id, approve) }.buttonStyle(.borderedProminent)
            Button("Reject", role: .destructive) { run(id, reject) }.buttonStyle(.bordered)
            if working.contains(id) { ProgressView() }
        }
        .disabled(working.contains(id))
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

    private func act(_ path: String, body: [String: String] = [:]) async throws {
        let _: OKResponse = try await env.api.post(path, body)
    }

    private func load() async {
        guard network.isOnline, !network.isSatelliteMode else { return }
        do {
            queue = try await env.api.get("/api/groups/\(groupId)/moderation")
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
