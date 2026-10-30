import SwiftData
import SwiftUI

/// Nominated carers: who can see my appointments, and whose appointments I can see.
struct CarersView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ProfileStore.self) private var profiles
    @Environment(NetworkMonitor.self) private var network
    @State private var carers: CarersPayload?
    @State private var adding = false
    @State private var revoking: CarerLink?
    @State private var error: String?

    var body: some View {
        let myCarers = (carers?.myCarers ?? []).filter { $0.status == "active" }
        let caringFor = (carers?.caringFor ?? []).filter { $0.status == "active" }

        List {
            Section {
                if myCarers.isEmpty {
                    Text("No one can see your appointments yet.").foregroundStyle(.secondary)
                }
                ForEach(myCarers) { link in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(link.carer.name).font(.headline)
                            if let since = link.consentedAt {
                                Text("Sharing since \(since.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Stop sharing", role: .destructive) { revoking = link }
                            .buttonStyle(.bordered)
                    }
                }
                Button { adding = true } label: { Label("Add a carer", systemImage: "person.badge.plus") }
                    .disabled(!network.isOnline || network.isSatelliteMode)
            } header: {
                Text("People who can see my appointments")
            } footer: {
                Text("Carers see your appointment times, places and providers, and get reminders. They can't change your appointments.")
            }

            Section("People I care for") {
                if caringFor.isEmpty {
                    Text("No one has chosen you as their carer.").foregroundStyle(.secondary)
                }
                ForEach(caringFor) { link in
                    Text(link.person.name)
                }
            }

            if let error { Section { ErrorBanner(message: error) } }
        }
        .navigationTitle("Carers")
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $adding) {
            NavigationStack { AddCarerView { await load() } }
        }
        .confirmationDialog(
            Text("Stop sharing with \(revoking?.carer.name ?? "")?"),
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            titleVisibility: .visible
        ) {
            Button("Stop sharing", role: .destructive) {
                if let link = revoking { Task { await revoke(link) } }
            }
        } message: {
            Text("They will no longer see your appointments or get reminders about them. You can add them again later.")
        }
    }

    private func load() async {
        guard let pid = profiles.activeProfileId else { return }
        if carers == nil {
            carers = env.cache.value(CarersPayload.self, profileId: pid, kind: CacheKind.carers, id: "carers")
        }
        guard network.isOnline, !network.isSatelliteMode else { return }
        do {
            let fresh: CarersPayload = try await env.api.get("/api/carers")
            carers = fresh
            env.cache.upsert(fresh, profileId: pid, kind: CacheKind.carers, id: "carers", sortDate: .now)
            try? env.container.mainContext.save()
            error = nil
        } catch let e as APIError where e.isOffline {
        } catch { self.error = error.localizedDescription }
    }

    private func revoke(_ link: CarerLink) async {
        do {
            let _: CarerLink = try await env.api.delete("/api/carers/\(link.id)")
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

struct AddCarerView: View {
    var onAdded: () async -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var consent = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Carer's mobile number", text: $phone, prompt: Text("0400 000 000"))
                    .keyboardType(.phonePad)
                    .font(.title3)
            } footer: {
                Text("Your carer needs to have MyMob on their phone.")
            }

            Section {
                Toggle(isOn: $consent) {
                    Text("I agree that this person can see my appointment times, places and providers, and receive reminders about them. I can stop sharing at any time.")
                        .font(.subheadline)
                }
            } header: {
                Text("Your consent")
            }

            if let error { Section { ErrorBanner(message: error) } }
        }
        .navigationTitle("Add a carer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Share") { Task { await add() } }
                    .disabled(!consent || normalizePhone(phone).count < 10 || busy)
            }
        }
    }

    private func add() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let _: CarerLink = try await env.api.post("/api/carers", ["phoneNumber": normalizePhone(phone)])
            await onAdded()
            dismiss()
        } catch APIError.notFound {
            error = String(localized: "No one with that number uses MyMob yet. Ask them to install it first.")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
