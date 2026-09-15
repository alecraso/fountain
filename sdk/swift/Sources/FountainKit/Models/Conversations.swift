import Foundation

/// How a nullable conversation binding changes during a reapply. Three states,
/// because "leave it alone" and "remove it" are different requests and a plain
/// optional cannot tell them apart.
public enum ConversationBindingUpdate: Sendable, Equatable {
  /// Leave the current binding unchanged.
  case unchanged
  /// Remove the current binding.
  case clear
  /// Replace it with the resource identified by this id.
  case use(String)
}

/// `POST /api/conversations/{id}/reapply` body.
public struct ConversationReapplyRequest: Sendable, Encodable {
  public var agentID: String?
  public var environment: ConversationBindingUpdate
  public var vault: ConversationBindingUpdate

  public init(
    agentID: String? = nil,
    environment: ConversationBindingUpdate = .unchanged,
    vault: ConversationBindingUpdate = .unchanged
  ) {
    self.agentID = agentID
    self.environment = environment
    self.vault = vault
  }

  enum CodingKeys: String, CodingKey {
    case agentID = "agent_id"
    case environmentID = "environment_id"
    case vaultID = "vault_id"
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(agentID, forKey: .agentID)

    switch environment {
    case .unchanged: break
    case .clear: try container.encodeNil(forKey: .environmentID)
    case .use(let id): try container.encode(id, forKey: .environmentID)
    }

    switch vault {
    case .unchanged: break
    case .clear: try container.encodeNil(forKey: .vaultID)
    case .use(let id): try container.encode(id, forKey: .vaultID)
    }
  }
}
