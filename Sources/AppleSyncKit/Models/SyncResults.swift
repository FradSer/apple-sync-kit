import Foundation

// MARK: - Sync Configuration

public struct SyncConfig: Codable, Sendable {
  public let apiURL: String
  public let apiToken: String
  public let deviceId: String

  public init(apiURL: String, apiToken: String, deviceId: String) {
    self.apiURL = apiURL
    self.apiToken = apiToken
    self.deviceId = deviceId
  }
}

// MARK: - Sync Results

public struct PushResult: Codable, Sendable {
  public let synced: Int
  public let skipped: Int

  public init(synced: Int, skipped: Int) {
    self.synced = synced
    self.skipped = skipped
  }
}

public struct PullResponse<T: Codable & Sendable>: Sendable {
  public let items: [PullItem<T>]
  public let cursor: String
  public let hasMore: Bool

  public init(items: [PullItem<T>], cursor: String, hasMore: Bool) {
    self.items = items
    self.cursor = cursor
    self.hasMore = hasMore
  }
}

public struct PullItem<T: Codable & Sendable>: Sendable {
  public let id: String
  public let data: T
  public let deleted: Bool
  public let updatedAt: String
  public let lastModified: String

  public init(id: String, data: T, deleted: Bool, updatedAt: String, lastModified: String) {
    self.id = id
    self.data = data
    self.deleted = deleted
    self.updatedAt = updatedAt
    self.lastModified = lastModified
  }
}

public struct PullSummary: Codable, Sendable {
  public let pulled: Int
  public let deleted: Int
  public let skipped: Int

  public init(pulled: Int, deleted: Int, skipped: Int = 0) {
    self.pulled = pulled
    self.deleted = deleted
    self.skipped = skipped
  }
}
