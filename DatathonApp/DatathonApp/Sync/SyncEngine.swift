import Foundation
import Observation
import SwiftData

protocol SyncTransport {
    func fullSync(_ request: SyncRequest) async throws -> SyncResponse
    func liteSync(_ request: SyncRequest) async throws -> LiteSyncResponse
}

/// Offline-first write queue and delta sync.
///
/// Writes are applied optimistically to the local cache, stored as `PendingMutation`s and flushed in
/// one batch to `/api/sync` (or `/api/sync/lite` in satellite mode). Each mutation keeps its
/// `clientMutationId` across retries; the server answers `duplicate` for anything it already applied.
@Observable
final class SyncEngine {
    private(set) var isSyncing = false
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    private(set) var deferred: DeferredCounts?
    /// Bumped when memberships arrive from a full sync so the profile store can refresh `Me`.
    private(set) var membershipsFromSync: [Membership]?

    @ObservationIgnored private var flushRequested = false
    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let transport: SyncTransport
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var profileId: () -> String?
    @ObservationIgnored var currentUser: () -> PersonRef?
    @ObservationIgnored var isOnline: () -> Bool
    @ObservationIgnored var isSatellite: () -> Bool

    private var cache: CacheStore { CacheStore(context: context) }

    init(context: ModelContext,
         transport: SyncTransport,
         defaults: UserDefaults = .standard,
         profileId: @escaping () -> String?,
         currentUser: @escaping () -> PersonRef? = { nil },
         isOnline: @escaping () -> Bool,
         isSatellite: @escaping () -> Bool) {
        self.context = context
        self.transport = transport
        self.defaults = defaults
        self.profileId = profileId
        self.currentUser = currentUser
        self.isOnline = isOnline
        self.isSatellite = isSatellite
    }

    // MARK: Queue

    /// Queue a write, apply it locally, and try to send it straight away.
    @discardableResult
    func enqueue(_ mutation: QueuedMutation, flushNow: Bool = true) -> PendingMutation? {
        guard let pid = profileId() else { return nil }
        if let key = mutation.coalesceKey {
            for old in queued(profileId: pid) where old.coalesceKey == key { context.delete(old) }
        }
        let pending = PendingMutation(profileId: pid, mutation: mutation)
        context.insert(pending)
        applyOptimistically(mutation, clientMutationId: pending.clientMutationId, profileId: pid)
        try? context.save()
        if flushNow { Task { await flush() } }
        return pending
    }

    func queued(profileId: String) -> [PendingMutation] {
        let d = FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.profileId == profileId && $0.state == "queued" },
            sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(d)) ?? []
    }

    func discard(_ mutation: PendingMutation) {
        context.delete(mutation)
        try? context.save()
    }

    // MARK: Flush

    func flush() async {
        guard !isSyncing else {
            // A sync is in flight (e.g. user tapped "Sync now", or satellite mode switched on);
            // run one more pass when it finishes rather than dropping the request.
            flushRequested = true
            return
        }
        guard let pid = profileId(), isOnline() else { return }
        isSyncing = true
        defer { isSyncing = false }

        // Writes queued while a request is in flight go out in a follow-up batch.
        for _ in 0..<3 {
            flushRequested = false
            let batch = queued(profileId: pid)
            let ok = await sendBatch(batch, profileId: pid)
            guard ok, profileId() == pid else { break }
            if queued(profileId: pid).isEmpty && !flushRequested { break }
        }
    }

    private func sendBatch(_ batch: [PendingMutation], profileId pid: String) async -> Bool {
        batch.forEach { $0.attempts += 1 }
        let satellite = isSatellite()
        do {
            if satellite {
                let cursor = defaults.string(forKey: liteCursorKey(pid)) ?? defaults.string(forKey: fullCursorKey(pid))
                let response = try await transport.liteSync(SyncRequest(cursor: cursor, mutations: batch.map(\.dto)))
                apply(results: response.results, batch: batch, profileId: pid)
                mergeLite(response, profileId: pid)
                if let c = response.cursor { defaults.set(c, forKey: liteCursorKey(pid)) }
            } else {
                let cursor = defaults.string(forKey: fullCursorKey(pid))
                let response = try await transport.fullSync(SyncRequest(cursor: cursor, mutations: batch.map(\.dto)))
                apply(results: response.results, batch: batch, profileId: pid)
                mergeFull(response, profileId: pid)
                if let c = response.cursor { defaults.set(c, forKey: fullCursorKey(pid)) }
                // A full sync catches up on everything the lite path deferred.
                defaults.removeObject(forKey: liteCursorKey(pid))
                deferred = nil
            }
            lastSyncAt = .now
            lastError = nil
            try? context.save()
            return true
        } catch {
            // Keep every mutation queued with its original clientMutationId for the next attempt.
            lastError = APIClient.map(error).localizedDescription
            try? context.save()
            return false
        }
    }

    func apply(results: [MutationResult], batch: [PendingMutation], profileId pid: String) {
        let byId = Dictionary(batch.map { ($0.clientMutationId, $0) }, uniquingKeysWith: { a, _ in a })
        for result in results {
            guard let mutation = byId[result.clientMutationId] else { continue }
            switch result.status {
            case "applied", "duplicate":
                if mutation.type == "createPost", let entityId = result.entityId {
                    rekeyLocalPost(clientMutationId: mutation.clientMutationId, to: entityId, profileId: pid)
                }
                context.delete(mutation)
            default:
                mutation.state = "rejected"
                mutation.lastError = result.error
                if mutation.type == "createPost" {
                    cache.delete(profileId: pid, kind: CacheKind.post, id: "local-\(mutation.clientMutationId)")
                }
            }
        }
    }

    func mergeFull(_ r: SyncResponse, profileId pid: String) {
        r.appointments?.forEach { cache.upsert(appointment: $0, profileId: pid) }
        r.posts?.forEach { cache.upsert(post: $0, profileId: pid) }
        removePosts(r.removedPostIds, profileId: pid)
        r.events?.forEach { cache.upsert(event: $0, profileId: pid) }
        if let carers = r.carers {
            cache.upsert(carers, profileId: pid, kind: CacheKind.carers, id: "carers", sortDate: .now)
        }
        if let m = r.memberships { membershipsFromSync = m }
    }

    func mergeLite(_ r: LiteSyncResponse, profileId pid: String) {
        for lite in r.appointments {
            var appt = cache.value(Appointment.self, profileId: pid, kind: CacheKind.appointment, id: lite.id)
                ?? Appointment(id: lite.id, startsAt: lite.startsAt, location: lite.location, type: lite.type,
                               prepNotes: nil, transportNote: nil, status: lite.status,
                               provider: ProviderRef(id: "", name: lite.providerName ?? "", phone: nil),
                               personName: "", isMine: lite.isMine, updatedAt: lite.updatedAt)
            appt.startsAt = lite.startsAt
            appt.location = lite.location
            appt.type = lite.type
            appt.status = lite.status
            appt.isMine = lite.isMine
            appt.updatedAt = lite.updatedAt
            if let name = lite.providerName { appt.provider.name = name }
            cache.upsert(appointment: appt, profileId: pid)
        }
        for notice in r.notices {
            cache.upsert(notice, profileId: pid, kind: CacheKind.notice, id: notice.id, groupId: notice.groupId, sortDate: notice.createdAt)
        }
        removePosts(r.removedPostIds, profileId: pid)
        deferred = r.deferred
    }

    /// Archived sorry business and rejected posts leave the offline cache, as posts and notices.
    private func removePosts(_ ids: [String]?, profileId pid: String) {
        for id in ids ?? [] {
            cache.delete(profileId: pid, kind: CacheKind.post, id: id)
            cache.delete(profileId: pid, kind: CacheKind.notice, id: id)
        }
    }

    func resetCursors(profileId pid: String) {
        defaults.removeObject(forKey: fullCursorKey(pid))
        defaults.removeObject(forKey: liteCursorKey(pid))
    }

    private func fullCursorKey(_ pid: String) -> String { "cursor.full.\(pid)" }
    private func liteCursorKey(_ pid: String) -> String { "cursor.lite.\(pid)" }

    // MARK: Optimistic local apply

    private func applyOptimistically(_ mutation: QueuedMutation, clientMutationId: String, profileId pid: String) {
        switch mutation {
        case let .rsvp(eventId, response):
            guard var event = cache.value(Event.self, profileId: pid, kind: CacheKind.event, id: eventId) else { return }
            if let old = event.myRsvp { event.rsvpCounts.adjust(old, by: -1) }
            event.rsvpCounts.adjust(response, by: 1)
            event.myRsvp = response
            cache.upsert(event: event, profileId: pid)

        case let .confirmAppointment(id):
            guard var appt = cache.value(Appointment.self, profileId: pid, kind: CacheKind.appointment, id: id) else { return }
            appt.status = "confirmed"
            cache.upsert(appointment: appt, profileId: pid)

        case let .createPost(groupId, body, title, kind, options):
            let author = currentUser() ?? PersonRef(id: "me", name: String(localized: "You"))
            let post = Post(id: "local-\(clientMutationId)", groupId: groupId, groupName: nil, author: author,
                            kind: kind ?? "announcement", title: title, body: body, hasMedia: false, imageUrl: nil,
                            status: "pending", pinned: false, urgent: options.urgent, restrictGender: options.restrictGender,
                            minAge: options.minAge, deceasedWarning: options.deceasedWarning,
                            commentsEnabled: kind != "sorry_business", threadLocked: false, commentCount: 0,
                            reactions: .zero, myReactions: [], createdAt: .now, updatedAt: .now)
            cache.upsert(post: post, profileId: pid)

        case let .reaction(targetType, targetId, kindRaw):
            guard targetType == "post", let kind = ReactionKind(rawValue: kindRaw),
                  var post = cache.value(Post.self, profileId: pid, kind: CacheKind.post, id: targetId) else { return }
            var counts = post.reactions ?? .zero
            var mine = post.myReactions ?? []
            if let i = mine.firstIndex(of: kindRaw) {
                mine.remove(at: i); counts[kind] = max(0, counts[kind] - 1)
            } else {
                mine.append(kindRaw); counts[kind] += 1
            }
            post.reactions = counts
            post.myReactions = mine
            cache.upsert(post: post, profileId: pid)

        case .createComment:
            break // shown from the queue itself until the thread is refetched
        }
    }

    private func rekeyLocalPost(clientMutationId: String, to entityId: String, profileId pid: String) {
        let localId = "local-\(clientMutationId)"
        guard var post = cache.value(Post.self, profileId: pid, kind: CacheKind.post, id: localId) else { return }
        cache.delete(profileId: pid, kind: CacheKind.post, id: localId)
        if cache.item(profileId: pid, kind: CacheKind.post, id: entityId) == nil {
            post.id = entityId
            cache.upsert(post: post, profileId: pid)
        }
    }
}

extension RSVPCounts {
    mutating func adjust(_ response: String, by delta: Int) {
        switch response {
        case "going": going = max(0, going + delta)
        case "maybe": maybe = max(0, maybe + delta)
        case "no": no = max(0, no + delta)
        default: break
        }
    }
}
