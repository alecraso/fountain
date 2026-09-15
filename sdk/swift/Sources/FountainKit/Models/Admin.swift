import Foundation

/// `/api/admin/users` is the one endpoint with page-number pagination:
/// `meta` is `{page, per_page, total}`, not a cursor.
public struct AdminUserPage: Sendable, Decodable {
  public var users: [AdminUser]
  public var page: Int
  public var perPage: Int
  public var total: Int

  enum CodingKeys: String, CodingKey {
    case data, meta
  }

  enum MetaKeys: String, CodingKey {
    case page, total
    case perPage = "per_page"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    users = try container.decode([AdminUser].self, forKey: .data)
    let meta = try container.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta)
    page = try meta.decode(Int.self, forKey: .page)
    perPage = try meta.decode(Int.self, forKey: .perPage)
    total = try meta.decode(Int.self, forKey: .total)
  }

  public var hasMore: Bool { page * perPage < total }
}
