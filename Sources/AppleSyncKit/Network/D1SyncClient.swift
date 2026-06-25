import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat

// MARK: - D1 Sync Client

/// Generic HTTP client for the Cloudflare D1 sync Worker. Entity-agnostic: every
/// method takes the entity name as a string (`"notes"`, `"reminders"`, …) and is
/// generic over the record type.
public actor D1SyncClient {
  /// Must stay in sync with `MAX_BATCH_SIZE` in the Cloudflare Worker.
  private static let maxBatchSize = 500

  private let config: SyncConfig
  private let httpClient: HTTPClient

  /// `urlQueryAllowed` minus the separators that must be escaped inside a value.
  private static let queryValueAllowed: CharacterSet = {
    var set = CharacterSet.urlQueryAllowed
    set.remove(charactersIn: "&=+")
    return set
  }()

  private static func encodeQuery(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value
  }

  /// `urlPathAllowed` minus `/` so a record id stays a single path segment. Note
  /// ids are `x-coredata://…/ICNote/p123`; leaving the slashes unescaped splits
  /// them into extra path segments and the Worker's `:id` route 404s.
  private static let pathSegmentAllowed: CharacterSet = {
    var set = CharacterSet.urlPathAllowed
    set.remove(charactersIn: "/")
    return set
  }()

  public init(config: SyncConfig) {
    self.config = config
    self.httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
  }

  /// Shut down the underlying HTTP client. Call before discarding the client.
  public func shutdown() async throws {
    try await httpClient.shutdown()
  }

  /// Creates a client from `config`, runs `body`, and guarantees `shutdown()` —
  /// even if `body` throws before making any request. Prefer this over
  /// constructing `D1SyncClient` directly so the underlying HTTPClient is never
  /// leaked (its `deinit` fatals if not shut down).
  public static func withClient<R>(
    config: SyncConfig,
    _ body: @Sendable (D1SyncClient) async throws -> R
  ) async throws -> R {
    let client = D1SyncClient(config: config)
    do {
      let result = try await body(client)
      try await client.shutdown()
      return result
    } catch {
      try? await client.shutdown()
      throw error
    }
  }

  // MARK: - Push

  /// Batch upsert `items` to `entity`. `id` extracts each record's local id;
  /// `idOverrides` maps local -> remote id; `lastModifiedByRemoteId` supplies the
  /// envelope timestamp (defaults to now).
  public func push<T: Codable & Sendable>(
    entity: String,
    items: [T],
    id: @Sendable (T) -> String,
    idOverrides: [String: String] = [:],
    lastModifiedByRemoteId: [String: String] = [:]
  ) async throws -> PushResult {
    let now = ISO8601DateFormatter.syncISO8601.string(from: Date())
    let requestItems = items.map { item -> PushRequestItem<T> in
      let remoteId = idOverrides[id(item)] ?? id(item)
      return PushRequestItem(
        id: remoteId, data: item, lastModified: lastModifiedByRemoteId[remoteId] ?? now)
    }
    return try await push(entity: entity, items: requestItems)
  }

  // MARK: - Pull

  public func pull<T: Codable & Sendable>(
    entity: String,
    cursor: String?,
    excludeOwnWrites: Bool = true
  ) async throws -> PullResponse<T> {
    var queryItems: [String] = []
    if excludeOwnWrites {
      queryItems.append("device=\(Self.encodeQuery(config.deviceId))")
    }
    if let cursor {
      queryItems.append("cursor=\(Self.encodeQuery(cursor))")
    }
    let queryString = queryItems.isEmpty ? "" : "?\(queryItems.joined(separator: "&"))"
    var httpRequest = HTTPClientRequest(url: "\(config.apiURL)/api/v1/\(entity)/pull\(queryString)")
    httpRequest.method = .GET
    httpRequest.headers.add(name: "Authorization", value: "Bearer \(config.apiToken)")

    let response = try await httpClient.execute(httpRequest, timeout: .seconds(120))
    // Pull responses carry full entity payloads (10 MB ceiling).
    let responseData = try await response.body.collect(upTo: 10 * 1024 * 1024)

    guard response.status == .ok else {
      let errorBody = String(buffer: responseData)
      throw SyncError.unknown("Pull failed (\(response.status.code)): \(errorBody)")
    }

    let dto = try JSONDecoder().decode(PullResponseDTO.self, from: Data(buffer: responseData))
    let items: [PullItem<T>] = try PullItemDecoder.decodeItems(from: dto.items, entity: entity)
    return PullResponse(items: items, cursor: dto.cursor, hasMore: dto.hasMore)
  }

  /// Reads every live record regardless of origin device (own-writes filter
  /// disabled). Soft-deleted records are dropped.
  public func pullAll<T: Codable & Sendable>(
    entity: String,
    as type: T.Type = T.self
  ) async throws -> [T] {
    var all: [T] = []
    var cursor: String? = nil
    var hasMore = true
    while hasMore {
      let response: PullResponse<T> = try await pull(
        entity: entity, cursor: cursor, excludeOwnWrites: false)
      all += response.items.filter { !$0.deleted }.map { $0.data }
      cursor = response.cursor
      hasMore = response.hasMore
    }
    return all
  }

  // MARK: - Delete

  public func delete(entity: String, id: String, lastModified: String?) async throws {
    let encodedId = id.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? id
    var httpRequest = HTTPClientRequest(url: "\(config.apiURL)/api/v1/\(entity)/\(encodedId)")
    httpRequest.method = .DELETE
    httpRequest.headers.add(name: "Authorization", value: "Bearer \(config.apiToken)")
    httpRequest.headers.add(name: "Content-Type", value: "application/json")
    let bodyDict = [
      "last_modified": lastModified ?? ISO8601DateFormatter.syncISO8601.string(from: Date())
    ]
    httpRequest.body = .bytes(try JSONEncoder().encode(bodyDict))

    let response = try await httpClient.execute(httpRequest, timeout: .seconds(120))
    guard response.status == .ok else {
      let responseData = try await response.body.collect(upTo: 1024 * 1024)
      let errorBody = String(buffer: responseData)
      throw SyncError.unknown("Delete failed (\(response.status.code)): \(errorBody)")
    }
  }

  // MARK: - Generic Batch Push

  private func push<T: Codable>(entity: String, items: [PushRequestItem<T>]) async throws
    -> PushResult
  {
    guard !items.isEmpty else { return PushResult(synced: 0, skipped: 0) }
    var synced = 0
    var skipped = 0
    var offset = 0
    while offset < items.count {
      let chunk = Array(items[offset..<min(offset + Self.maxBatchSize, items.count)])
      let result = try await pushBatch(entity: entity, items: chunk)
      synced += result.synced
      skipped += result.skipped
      offset += Self.maxBatchSize
    }
    return PushResult(synced: synced, skipped: skipped)
  }

  private func pushBatch<T: Codable>(entity: String, items: [PushRequestItem<T>]) async throws
    -> PushResult
  {
    let request = PushRequest(deviceId: config.deviceId, items: items)
    let body = try JSONEncoder().encode(request)

    var httpRequest = HTTPClientRequest(url: "\(config.apiURL)/api/v1/\(entity)/push")
    httpRequest.method = .POST
    httpRequest.headers.add(name: "Authorization", value: "Bearer \(config.apiToken)")
    httpRequest.headers.add(name: "Content-Type", value: "application/json")
    httpRequest.body = .bytes(body)

    let response = try await httpClient.execute(httpRequest, timeout: .seconds(120))
    // Push responses are small acknowledgements (1 MB ceiling).
    let responseData = try await response.body.collect(upTo: 1024 * 1024)

    guard response.status == .ok else {
      let errorBody = String(buffer: responseData)
      throw SyncError.unknown("Push failed (\(response.status.code)): \(errorBody)")
    }
    return try JSONDecoder().decode(PushResult.self, from: Data(buffer: responseData))
  }
}
