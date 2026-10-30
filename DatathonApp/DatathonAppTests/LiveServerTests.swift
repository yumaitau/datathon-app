import Foundation
import SwiftData
import Testing
@testable import DatathonApp

/// Integration checks against the dev server on localhost:3000 using seeded demo accounts.
/// Each test returns early (and records why) when the server isn't running. They are written
/// to leave demo data as they found it.
@MainActor
struct LiveServerTests {
    static let baseURL = ProcessInfo.processInfo.environment["MYMOB_TEST_SERVER"] ?? "http://localhost:3000"

    private func client(token: String? = nil, log: NetworkLog? = nil) -> APIClient {
        APIClient(log: log ?? NetworkLog(), baseURL: { Self.baseURL }, tokenProvider: { token }, forceOffline: { false })
    }

    private func signIn(_ phone: String) async throws -> String? {
        let api = client()
        do {
            let _: OKResponse = try await api.post("/api/auth/otp/send", ["phoneNumber": phone])
        } catch APIError.offline {
            print("LiveServerTests skipped: server not reachable at \(Self.baseURL)")
            return nil
        }
        let auth: AuthResponse = try await api.post("/api/auth/otp/verify", ["phoneNumber": phone, "code": "123456"])
        return auth.token
    }

    @Test func reactionMutationIsIdempotentThroughSync() async throws {
        guard let token = try await signIn("+61400000001") else { return }
        let api = client(token: token)
        let me: Me = try await api.get("/api/me")
        let groupId = try #require(me.isElderOf.first)
        let feed: FeedResponse = try await api.get("/api/groups/\(groupId)/feed")
        let post = try #require(feed.posts.first)
        let before = post.reactions?.like ?? 0

        let first = SyncMutationDTO(clientMutationId: UUID().uuidString, type: "reaction",
                                    payload: QueuedMutation.reaction(targetType: "post", targetId: post.id, kind: "like").payload,
                                    createdAt: .now)
        let applied = try await api.fullSync(SyncRequest(cursor: nil, mutations: [first]))
        #expect(applied.results.first?.status == "applied")

        // Re-sending the same clientMutationId (a retried satellite batch) must not toggle again.
        let replay = try await api.fullSync(SyncRequest(cursor: applied.cursor, mutations: [first]))
        #expect(replay.results.first?.status == "duplicate")

        // Toggle back with a new id so the demo data is unchanged.
        let undo = SyncMutationDTO(clientMutationId: UUID().uuidString, type: "reaction", payload: first.payload, createdAt: .now)
        let undone = try await api.fullSync(SyncRequest(cursor: replay.cursor, mutations: [undo]))
        #expect(undone.results.first?.status == "applied")
        let after: FeedResponse = try await api.get("/api/groups/\(groupId)/feed")
        #expect(after.posts.first { $0.id == post.id }?.reactions?.like == before)
    }

    @Test func liteSyncUsesSatelliteSessionAndStaysSmall() async throws {
        guard let token = try await signIn("+61400000004") else { return }
        let log = NetworkLog()
        let api = client(token: token, log: log)
        let response = try await api.liteSync(SyncRequest(cursor: nil, mutations: []))
        #expect(response.lite == true)
        let entry = try #require(log.entries.first)
        #expect(entry.path == "/api/sync/lite")
        #expect(entry.lite)
        let payload = try #require(entry.payloadBytes)
        let compressed = try #require(entry.compressedBytes)
        #expect(compressed <= payload)
        #expect(compressed < 5 * 1024)
        print("lite sync: payload \(payload) B, gzip \(compressed) B, appointments \(response.appointments.count)")
    }

    @Test func fullSyncPopulatesCacheForPatient() async throws {
        guard let token = try await signIn("+61400000004") else { return }
        let container = try ModelContainer(for: CachedItem.self, PendingMutation.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = SyncEngine(context: container.mainContext, transport: client(token: token),
                                defaults: UserDefaults(suiteName: "live-\(UUID().uuidString)")!,
                                profileId: { "leah" }, isOnline: { true }, isSatellite: { false })
        await engine.flush()
        #expect(engine.lastError == nil)
        let appointments = CacheStore(context: container.mainContext).items(profileId: "leah", kind: CacheKind.appointment)
            .compactMap { $0.decode(Appointment.self) }
        #expect(!appointments.isEmpty)
        #expect(appointments.contains { $0.isMine })
    }
}
