import Foundation

// Wire types for the MyMob iOS API (server/docs/API.md). Optional fields follow the
// contract's `?` markers; a few extra optionals guard against fields the server may omit.

nonisolated struct User: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var phoneNumber: String
    var dateOfBirth: String?
    var gender: String?
}

nonisolated struct Membership: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var groupId: String
    var groupName: String
    var groupType: String
    var communityId: String?
    var role: String
    var status: String

    var isActive: Bool { status == "active" }
    var isPending: Bool { status == "pending" }
}

nonisolated struct Me: Codable, Hashable, Sendable {
    var user: User
    var memberships: [Membership]
    var isElderOf: [String]
}

nonisolated struct AuthResponse: Codable, Sendable {
    var token: String
    var user: User
}

nonisolated struct OKResponse: Codable, Sendable {
    var ok: Bool?
}

nonisolated struct PersonRef: Codable, Hashable, Sendable {
    var id: String
    var name: String
}

nonisolated struct ReactionCounts: Codable, Hashable, Sendable {
    var like: Int
    var heart: Int
    var thinkingOfYou: Int

    static let zero = ReactionCounts(like: 0, heart: 0, thinkingOfYou: 0)

    enum CodingKeys: String, CodingKey {
        case like, heart
        case thinkingOfYou = "thinking_of_you"
    }

    subscript(kind: ReactionKind) -> Int {
        get {
            switch kind {
            case .like: like
            case .heart: heart
            case .thinkingOfYou: thinkingOfYou
            }
        }
        set {
            switch kind {
            case .like: like = newValue
            case .heart: heart = newValue
            case .thinkingOfYou: thinkingOfYou = newValue
            }
        }
    }
}

nonisolated enum ReactionKind: String, CaseIterable, Codable, Sendable {
    case like
    case heart
    case thinkingOfYou = "thinking_of_you"
}

nonisolated struct GroupSummary: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var type: String
    var parentName: String?
    var memberCount: Int?
}

nonisolated struct Post: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var groupId: String
    var groupName: String?
    var author: PersonRef
    var kind: String
    var title: String?
    var body: String
    var hasMedia: Bool?
    /// Not in API.md; the dev server sends it alongside `hasMedia`.
    var imageUrl: String?
    var status: String
    var pinned: Bool
    var urgent: Bool?
    var restrictGender: String?
    var minAge: Int?
    var deceasedWarning: Bool
    var commentsEnabled: Bool
    var threadLocked: Bool
    var commentCount: Int?
    var reactions: ReactionCounts?
    var myReactions: [String]?
    var createdAt: Date
    var updatedAt: Date?

    var isPending: Bool { status == "pending" }
    var isSorryBusiness: Bool { kind == "sorry_business" }
}

nonisolated struct RSVPCounts: Codable, Hashable, Sendable {
    var going: Int
    var maybe: Int
    var no: Int
}

nonisolated struct Event: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var groupId: String
    var groupName: String?
    var title: String
    var description: String?
    var category: String?
    var startsAt: Date
    var endsAt: Date?
    var location: String
    var providerName: String?
    var cancelled: Bool
    var commentsEnabled: Bool
    var threadLocked: Bool
    var rsvpCounts: RSVPCounts
    var myRsvp: String?
    var commentCount: Int?
    var updatedAt: Date?
}

nonisolated struct FeedResponse: Codable, Sendable {
    var posts: [Post]
    var events: [Event]
}

nonisolated struct Comment: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var author: PersonRef
    var body: String
    var parentCommentId: String?
    var status: String
    var createdAt: Date
    var replies: [Comment]?
}

nonisolated struct ReactionResult: Codable, Sendable {
    var active: Bool
    var counts: ReactionCounts
}

nonisolated struct PendingMember: Codable, Hashable, Identifiable, Sendable {
    struct Person: Codable, Hashable, Sendable {
        var id: String
        var name: String
        var phoneNumber: String?
        var isMinor: Bool?
    }
    var id: String
    var user: Person
    var guardianConsent: Bool?
    var createdAt: Date
}

nonisolated struct ProviderRequest: Codable, Hashable, Identifiable, Sendable {
    struct Provider: Codable, Hashable, Sendable {
        var id: String
        var name: String
        var type: String?
        var address: String?
    }
    var id: String
    var provider: Provider
    var message: String?
    var status: String
    var createdAt: Date
}

nonisolated struct Report: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var reason: String
    var comment: Comment
    var createdAt: Date
}

nonisolated struct ModerationQueue: Codable, Sendable {
    var memberships: [PendingMember]
    var posts: [Post]
    var providerRequests: [ProviderRequest]
    var reports: [Report]
}

nonisolated struct ProviderRef: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var phone: String?
}

nonisolated struct Appointment: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var startsAt: Date
    var location: String
    var type: String
    var prepNotes: String?
    var transportNote: String?
    var status: String
    var provider: ProviderRef
    var personName: String
    var isMine: Bool
    var updatedAt: Date?
}

nonisolated struct AppointmentsResponse: Codable, Sendable {
    var mine: [Appointment]
    var caring: [Appointment]
}

nonisolated struct PatientInvite: Codable, Hashable, Identifiable, Sendable {
    struct Provider: Codable, Hashable, Sendable {
        var id: String
        var name: String
        var type: String?
    }
    var id: String
    var provider: Provider
    var status: String
    var createdAt: Date
}

nonisolated struct CarerLink: Codable, Hashable, Identifiable, Sendable {
    struct Carer: Codable, Hashable, Sendable {
        var id: String
        var name: String
        var phoneNumber: String?
    }
    var id: String
    var person: PersonRef
    var carer: Carer
    var status: String
    var consentedAt: Date?
    var revokedAt: Date?
}

nonisolated struct CarersPayload: Codable, Hashable, Sendable {
    var myCarers: [CarerLink]
    var caringFor: [CarerLink]
}

// MARK: - Sync

nonisolated struct SyncMutationDTO: Codable, Sendable {
    var clientMutationId: String
    var type: String
    var payload: JSONValue
    var createdAt: Date
}

nonisolated struct SyncRequest: Codable, Sendable {
    var cursor: String?
    var mutations: [SyncMutationDTO]
}

nonisolated struct MutationResult: Codable, Hashable, Sendable {
    var clientMutationId: String
    var status: String // applied | duplicate | rejected
    var entityId: String?
    var error: String?
}

nonisolated struct SyncResponse: Codable, Sendable {
    var cursor: String?
    var serverTime: Date?
    var results: [MutationResult]
    var appointments: [Appointment]?
    var posts: [Post]?
    var events: [Event]?
    var memberships: [Membership]?
    var carers: CarersPayload?
}

nonisolated struct LiteAppointment: Codable, Hashable, Sendable {
    var id: String
    var startsAt: Date
    var location: String
    var type: String
    var status: String
    var providerName: String?
    var isMine: Bool
    var updatedAt: Date?
}

nonisolated struct LiteNotice: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var groupId: String
    var kind: String
    var title: String?
    var body: String
    var createdAt: Date
}

nonisolated struct DeferredCounts: Codable, Hashable, Sendable {
    var posts: Int
    var events: Int
}

nonisolated struct LiteSyncResponse: Codable, Sendable {
    var cursor: String?
    var serverTime: Date?
    var lite: Bool?
    var results: [MutationResult]
    var appointments: [LiteAppointment]
    var notices: [LiteNotice]
    var deferred: DeferredCounts?
}

// MARK: - JSON helpers

/// Minimal JSON value so queued mutation payloads can be stored and replayed verbatim.
nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> String? {
        if case .object(let o) = self, case .string(let s)? = o[key] { return s }
        return nil
    }
}

nonisolated enum APIDate {
    static func parse(_ string: String) -> Date? {
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return d }
        return try? Date.ISO8601FormatStyle().parse(string)
    }

    static func format(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

extension JSONDecoder {
    nonisolated static var api: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = APIDate.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO 8601 date: \(s)")
            }
            return date
        }
        return d
    }
}

extension JSONEncoder {
    nonisolated static var api: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(APIDate.format(date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
