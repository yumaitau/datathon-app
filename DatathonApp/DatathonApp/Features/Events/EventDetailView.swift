import SwiftData
import SwiftUI

struct EventDetailView: View {
    let eventId: String
    @Environment(SyncEngine.self) private var sync
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

            CommentsSection(target: .event(event.id), groupId: event.groupId,
                            commentsEnabled: event.commentsEnabled, threadLocked: event.threadLocked)
        }
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
    }
}
