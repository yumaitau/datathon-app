import SwiftData
import SwiftUI

/// Personal calendar: my appointments and those of people I care for.
struct AppointmentsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ProfileStore.self) private var profiles
    @Environment(NetworkMonitor.self) private var network
    @Query private var items: [CachedItem]
    @Query private var pendingConfirms: [PendingMutation]
    @State private var scope = Scope.mine
    @State private var invites: [PatientInvite] = []
    @State private var error: String?

    enum Scope: Hashable { case mine, caring }

    init() {
        let pid = AppEnvironment.shared.profiles.activeProfileId ?? ""
        let kind = CacheKind.appointment
        _items = Query(filter: #Predicate<CachedItem> { $0.profileId == pid && $0.kind == kind }, sort: \.sortDate)
        _pendingConfirms = Query(filter: #Predicate<PendingMutation> {
            $0.profileId == pid && $0.type == "confirmAppointment" && $0.state == "queued"
        })
    }

    var body: some View {
        let all = items.compactMap { $0.decode(Appointment.self) }
        let scoped = all.filter { scope == .mine ? $0.isMine : !$0.isMine }
        let upcoming = scoped.filter { $0.startsAt >= Calendar.current.startOfDay(for: .now) && $0.status != "cancelled" }
        let past = scoped.filter { !upcoming.contains($0) }.reversed()
        let queuedIds = Set(pendingConfirms.compactMap(\.targetId))

        List {
            Section {
                Picker("Show", selection: $scope) {
                    Text("Mine").tag(Scope.mine)
                    Text("Caring for").tag(Scope.caring)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if !invites.isEmpty && scope == .mine {
                Section {
                    ForEach(invites) { invite in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(invite.provider.name) would like to send you appointment details and reminders in MyMob.")
                                .font(.subheadline)
                            Text("Only you, and carers you choose, will see them.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Accept") { Task { await accept(invite) } }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Label("Clinic invitations", systemImage: "envelope.badge")
                }
            }

            if let error { Section { ErrorBanner(message: error) } }

            Section("Upcoming") {
                if upcoming.isEmpty {
                    Text(scope == .mine ? LocalizedStringKey("No upcoming appointments.") : LocalizedStringKey("No one has shared upcoming appointments with you."))
                        .foregroundStyle(.secondary)
                }
                ForEach(upcoming) { a in
                    NavigationLink(value: a.id) { AppointmentRow(appointment: a, queued: queuedIds.contains(a.id)) }
                }
            }

            if !past.isEmpty {
                Section("Past") {
                    ForEach(Array(past)) { a in
                        NavigationLink(value: a.id) { AppointmentRow(appointment: a, queued: queuedIds.contains(a.id)) }
                    }
                }
            }
        }
        .localizedNavigationTitle("Calendar")
        .navigationDestination(for: String.self) { id in AppointmentDetailView(appointmentId: id) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { CarersView() } label: { Label("Carers", systemImage: "person.2.badge.gearshape") }
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        await env.sync.flush()
        guard network.isOnline, !network.isSatelliteMode else { return }
        do {
            let all: [PatientInvite] = try await env.api.get("/api/patient-links")
            invites = all.filter { $0.status == "invited" }
            error = nil
        } catch let e as APIError where e.isOffline {
        } catch { self.error = error.localizedDescription }
    }

    private func accept(_ invite: PatientInvite) async {
        do {
            let _: PatientInvite = try await env.api.post("/api/patient-links/\(invite.id)/accept")
            invites.removeAll { $0.id == invite.id }
            // Pull appointments the clinic has already booked.
            if let pid = profiles.activeProfileId {
                let r: AppointmentsResponse = try await env.api.get("/api/appointments")
                (r.mine + r.caring).forEach { env.cache.upsert(appointment: $0, profileId: pid) }
                try? env.container.mainContext.save()
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct AppointmentRow: View {
    let appointment: Appointment
    let queued: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(appointment.startsAt, format: .dateTime.weekday(.abbreviated).day().month().hour().minute())
                    .font(.subheadline.weight(.semibold))
                Spacer()
                AppointmentStatusBadge(status: appointment.status)
            }
            Text(appointment.type).font(.headline)
            Text(appointment.provider.name).font(.subheadline).foregroundStyle(.secondary)
            if !appointment.isMine && !appointment.personName.isEmpty {
                Label("For \(appointment.personName)", systemImage: "person").font(.caption)
            }
            if queued {
                Label("Waiting to sync", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AppointmentStatusBadge: View {
    let status: String
    var body: some View {
        switch status {
        case "confirmed": Badge(text: "Confirmed", systemImage: "checkmark.circle", tint: .green)
        case "attended": Badge(text: "Attended", systemImage: "checkmark", tint: .gray)
        case "missed": Badge(text: "Missed", tint: .orange)
        case "cancelled": Badge(text: "Cancelled", systemImage: "xmark", tint: .red)
        default: Badge(text: "Booked", systemImage: "calendar", tint: .blue)
        }
    }
}

struct AppointmentDetailView: View {
    let appointmentId: String
    @Environment(SyncEngine.self) private var sync
    @Environment(NetworkMonitor.self) private var network
    @Query private var items: [CachedItem]
    @Query private var pending: [PendingMutation]

    init(appointmentId: String) {
        self.appointmentId = appointmentId
        let pid = AppEnvironment.shared.profiles.activeProfileId ?? ""
        let key = CachedItem.key(profileId: pid, kind: CacheKind.appointment, entityId: appointmentId)
        _items = Query(filter: #Predicate<CachedItem> { $0.key == key })
        _pending = Query(filter: #Predicate<PendingMutation> {
            $0.profileId == pid && $0.type == "confirmAppointment" && $0.targetId == appointmentId && $0.state == "queued"
        })
    }

    var body: some View {
        if let a = items.first?.decode(Appointment.self) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        AppointmentStatusBadge(status: a.status)
                        Text(a.type).font(.title2.bold())
                        Text(a.startsAt, format: .dateTime.weekday(.wide).day().month(.wide))
                            .font(.title3)
                        Text(a.startsAt, format: .dateTime.hour().minute())
                            .font(.title3.weight(.semibold))
                        if !a.isMine && !a.personName.isEmpty {
                            Label("For \(a.personName)", systemImage: "person")
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Where") {
                    Label(a.location, systemImage: "mappin.and.ellipse")
                    if let url = URL(string: "maps://?q=\(a.location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"),
                       !network.isSatelliteMode {
                        Link(destination: url) { Label("Open in Maps", systemImage: "map") }
                    }
                }

                Section("Who") {
                    Label(a.provider.name, systemImage: "cross.case")
                    if let phone = a.provider.phone, let url = URL(string: "tel:\(phone.filter { !$0.isWhitespace })") {
                        Link(destination: url) { Label("Call \(phone)", systemImage: "phone") }
                    }
                }

                if let prep = a.prepNotes, !prep.isEmpty {
                    Section("Before you go") { Text(prep) }
                }
                if let transport = a.transportNote, !transport.isEmpty {
                    Section("Transport") { Label(transport, systemImage: "car") }
                }

                if a.isMine && (a.status == "booked" || a.status == "confirmed") && a.startsAt > .now.addingTimeInterval(-3600) {
                    Section {
                        if a.status == "confirmed" {
                            Label("You've confirmed you'll attend", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button {
                                sync.enqueue(.confirmAppointment(appointmentId: a.id))
                            } label: {
                                Label("Confirm I'll attend", systemImage: "checkmark.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                        if !pending.isEmpty {
                            Label(network.isOnline ? LocalizedStringKey("Sending…") : LocalizedStringKey("Saved on this phone. Will sync when you're back online."),
                                  systemImage: "clock.arrow.circlepath")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if !a.isMine {
                    Section {
                        Text("You can see this because \(a.personName.isEmpty ? String(localized: "this person") : a.personName) chose you as a carer. Only they or the clinic can change it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .localizedNavigationTitle("Appointment")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Appointment not available", systemImage: "calendar.badge.exclamationmark")
        }
    }
}
