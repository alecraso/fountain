/// Internal storage for the three wire states of an optional request field.
/// Public properties remain Optional for source compatibility.
enum ConversationInputField<Value: Encodable & Sendable>: Sendable {
  case omitted
  case null
  case value(Value)

  var value: Value? {
    if case .value(let value) = self { return value }
    return nil
  }

  func encode<Key: CodingKey>(
    into container: inout KeyedEncodingContainer<Key>, forKey key: Key
  ) throws {
    switch self {
    case .omitted: break
    case .null: try container.encodeNil(forKey: key)
    case .value(let value): try container.encode(value, forKey: key)
    }
  }
}

/// A request cannot be followed as a run (blank prompt or queued creation).
public struct ConversationRunInputError: Error, Sendable {
  public let message: String
}
