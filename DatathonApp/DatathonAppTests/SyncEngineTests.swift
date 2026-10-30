import Foundation
import SwiftData
import Testing
@testable import DatathonApp

/// Scripted transport: records every request and replays queued outcomes.
final class FakeTransport: SyncTransport {
    enum Outcome {
        case full(SyncResponse)
        case lite(LiteSyncResponse)
        case fail(Error)
    }

    var outcomes: [Outcome] = []
    private(set) var fullRequests: [SyncRequest] = []
    private(set) var liteRequests: [SyncRequest] = []

    func fullSync(_ request: SyncRequest) async throws -> SyncResponse {
        fullRequests.append(request)
        switch outcomes.removeFirst() {
        case .full(let r): return r
        case .fail(let e): throw e
        case .lite: fatalError("expected full sync")
        }
    }

    func liteSync(_ request: SyncRequest) async throws -> LiteSyncResponse {
        liteRequests.append(request)
        switch outcomes.removeFirst() {
        case .lite(let r): return r
        case .fail(let e): throw e
        case .full: fatalError("expected lite sync")
        }
    }
}

@MainActor
final class SyncHarness {
    let container: ModelContainer
    let transport = FakeTransport()
    let engine: SyncEngine
    var online = true
    var satellite = false
    let profileId = "profile-1"

    init() throws {
        container = try ModelContainer(for: CachedItem.self, PendingMutation.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let defaults = UserDefaults(suiteName: "tests-\(UUID().uuidString)")!
        var engineRef: SyncEngine!
        engineRef = SyncEngine(context: container.mainContext, transport: transport, defaults: defaults,
                               profileId: { "profile-1" }, currentUser: { PersonRef(id: "u1", name: "Jordan") },
                               isOnline: { true }, isSatellite: { false })
        engine = engineRef
        engine.isOnline = { [unowned self] in self.online }
        engine.isSatellite = { [unowned self] in self.satellite }
    }

    var cache: CacheStore { CacheStore(context: container.mainContext) }
    var queued: [PendingMutation] { engine.queued(profileId: profileId) }

    func seedAppointment(id: String = "a1", status: String = "booked", prepNotes: String? = "Bring Medicare card") {
        cache.upsert(appointment: Appointment(
            id: id, startsAt: .now.addingTimeInterval(86_400), location: "Saltbush Clinic", type: "715 health check",
            prepNotes: prepNotes, transportNote: nil, status: status,
            provider: ProviderRef(id: "prov", name: "Saltbush Clinic", phone: nil),
            personName: "Leah", isMine: true, updatedAt: nil), profileId: profileId)
    }

    func seedEvent(id: String = "e1", myRsvp: String? = nil, counts: RSVPCounts = RSVPCounts(going: 5, maybe: 2, no: 0)) {
        cache.upsert(event: Event(
            id: id, groupId: "g1", groupName: nil, title: "NAIDOC lunch", description: nil, category: "cultural",
            startsAt: .now.addingTimeInterval(3600), endsAt: nil, location: "Hall", providerName: nil, cancelled: false,
            commentsEnabled: true, threadLocked: false, rsvpCounts: counts, myRsvp: myRsvp, commentCount: 0, updatedAt: nil),
            profileId: profileId)
    }

    static func fullResponse(_ results: [MutationResult], appointments: [Appointment]? = nil, cursor: String = "c1") -> SyncResponse {
        SyncResponse(cursor: cursor, serverTime: .now, results: results, appointments: appointments,
                     posts: nil, events: nil, memberships: nil, carers: nil)
    }
}

@MainActor
struct SyncEngineTests {
    @Test func offlineConfirmIsQueuedAndAppliedLocally() throws {
        let h = try SyncHarness()
        h.online = false
        h.seedAppointment()

        h.engine.enqueue(.confirmAppointment(appointmentId: "a1"), flushNow: false)

        #expect(h.queued.count == 1)
        #expect(h.queued.first?.type == "confirmAppointment")
        #expect(h.queued.first?.payloadValue["appointmentId"] == "a1")
        let appt = h.cache.value(Appointment.self, profileId: h.profileId, kind: CacheKind.appointment, id: "a1")
        #expect(appt?.status == "confirmed")
    }

    @Test func flushDoesNothingWhileOffline() async throws {
        let h = try SyncHarness()
        h.online = false
        h.engine.enqueue(.confirmAppointment(appointmentId: "a1"), flushNow: false)
        await h.engine.flush()
        #expect(h.transport.fullRequests.isEmpty)
        #expect(h.queued.count == 1)
    }

    @Test func droppedRequestRetriesWithSameIdAndDuplicateClearsQueue() async throws {
        let h = try SyncHarness()
        h.seedAppointment()
        let pending = try #require(h.engine.enqueue(.confirmAppointment(appointmentId: "a1"), flushNow: false))
        let id = pending.clientMutationId

        // First attempt: the connection drops after the server may have applied it.
        h.transport.outcomes = [.fail(URLError(.networkConnectionLost))]
        await h.engine.flush()
        #expect(h.queued.map(\.clientMutationId) == [id])
        #expect(h.queued.first?.attempts == 1)
        #expect(h.engine.lastError != nil)

        // Retry: same clientMutationId; server reports it as a duplicate, so nothing is applied twice.
        h.transport.outcomes = [.full(SyncHarness.fullResponse([MutationResult(clientMutationId: id, status: "duplicate", entityId: "a1", error: nil)]))]
        await h.engine.flush()

        #expect(h.transport.fullRequests.count == 2)
        #expect(h.transport.fullRequests.map { $0.mutations.map(\.clientMutationId) } == [[id], [id]])
        #expect(h.queued.isEmpty)
        #expect(h.engine.lastError == nil)
    }

    @Test func cursorFromResponseIsSentOnNextSync() async throws {
        let h = try SyncHarness()
        h.transport.outcomes = [.full(SyncHarness.fullResponse([], cursor: "c-1")), .full(SyncHarness.fullResponse([], cursor: "c-2"))]
        await h.engine.flush()
        await h.engine.flush()
        #expect(h.transport.fullRequests.map(\.cursor) == [nil, "c-1"])
    }

    @Test func serverWinsForAppointmentsInFullSync() async throws {
        let h = try SyncHarness()
        h.seedAppointment()
        h.engine.enqueue(.confirmAppointment(appointmentId: "a1"), flushNow: false)
        let id = try #require(h.queued.first?.clientMutationId)
        var cancelled = try #require(h.cache.value(Appointment.self, profileId: h.profileId, kind: CacheKind.appointment, id: "a1"))
        cancelled.status = "cancelled"
        h.transport.outcomes = [.full(SyncHarness.fullResponse(
            [MutationResult(clientMutationId: id, status: "rejected", entityId: nil, error: "Appointment cancelled")],
            appointments: [cancelled]))]

        await h.engine.flush()

        #expect(h.cache.value(Appointment.self, profileId: h.profileId, kind: CacheKind.appointment, id: "a1")?.status == "cancelled")
        #expect(h.queued.isEmpty)
        let rejected = try h.container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        #expect(rejected.first?.state == "rejected")
        #expect(rejected.first?.lastError == "Appointment cancelled")
    }

    @Test func latestRSVPReplacesQueuedOneAndCountsStayConsistent() throws {
        let h = try SyncHarness()
        h.online = false
        h.seedEvent()

        h.engine.enqueue(.rsvp(eventId: "e1", response: "going"), flushNow: false)
        h.engine.enqueue(.rsvp(eventId: "e1", response: "maybe"), flushNow: false)

        #expect(h.queued.count == 1)
        #expect(h.queued.first?.payloadValue["response"] == "maybe")
        let event = try #require(h.cache.value(Event.self, profileId: h.profileId, kind: CacheKind.event, id: "e1"))
        #expect(event.myRsvp == "maybe")
        #expect(event.rsvpCounts == RSVPCounts(going: 5, maybe: 3, no: 0))
    }

    @Test func offlinePostShowsAsPendingThenTakesServerId() async throws {
        let h = try SyncHarness()
        h.online = false
        let pending = try #require(h.engine.enqueue(.createPost(groupId: "g1", body: "Footy training moved", title: nil, kind: "announcement"), flushNow: false))
        let localId = "local-\(pending.clientMutationId)"
        let local = try #require(h.cache.value(Post.self, profileId: h.profileId, kind: CacheKind.post, id: localId))
        #expect(local.isPending)
        #expect(local.author.name == "Jordan")

        h.online = true
        h.transport.outcomes = [.full(SyncHarness.fullResponse([MutationResult(clientMutationId: pending.clientMutationId, status: "applied", entityId: "post-99", error: nil)]))]
        await h.engine.flush()

        #expect(h.cache.item(profileId: h.profileId, kind: CacheKind.post, id: localId) == nil)
        let synced = try #require(h.cache.value(Post.self, profileId: h.profileId, kind: CacheKind.post, id: "post-99"))
        #expect(synced.isPending)
        #expect(synced.body == "Footy training moved")
    }

    @Test func offlineElderPostKeepsFlagsAndRestrictions() throws {
        let h = try SyncHarness()
        h.online = false
        let options = PostOptions(urgent: true, deceasedWarning: true, restrictGender: "female", minAge: 18)
        let pending = try #require(h.engine.enqueue(.createPost(groupId: "g1", body: "Women's business at the hall",
                                                                title: nil, kind: "announcement", options: options), flushNow: false))
        // The queued payload carries every flag, so nothing is lost if it sends later.
        guard case .object(let payload) = pending.dto.payload else { Issue.record("payload not an object"); return }
        #expect(payload["urgent"] == .bool(true))
        #expect(payload["deceasedWarning"] == .bool(true))
        #expect(payload["restrictGender"] == .string("female"))
        #expect(payload["minAge"] == .number(18))
        // And the local copy reflects them while it waits.
        let local = try #require(h.cache.value(Post.self, profileId: h.profileId, kind: CacheKind.post, id: "local-\(pending.clientMutationId)"))
        #expect(local.urgent == true && local.deceasedWarning)
        #expect(local.restrictGender == "female" && local.minAge == 18)
    }

    @Test func removedPostsLeaveTheOfflineCache() async throws {
        let h = try SyncHarness()
        let json = """
        {"id":"p1","groupId":"g1","author":{"id":"u2","name":"Aunty Grace"},"kind":"sorry_business","body":"Sorry business",
         "status":"published","pinned":false,"deceasedWarning":true,"commentsEnabled":false,"threadLocked":false,
         "createdAt":"2026-10-20T01:00:00.000Z"}
        """
        h.cache.upsert(post: try JSONDecoder.api.decode(Post.self, from: Data(json.utf8)), profileId: h.profileId)
        #expect(h.cache.item(profileId: h.profileId, kind: CacheKind.post, id: "p1") != nil)

        var response = SyncHarness.fullResponse([])
        response.removedPostIds = ["p1"]
        h.transport.outcomes = [.full(response)]
        await h.engine.flush()

        #expect(h.cache.item(profileId: h.profileId, kind: CacheKind.post, id: "p1") == nil)
    }

    @Test func satelliteModeUsesLiteSyncAndKeepsDetailFields() async throws {
        let h = try SyncHarness()
        h.satellite = true
        h.seedAppointment(prepNotes: "Fast from midnight")
        let pending = try #require(h.engine.enqueue(.confirmAppointment(appointmentId: "a1"), flushNow: false))
        h.transport.outcomes = [.lite(LiteSyncResponse(
            cursor: "lite-1", serverTime: .now, lite: true,
            results: [MutationResult(clientMutationId: pending.clientMutationId, status: "applied", entityId: "a1", error: nil)],
            appointments: [LiteAppointment(id: "a1", startsAt: .now.addingTimeInterval(7200), location: "Mobile clinic",
                                           type: "715 health check", status: "confirmed", providerName: "Saltbush Clinic",
                                           isMine: true, updatedAt: .now)],
            notices: [LiteNotice(id: "n1", groupId: "g1", kind: "urgent", title: nil, body: "Road closed", createdAt: .now)],
            deferred: DeferredCounts(posts: 3, events: 1)))]

        await h.engine.flush()

        #expect(h.transport.fullRequests.isEmpty)
        #expect(h.transport.liteRequests.count == 1)
        #expect(h.queued.isEmpty)
        let appt = try #require(h.cache.value(Appointment.self, profileId: h.profileId, kind: CacheKind.appointment, id: "a1"))
        #expect(appt.location == "Mobile clinic")
        #expect(appt.prepNotes == "Fast from midnight")
        #expect(h.cache.items(profileId: h.profileId, kind: CacheKind.notice).count == 1)
        #expect(h.engine.deferred == DeferredCounts(posts: 3, events: 1))
    }

    @Test func profilesHaveSeparateQueues() throws {
        let h = try SyncHarness()
        h.online = false
        h.engine.enqueue(.confirmAppointment(appointmentId: "a1"), flushNow: false)
        #expect(h.engine.queued(profileId: "someone-else").isEmpty)
        #expect(h.engine.queued(profileId: h.profileId).count == 1)
    }
}
