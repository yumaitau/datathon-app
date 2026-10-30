import Foundation
import Testing
@testable import DatathonApp

@MainActor
struct DecodingTests {
    @Test func parsesISODatesWithAndWithoutFractionalSeconds() throws {
        let withMillis = try #require(APIDate.parse("2026-11-02T00:30:00.000Z"))
        let without = try #require(APIDate.parse("2026-11-02T00:30:00Z"))
        #expect(withMillis == without)
        #expect(withMillis.timeIntervalSince1970 == 1_793_579_400)
        #expect(APIDate.parse("02/11/2026") == nil)
        #expect(APIDate.format(withMillis) == "2026-11-02T00:30:00.000Z")
    }

    @Test func decodesPostWithReactionsAndOptionalFields() throws {
        let json = """
        {"id":"p1","groupId":"g1","groupName":"Saltbush Creek","author":{"id":"u1","name":"Aunty Grace"},
         "kind":"announcement","body":"Bush tucker walk Saturday","hasMedia":true,"status":"published",
         "pinned":true,"urgent":false,"deceasedWarning":true,"commentsEnabled":true,"threadLocked":false,
         "commentCount":2,"reactions":{"like":3,"heart":1,"thinking_of_you":4},"myReactions":["heart"],
         "createdAt":"2026-10-30T01:02:03.456Z","updatedAt":"2026-10-30T01:02:03.456Z"}
        """
        let post = try JSONDecoder.api.decode(Post.self, from: Data(json.utf8))
        #expect(post.reactions?.thinkingOfYou == 4)
        #expect(post.reactions?[.like] == 3)
        #expect(post.title == nil)
        #expect(post.deceasedWarning)
        #expect(post.myReactions == ["heart"])
    }

    @Test func decodesLiteSyncResponse() throws {
        let json = """
        {"cursor":"c2","serverTime":"2026-10-30T01:00:00.000Z","lite":true,
         "results":[{"clientMutationId":"m1","status":"duplicate","entityId":"a1"}],
         "appointments":[{"id":"a1","startsAt":"2026-11-02T00:30:00.000Z","location":"Clinic","type":"715 health check",
                          "status":"confirmed","providerName":"Saltbush Clinic","isMine":true,"updatedAt":"2026-10-30T01:00:00.000Z"}],
         "notices":[{"id":"n1","groupId":"g1","kind":"sorry_business","body":"Sorry business notice","createdAt":"2026-10-29T01:00:00.000Z"}],
         "deferred":{"posts":4,"events":1}}
        """
        let r = try JSONDecoder.api.decode(LiteSyncResponse.self, from: Data(json.utf8))
        #expect(r.results.first?.status == "duplicate")
        #expect(r.appointments.first?.providerName == "Saltbush Clinic")
        #expect(r.notices.first?.title == nil)
        #expect(r.deferred == DeferredCounts(posts: 4, events: 1))
    }

    @Test func mutationRequestEncodesContractShape() throws {
        let mutation = QueuedMutation.createComment(postId: "p1", eventId: nil, parentCommentId: nil, body: "Thank you")
        let dto = SyncMutationDTO(clientMutationId: "m1", type: mutation.type, payload: mutation.payload,
                                  createdAt: try #require(APIDate.parse("2026-10-30T00:00:00.000Z")))
        let data = try JSONEncoder.api.encode(SyncRequest(cursor: nil, mutations: [dto]))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let first = try #require((object["mutations"] as? [[String: Any]])?.first)
        #expect(first["type"] as? String == "createComment")
        #expect(first["createdAt"] as? String == "2026-10-30T00:00:00.000Z")
        #expect(first["payload"] as? [String: String] == ["postId": "p1", "body": "Thank you"])
        #expect(object["cursor"] == nil)
    }

    @Test func normalisesAustralianMobileNumbers() {
        #expect(normalizePhone("0400 000 003") == "+61400000003")
        #expect(normalizePhone("61400000003") == "+61400000003")
        #expect(normalizePhone("+61 400 000 003") == "+61400000003")
    }
}
