import Foundation
import Testing

@testable import FountainKit

@Suite struct ConversationWireTests {
  @Test func omissionNullAndValuesRemainDistinct() throws {
    var request = ConversationCreateRequest(agentID: "a1", prompt: "hello", title: "", fresh: false)
    request.labels = [:]
    request.images = []
    request.permissionPolicyValues = ["ask_timeout": .number(0), "shell": .string("ask")]
    request.setNull(.vaultID)
    request.setNull(.queue)
    let body = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
    #expect(body["environment_id"] == nil)
    #expect(body["vault_id"] == .null)
    #expect(body["queue"] == .null)
    #expect(body["fresh"] == .bool(false))
    #expect(body["title"] == .string(""))
    #expect(body["images"] == .array([]))
    #expect(body["labels"] == .object([:]))
    #expect(body["permission_policy"]?["ask_timeout"] == .number(0))
    request.vaultID = "vault"
    #expect(try encoded(request)["vault_id"] == .string("vault"))
    request.setNull(.vaultID)
    request.vaultID = nil
    #expect(try encoded(request)["vault_id"] == nil)
  }

  private func encoded(_ request: ConversationCreateRequest) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
  }

  @Test func nullableResponsesAndNewFieldsDecode() throws {
    let conversation = try APIClient.decode(
      Conversation.self,
      from: Data(
        #"{"id":"c1","runtime":"claude","status":"idle","sandbox":null,"labels":{"origin":"test"},"permission_policy":{"ask_timeout":0,"shell":"ask"},"pending_requests":[{"request_id":"r1","options":[],"asked_at":null}],"last_active_at":"2026-09-15T12:00:00Z","current":true}"#
          .utf8))
    #expect(conversation.sandbox == nil)
    #expect(conversation.labels == ["origin": "test"])
    #expect(conversation.permissionPolicy == ["shell": "ask"])
    #expect(conversation.permissionPolicyValues?["ask_timeout"] == .number(0))
    #expect(conversation.pendingRequests?.first?.askedAt == nil)
    #expect(conversation.lastActiveAt != nil)
    #expect(conversation.current == true)
    let turn = try APIClient.decode(
      Turn.self,
      from: Data(
        #"{"id":"t1","turn_number":1,"prompt":"hello","status":"running","usage":null,"waiting":false,"model_selection":{"status":"selected","effective_model":null}}"#
          .utf8))
    #expect(turn.usage == nil)
    #expect(turn.waiting == false)
    #expect(turn.modelSelection?.effectiveModel == nil)
    #expect(throws: (any Error).self) {
      try APIClient.decode(Conversation.self, from: Data(#"{"id":"c1"}"#.utf8))
    }
  }

  @Test func invalidRunInputsDoNotMakeRequests() async throws {
    let transport = FakeTransport([])
    let client = FountainClient.fake(transport)
    for prompt in [nil, "", " \n"] as [String?] {
      await #expect(throws: ConversationRunInputError.self) {
        try await client.runRequest(ConversationCreateRequest(agentID: "a1", prompt: prompt))
      }
    }
    var request = ConversationCreateRequest(agentID: "a1", prompt: "hello")
    request.queue = true
    await #expect(throws: ConversationRunInputError.self) { try await client.runRequest(request) }
    await #expect(throws: ConversationRunInputError.self) {
      try await client.conversations.create(request)
    }
    #expect(transport.requests.isEmpty)
  }
}
