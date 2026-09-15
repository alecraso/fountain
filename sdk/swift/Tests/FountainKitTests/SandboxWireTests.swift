import Foundation
import Testing

@testable import FountainKit

@Suite struct SandboxWireTests {
  private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try APIClient.decode(type, from: Data(json.utf8))
  }

  @Test func sandboxPreservesNestedNamesDatesNullsAndUnknownEnums() throws {
    let value = try decode(
      Sandbox.self,
      #"{"id":"s1","sprite_name":"box","status":"future_status","mode":"persistent","provider":"future_provider","environment_id":null,"checkpoint":{"id":"cp1","at":"2026-09-15T10:00:00Z"},"runner":{"id":"r1","name":"desk","hostname":"host","online":false,"path":"/work"}}"#
    )
    let checkpoint: Sandbox.Checkpoint? = value.checkpoint
    let runner: Sandbox.RunnerRef? = value.runner
    #expect(checkpoint?.id == "cp1")
    #expect(checkpoint?.at != nil)
    #expect(runner?.online == false)
    #expect(runner?.path == "/work")
    #expect(value.status?.rawValue == "future_status")
    #expect(value.provider?.rawValue == "future_provider")
    #expect(value.environmentID == nil)
    let empty = try decode(Sandbox.self, #"{"id":"s2","checkpoint":null,"runner":null}"#)
    #expect(empty.spriteName == nil && empty.status == nil)
    #expect(empty.checkpoint == nil && empty.runner == nil)
    #expect(throws: (any Error).self) { try decode(Sandbox.self, #"{"sprite_name":"missing-id"}"#) }
  }

  @Test(arguments: [
    #"{"id":"c1"}"#,
    #"{"id":"c1","status":null,"mid_turn":null}"#,
    #"{"id":"c1","status":"future_status","mid_turn":false}"#,
  ])
  func nestedConversationKeepsItsOptionalSourceAPI(_ json: String) throws {
    let detail = try decode(SandboxDetail.self, "{\"id\":\"s1\",\"conversations\":[\(json)]}")
    let conversation = try #require(detail.conversations?.first)
    // These optional accesses fail to compile if generation tightens the
    // published API, even when all current server payloads have values.
    let status = conversation.status?.rawValue
    if let midTurn = conversation.midTurn {
      #expect(midTurn == false)
      #expect(status == "future_status")
    } else {
      #expect(status == nil)
    }
  }

  @Test func detailRunnerAndTreeRetainTheirPublicShapes() throws {
    let detail = try decode(
      SandboxDetail.self,
      #"{"id":"s1","sprite_name":"box","status":"ready","conversations":[{"id":"c1","runtime":"future_runtime","status":"idle","mid_turn":false,"inserted_at":"2026-09-15T10:00:00Z"}],"inserted_at":"2026-09-15T10:00:00Z","last_resumed_at":null}"#
    )
    let conversation: SandboxDetail.SandboxConversation? = detail.conversations?.first
    #expect(conversation?.runtime?.rawValue == "future_runtime")
    #expect(conversation?.midTurn == false)
    #expect(conversation?.insertedAt != nil)
    #expect(detail.insertedAt != nil && detail.lastResumedAt == nil)
    let runner = try decode(
      Runner.self,
      #"{"id":"r1","name":"desk","online":false,"hostname":null,"connected_at":"2026-09-15T10:00:00Z","last_seen_at":null}"#
    )
    #expect(runner.online == false && runner.connectedAt != nil && runner.createdAt == nil)
    let tree = try decode(
      ConversationTreeNode.self,
      #"{"id":"c1","parent_id":null,"source":"future_source","status":"future_status"}"#)
    #expect(tree.source?.rawValue == "future_source" && tree.parentID == nil)
  }
}
