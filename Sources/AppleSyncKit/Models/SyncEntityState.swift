import Foundation

// MARK: - Sync Date Range

public struct SyncDateRange: Codable, Sendable, Equatable {
  public let start: String
  public let end: String

  public init(start: String, end: String) {
    self.start = start
    self.end = end
  }

  public func overlaps(_ other: SyncDateRange) -> Bool {
    start <= other.end && end >= other.start
  }
}

// MARK: - Sync Entity State

/// Per-entity sync bookkeeping: which remote ids are known, their last-modified
/// values, content snapshots (for change detection), and optional date ranges
/// (calendar windowing). Entity-agnostic; the consuming project composes these
/// into its own `SyncState` keyed by entity.
public struct SyncEntityState: Codable, Sendable, Equatable {
  public var knownRemoteIds: Set<String>
  public var lastModifiedByRemoteId: [String: String]
  public var snapshotsByRemoteId: [String: String]
  public var dateRangeByRemoteId: [String: SyncDateRange]

  public init(
    knownRemoteIds: Set<String> = [],
    lastModifiedByRemoteId: [String: String] = [:],
    snapshotsByRemoteId: [String: String] = [:],
    dateRangeByRemoteId: [String: SyncDateRange] = [:]
  ) {
    self.knownRemoteIds = knownRemoteIds
    self.lastModifiedByRemoteId = lastModifiedByRemoteId
    self.snapshotsByRemoteId = snapshotsByRemoteId
    self.dateRangeByRemoteId = dateRangeByRemoteId
  }

  public func deletionCandidates(currentRemoteIds: Set<String>) -> [String] {
    knownRemoteIds.subtracting(currentRemoteIds).sorted()
  }

  public func deletionCandidates(
    currentRemoteIds: Set<String>,
    withinRange range: SyncDateRange
  ) -> [String] {
    knownRemoteIds.subtracting(currentRemoteIds).filter { id in
      guard let stored = dateRangeByRemoteId[id] else { return false }
      return stored.overlaps(range)
    }.sorted()
  }

  /// Returns the stored last-modified for `value` when its content snapshot is
  /// unchanged, otherwise `fallback`. `volatileKeys` are excluded from the
  /// snapshot (identity/timestamp/read-only fields that differ per device).
  public func lastModified<T: Encodable>(
    for value: T,
    remoteId: String,
    fallback: String,
    volatileKeys: Set<String>
  ) throws -> String {
    let snapshot = try SyncSnapshotEncoder.encode(value, volatileKeys: volatileKeys)
    guard snapshotsByRemoteId[remoteId] == snapshot,
      let existingLastModified = lastModifiedByRemoteId[remoteId]
    else {
      return fallback
    }
    return existingLastModified
  }

  public mutating func recordKnownRemoteId(_ remoteId: String) {
    knownRemoteIds.insert(remoteId)
  }

  public mutating func removeRemoteId(_ remoteId: String) {
    knownRemoteIds.remove(remoteId)
    lastModifiedByRemoteId.removeValue(forKey: remoteId)
    snapshotsByRemoteId.removeValue(forKey: remoteId)
    dateRangeByRemoteId.removeValue(forKey: remoteId)
  }

  public mutating func recordDateRange(_ range: SyncDateRange, for remoteId: String) {
    dateRangeByRemoteId[remoteId] = range
  }

  public mutating func recordSyncedValue<T: Encodable>(
    _ value: T,
    remoteId: String,
    lastModified: String,
    volatileKeys: Set<String>
  ) throws {
    recordKnownRemoteId(remoteId)
    lastModifiedByRemoteId[remoteId] = lastModified
    snapshotsByRemoteId[remoteId] = try SyncSnapshotEncoder.encode(
      value, volatileKeys: volatileKeys)
  }
}

// MARK: - Snapshot Encoder

public enum SyncSnapshotEncoder {
  /// Encodes `value` to canonical JSON with `volatileKeys` removed, so pull-stored
  /// and push-computed snapshots compare only user-modifiable content.
  public static func encode<T: Encodable>(_ value: T, volatileKeys: Set<String>) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let raw = try encoder.encode(value)

    guard var json = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
      return String(decoding: raw, as: UTF8.self)
    }
    for key in volatileKeys {
      json.removeValue(forKey: key)
    }
    let cleaned = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    return String(decoding: cleaned, as: UTF8.self)
  }
}
