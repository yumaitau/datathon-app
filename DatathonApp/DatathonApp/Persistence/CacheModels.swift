import Foundation
import SwiftData

/// One cached server entity, stored as the JSON of its API type and scoped to a local profile.
/// Kinds: post, event, appointment, notice, comments, carers.
@Model
final class CachedItem {
    @Attribute(.unique) var key: String
    var profileId: String
    var kind: String
    var entityId: String
    var groupId: String?
    var sortDate: Date
    var payload: Data

    init(profileId: String, kind: String, entityId: String, groupId: String?, sortDate: Date, payload: Data) {
        key = CachedItem.key(profileId: profileId, kind: kind, entityId: entityId)
        self.profileId = profileId
        self.kind = kind
        self.entityId = entityId
        self.groupId = groupId
        self.sortDate = sortDate
        self.payload = payload
    }

    static func key(profileId: String, kind: String, entityId: String) -> String {
        "\(profileId)|\(kind)|\(entityId)"
    }

    func decode<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder.api.decode(type, from: payload)
    }
}

/// A queued write waiting for `/api/sync`. The `clientMutationId` is generated once and reused on
/// every retry, so a dropped connection never double-submits.
@Model
final class PendingMutation {
    @Attribute(.unique) var clientMutationId: String
    var profileId: String
    var type: String
    var payload: Data
    var createdAt: Date
    /// Mutations with the same key replace each other while still queued (e.g. the latest RSVP wins).
    var coalesceKey: String?
    /// The entity this write targets (appointment id, event id, local post id) for UI badges.
    var targetId: String?
    var attempts: Int
    var state: String // queued | rejected
    var lastError: String?

    init(profileId: String, mutation: QueuedMutation, createdAt: Date = .now, clientMutationId: String = UUID().uuidString) {
        self.clientMutationId = clientMutationId
        self.profileId = profileId
        type = mutation.type
        payload = (try? JSONEncoder.api.encode(mutation.payload)) ?? Data("{}".utf8)
        self.createdAt = createdAt
        coalesceKey = mutation.coalesceKey
        targetId = mutation.targetId
        attempts = 0
        state = "queued"
    }

    var payloadValue: JSONValue {
        (try? JSONDecoder.api.decode(JSONValue.self, from: payload)) ?? .object([:])
    }

    var dto: SyncMutationDTO {
        SyncMutationDTO(clientMutationId: clientMutationId, type: type, payload: payloadValue, createdAt: createdAt)
    }
}

/// Typed mutations matching the payloads in API.md "Sync".
enum QueuedMutation: Equatable {
    case rsvp(eventId: String, response: String)
    case confirmAppointment(appointmentId: String)
    case createPost(groupId: String, body: String, title: String?, kind: String?)
    case createComment(postId: String?, eventId: String?, parentCommentId: String?, body: String)
    case reaction(targetType: String, targetId: String, kind: String)

    var type: String {
        switch self {
        case .rsvp: "rsvp"
        case .confirmAppointment: "confirmAppointment"
        case .createPost: "createPost"
        case .createComment: "createComment"
        case .reaction: "reaction"
        }
    }

    var payload: JSONValue {
        var o: [String: JSONValue] = [:]
        switch self {
        case let .rsvp(eventId, response):
            o["eventId"] = .string(eventId); o["response"] = .string(response)
        case let .confirmAppointment(id):
            o["appointmentId"] = .string(id)
        case let .createPost(groupId, body, title, kind):
            o["groupId"] = .string(groupId); o["body"] = .string(body)
            if let title { o["title"] = .string(title) }
            if let kind { o["kind"] = .string(kind) }
        case let .createComment(postId, eventId, parentCommentId, body):
            if let postId { o["postId"] = .string(postId) }
            if let eventId { o["eventId"] = .string(eventId) }
            if let parentCommentId { o["parentCommentId"] = .string(parentCommentId) }
            o["body"] = .string(body)
        case let .reaction(targetType, targetId, kind):
            o["targetType"] = .string(targetType); o["targetId"] = .string(targetId); o["kind"] = .string(kind)
        }
        return .object(o)
    }

    var coalesceKey: String? {
        switch self {
        case let .rsvp(eventId, _): "rsvp:\(eventId)"
        case let .confirmAppointment(id): "confirm:\(id)"
        default: nil
        }
    }

    var targetId: String? {
        switch self {
        case let .rsvp(eventId, _): eventId
        case let .confirmAppointment(id): id
        case let .createComment(postId, eventId, _, _): postId ?? eventId
        case let .reaction(_, targetId, _): targetId
        case .createPost: nil
        }
    }
}

enum CacheKind {
    static let post = "post"
    static let event = "event"
    static let appointment = "appointment"
    static let notice = "notice"
    static let comments = "comments"
    static let carers = "carers"
}

/// Read/write helpers over the SwiftData cache.
struct CacheStore {
    let context: ModelContext

    func item(profileId: String, kind: String, id: String) -> CachedItem? {
        let key = CachedItem.key(profileId: profileId, kind: kind, entityId: id)
        var d = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.key == key })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func value<T: Decodable>(_ type: T.Type, profileId: String, kind: String, id: String) -> T? {
        item(profileId: profileId, kind: kind, id: id)?.decode(type)
    }

    func items(profileId: String, kind: String) -> [CachedItem] {
        let d = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.profileId == profileId && $0.kind == kind })
        return (try? context.fetch(d)) ?? []
    }

    func upsert<T: Encodable>(_ value: T, profileId: String, kind: String, id: String, groupId: String? = nil, sortDate: Date) {
        guard let data = try? JSONEncoder.api.encode(value) else { return }
        if let existing = item(profileId: profileId, kind: kind, id: id) {
            existing.payload = data
            existing.sortDate = sortDate
            existing.groupId = groupId
        } else {
            context.insert(CachedItem(profileId: profileId, kind: kind, entityId: id, groupId: groupId, sortDate: sortDate, payload: data))
        }
    }

    func delete(profileId: String, kind: String, id: String) {
        if let i = item(profileId: profileId, kind: kind, id: id) { context.delete(i) }
    }

    func upsert(post: Post, profileId: String) {
        upsert(post, profileId: profileId, kind: CacheKind.post, id: post.id, groupId: post.groupId, sortDate: post.createdAt)
    }

    func upsert(event: Event, profileId: String) {
        upsert(event, profileId: profileId, kind: CacheKind.event, id: event.id, groupId: event.groupId, sortDate: event.startsAt)
    }

    func upsert(appointment: Appointment, profileId: String) {
        upsert(appointment, profileId: profileId, kind: CacheKind.appointment, id: appointment.id, sortDate: appointment.startsAt)
    }

    /// Replace a group's cached feed with a fresh server copy, keeping locally queued pending posts.
    func replaceFeed(_ feed: FeedResponse, groupId: String, profileId: String) {
        let incoming = Set(feed.posts.map(\.id))
        for item in items(profileId: profileId, kind: CacheKind.post) where item.groupId == groupId {
            let isLocalPending = item.entityId.hasPrefix("local-") || (item.decode(Post.self)?.isPending ?? false)
            if !incoming.contains(item.entityId) && !isLocalPending { context.delete(item) }
        }
        for item in items(profileId: profileId, kind: CacheKind.event) where item.groupId == groupId {
            if !feed.events.contains(where: { $0.id == item.entityId }) { context.delete(item) }
        }
        feed.posts.forEach { upsert(post: $0, profileId: profileId) }
        feed.events.forEach { upsert(event: $0, profileId: profileId) }
    }

    func deleteAll(profileId: String) {
        try? context.delete(model: CachedItem.self, where: #Predicate { $0.profileId == profileId })
        try? context.delete(model: PendingMutation.self, where: #Predicate { $0.profileId == profileId })
    }
}
