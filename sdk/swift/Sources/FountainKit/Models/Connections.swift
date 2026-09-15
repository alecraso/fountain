import Foundation

public struct ConnectionStatus: WireValue {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let active: Self = "active"
  public static let expired: Self = "expired"
  public static let revoked: Self = "revoked"
}
