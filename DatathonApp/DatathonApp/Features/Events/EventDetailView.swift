import SwiftData
import SwiftUI

struct EventDetailView: View {
    let eventId: String
    @Environment(SyncEngine.self) private var sync
    @Environment(ProfileStore.self) private var profiles
    @State private var error: String?
    @Query private var items: [CachedItem]
    @Query private var pendingRSVP: [PendingMutation]

    init(eventId: String) {
        self.eventId = eventId
        let pid = AppEnvironment.shared.profiles.activeProfileId ?? ""
        let key = CachedItem.key(profileId: pid, kind: CacheKind.event, entityId: eventId)
        _items = Query(filter: #Predicate<CachedItem> { $0.key == key })
        _pendingRSVP = Query(filter: #Predicate<PendingMutation> {
            $0.profileId == pid && $0.type == "rsvp" && $0.targetId == eventId && $0.state == "queued"
        })
    }

    var body: some View {
        if let event = items.first?.decode(Event.self) {
            content(event)
        } else {
            ContentUnavailableView("Event not available", systemImage: "calendar.badge.exclamationmark")
        }
    }

    private func content(_ event: Event) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if let category = event.category {
                        Badge(text: LocalizedStringKey(category.capitalized), tint: .teal)
                    }
                    Text(event.title).font(.title2.bold())
                    if event.cancelled {
                        Badge(text: "Cancelled", systemImage: "xmark.circle", tint: .red)
                    }
                    Label {
                        VStack(alignment: .leading) {
                            Text(event.startsAt, format: .dateTime.weekday(.wide).day().month(.wide))
                            HStack(spacing: 4) {
                                Text(event.startsAt, format: .dateTime.hour().minute())
                                if let end = event.endsAt {
                                    Text(verbatim: "–")
                                    Text(end, format: .dateTime.hour().minute())
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "clock") }
                    Label(event.location, systemImage: "mappin.and.ellipse")
                    if let provider = event.providerName {
                        Label(provider, systemImage: "cross.case")
                    }
                    if let d = event.description, !d.isEmpty {
                        Text(d).padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            }

            if !event.cancelled {
                Section {
                    Picker("Your RSVP", selection: Binding(
                        get: { event.myRsvp ?? "" },
                        set: { sync.enqueue(.rsvp(eventId: event.id, response: $0)) })) {
                        Text("Going").tag("going")
                        Text("Maybe").tag("maybe")
                        Text("Can't go").tag("no")
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 16) {
                        Text("\(event.rsvpCounts.going) going")
                        Text("\(event.rsvpCounts.maybe) maybe")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    if !pendingRSVP.isEmpty {
                        Label("Saved on this phone. Will send when you're back in coverage.", systemImage: "clock.arrow.circlepath")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Are you going?")
                }
            }

            if profiles.isElder(of: event.groupId) {
                ElderEventControls(event: event, error: $error)
            }
            if let error { Section { ErrorBanner(message: error) } }

            CommentsSection(target: .event(event.id), groupId: event.groupId,
                            commentsEnabled: event.commentsEnabled, threadLocked: event.threadLocked)
        }
        .localizedNavigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Elder per-event settings: comments on/off and lock thread.
private struct ElderEventControls: View {
    let event: Event
    @Binding var error: String?
    @Environment(AppEnvironment.self) private var env
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        Section {
            Toggle("Comments on", isOn: binding(\.commentsEnabled, field: "commentsEnabled"))
            Toggle("Lock thread", isOn: binding(\.threadLocked, field: "threadLocked"))
        } header: {
            Label("Elder controls", systemImage: "checkmark.shield")
        } footer: {
            if !network.isOnline || network.isSatelliteMode {
                Text("Elder controls need normal coverage.")
            }
        }
        .disabled(!network.isOnline || network.isSatelliteMode)
    }

    private func binding(_ keyPath: WritableKeyPath<Event, Bool>, field: String) -> Binding<Bool> {
        Binding(
            get: { event[keyPath: keyPath] },
            set: { newValue in
                var updated = event
                updated[keyPath: keyPath] = newValue
                save(updated)
                Task {
                    do {
                        let saved: Event = try await env.api.post("/api/events/\(event.id)/settings", [field: newValue])
                        save(saved)
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                        save(event)
                    }
                }
            })
    }

    private func save(_ e: Event) {
        guard let pid = env.profiles.activeProfileId else { return }
        env.cache.upsert(event: e, profileId: pid)
        try? env.container.mainContext.save()
    }
}
