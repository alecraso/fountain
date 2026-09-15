import Foundation

/// `GET /api/auth/me` — the cheapest check that a key works.
public struct AuthMe: Sendable, Decodable, Hashable {
  public var id: String
  public var email: String
  public var role: UserRole?
  public var emailVerified: Bool?
  public var onboardingState: String?
  public var onboardingCompleted: Bool?
  /// Null when billing is off on this deployment.
  public var comped: Bool?
  /// Whether the deployment brokers egress credentials.
  public var brokered: Bool?
  /// Whether new connections, providers, and credential bindings may be added.
  public var connectionsEnabled: Bool?
  /// Whether existing connections and bindings may be listed or removed.
  public var connectionsManageable: Bool?
  /// When the presented key expires (OAuth tokens do).
  public var expiresAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, email, role, comped, brokered
    case emailVerified = "email_verified"
    case connectionsEnabled = "connections_enabled"
    case connectionsManageable = "connections_manageable"
    case onboardingState = "onboarding_state"
    case onboardingCompleted = "onboarding_completed"
    case expiresAt = "expires_at"
  }
}
