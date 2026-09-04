import Foundation

// MARK: - Sync Adapter Context

/// Encapsulates coordinator context provided to a local sync adapter during change discovery.
public struct SyncAdapterContext: Sendable {
  public let localToRemoteId: [String: String]
  public let entityState: SyncEntityState

  public init(localToRemoteId: [String: String], entityState: SyncEntityState) {
    self.localToRemoteId = localToRemoteId
    self.entityState = entityState
  }
}

/// The local state used for safe last-write-wins conflict resolution.
public enum LocalRecordState: Sendable, Equatable {
  /// No local record exists, so a remote upsert may create one.
  case absent
  /// A local record exists and has a timestamp suitable for comparison.
  case timestamp(String)
  /// A local record exists but cannot safely participate in timestamp comparison.
  case unknown
  /// A local record exists without a comparable timestamp and explicitly accepts remote state.
  case acceptRemote
}

/// The local records and remote IDs discovered during one consistent source read.
public struct LocalSyncChanges<Record: Codable & Sendable>: Sendable {
  public let records: [Record]
  public let lastModifiedByRemoteId: [String: String]
  public let deletionCandidates: [String]
  public let deletionLastModifiedByRemoteId: [String: String]

  public init(
    records: [Record],
    lastModifiedByRemoteId: [String: String],
    deletionCandidates: [String],
    deletionLastModifiedByRemoteId: [String: String] = [:]
  ) {
    self.records = records
    self.lastModifiedByRemoteId = lastModifiedByRemoteId
    self.deletionCandidates = deletionCandidates
    self.deletionLastModifiedByRemoteId = deletionLastModifiedByRemoteId
  }
}

// MARK: - Local Sync Source Protocol

/// A cohesive bidirectional adapter seam over local storage.
/// One `changes` call discovers a consistent local view for both push and deletion.
public protocol LocalSyncSource<Record>: Sendable {
  associatedtype Record: Codable & Sendable

  /// The entity name used for remote D1 endpoints (e.g. "notes", "reminders").
  var entityName: String { get }

  /// Volatile fields excluded from content snapshots (e.g. identity, modification dates).
  var volatileKeys: Set<String> { get }

  /// Extracts the unique local identifier for a record.
  func getLocalId(_ record: Record) -> String

  /// Describes the local record for safe Last-Write-Wins (LWW) evaluation during pull.
  func localRecordState(for localId: String) async throws -> LocalRecordState

  /// Discovers pending records and deletion candidates from one local snapshot.
  func changes(context: SyncAdapterContext) async throws -> LocalSyncChanges<Record>

  /// Converts a local record to its remote payload. The transform must preserve its local ID.
  func transformForPush(_ record: Record) async throws -> Record

  /// Converts a remote payload back to the local record representation.
  func transformForPull(_ record: Record) async throws -> Record

  /// Whether a pulled item should participate in local application or bookkeeping.
  /// Called before tombstone/upsert branching so filters can inspect deletion state.
  func shouldApplyPulledItem(_ item: PullItem<Record>) async throws -> Bool

  /// Filters deletion candidates using domain-specific constraints such as calendar ranges.
  func filterDeletionCandidates(
    _ candidates: [String],
    context: SyncAdapterContext
  ) async throws -> [String]

  /// Records domain-specific metadata after a local record is checkpointed.
  func recordPushMetadata(_ record: Record, remoteId: String, state: inout SyncEntityState) throws

  /// Records domain-specific metadata after a remote record is checkpointed.
  func recordPullMetadata(_ record: Record, remoteId: String, state: inout SyncEntityState) throws

  /// Recognizes domain-specific not-found errors during idempotent remote deletes.
  func isNotFound(_ error: any Error) -> Bool

  /// Called after successful push to acknowledge pushed records locally.
  func acknowledgePushed(localIds: [String]) async throws

  /// Called after an accepted remote delete to purge or finalize the local record.
  /// Implementations must be idempotent: if local finalization succeeds but the journal
  /// checkpoint fails, the coordinator invokes this method again during retry.
  func finalizeDeleted(localId: String) async throws

  /// Applies a pulled upsert to local storage at the resolved local ID.
  /// Returns newly assigned local ID if the storage creates one.
  func applyRemoteUpsert(
    _ record: Record, localId: String, remoteId: String, lastModified: String
  ) async throws -> String?

  /// Applies a pulled deletion to local storage.
  func applyRemoteDelete(localId: String) async throws
}

extension LocalSyncSource {
  public var volatileKeys: Set<String> { [] }
  public func localRecordState(for localId: String) async throws -> LocalRecordState { .absent }
  public func transformForPush(_ record: Record) async throws -> Record { record }
  public func transformForPull(_ record: Record) async throws -> Record { record }
  public func shouldApplyPulledItem(_ item: PullItem<Record>) async throws -> Bool { true }
  public func filterDeletionCandidates(
    _ candidates: [String],
    context: SyncAdapterContext
  ) async throws -> [String] { candidates }
  public func recordPushMetadata(_ record: Record, remoteId: String, state: inout SyncEntityState)
    throws
  {}
  public func recordPullMetadata(_ record: Record, remoteId: String, state: inout SyncEntityState)
    throws
  {}
  public func isNotFound(_ error: any Error) -> Bool {
    (error as? any SyncNotFound)?.isNotFound == true
  }
}

// MARK: - Snapshot Sync Source (macOS / EventKit)

/// Adapter for snapshot-hash change detection.
/// Computes modifications and deletion candidates from one fetched record snapshot.
public struct SnapshotSyncSource<Record: Codable & Sendable>: LocalSyncSource {
  public let entityName: String
  public let fetchRecords: @Sendable () async throws -> [Record]
  public let getId: @Sendable (Record) -> String
  public let volatileKeys: Set<String>
  public let getLocalModified: (@Sendable (String) async throws -> String?)?
  public let existingRecordWithoutTimestamp: LocalRecordState
  public let transformForPushClosure: @Sendable (Record) async throws -> Record
  public let transformForPullClosure: @Sendable (Record) async throws -> Record
  public let shouldApplyPulledItemClosure: @Sendable (PullItem<Record>) async throws -> Bool
  public let filterDeletionCandidatesClosure:
    @Sendable ([String], SyncAdapterContext) async throws -> [String]
  public let recordPushMetadataClosure:
    @Sendable (Record, String, inout SyncEntityState) throws -> Void
  public let recordPullMetadataClosure:
    @Sendable (Record, String, inout SyncEntityState) throws -> Void
  public let isNotFoundClosure: @Sendable (any Error) -> Bool
  public let acknowledgePushedClosure: @Sendable ([String]) async throws -> Void
  public let finalizeDeletedClosure: @Sendable (String) async throws -> Void
  public let applyUpsertClosure:
    @Sendable (Record, _ localId: String, _ remoteId: String, _ lastModified: String) async throws
      -> String?
  public let applyDeleteClosure: @Sendable (String) async throws -> Void

  public init(
    entityName: String,
    fetchRecords: @escaping @Sendable () async throws -> [Record],
    getId: @escaping @Sendable (Record) -> String,
    volatileKeys: Set<String> = [],
    localLastModified: (@Sendable (String) async throws -> String?)? = nil,
    existingRecordWithoutTimestamp: LocalRecordState = .unknown,
    transformForPush: @escaping @Sendable (Record) async throws -> Record = { $0 },
    transformForPull: @escaping @Sendable (Record) async throws -> Record = { $0 },
    shouldApplyPulledItem: @escaping @Sendable (PullItem<Record>) async throws -> Bool = { _ in true
    },
    filterDeletionCandidates:
      @escaping @Sendable ([String], SyncAdapterContext) async throws -> [String] = { values, _ in
        values
      },
    recordPushMetadata:
      @escaping @Sendable (Record, String, inout SyncEntityState) throws -> Void = { _, _, _ in },
    recordPullMetadata:
      @escaping @Sendable (Record, String, inout SyncEntityState) throws -> Void = { _, _, _ in },
    isNotFound: @escaping @Sendable (any Error) -> Bool = {
      ($0 as? any SyncNotFound)?.isNotFound == true
    },
    acknowledgePushed: @escaping @Sendable ([String]) async throws -> Void = { _ in },
    finalizeDeleted: @escaping @Sendable (String) async throws -> Void = { _ in },
    applyUpsert:
      @escaping @Sendable (Record, _ localId: String, _ remoteId: String, _ lastModified: String)
      async throws -> String?,
    applyDelete: @escaping @Sendable (String) async throws -> Void
  ) {
    self.entityName = entityName
    self.fetchRecords = fetchRecords
    self.getId = getId
    self.volatileKeys = volatileKeys
    self.getLocalModified = localLastModified
    self.existingRecordWithoutTimestamp = existingRecordWithoutTimestamp
    self.transformForPushClosure = transformForPush
    self.transformForPullClosure = transformForPull
    self.shouldApplyPulledItemClosure = shouldApplyPulledItem
    self.filterDeletionCandidatesClosure = filterDeletionCandidates
    self.recordPushMetadataClosure = recordPushMetadata
    self.recordPullMetadataClosure = recordPullMetadata
    self.isNotFoundClosure = isNotFound
    self.acknowledgePushedClosure = acknowledgePushed
    self.finalizeDeletedClosure = finalizeDeleted
    self.applyUpsertClosure = applyUpsert
    self.applyDeleteClosure = applyDelete
  }

  public func getLocalId(_ record: Record) -> String {
    getId(record)
  }

  public func localRecordState(for localId: String) async throws -> LocalRecordState {
    let records = try await fetchRecords()
    guard records.contains(where: { getId($0) == localId }) else { return .absent }
    guard let timestamp = try await getLocalModified?(localId) else {
      return existingRecordWithoutTimestamp
    }
    return .timestamp(timestamp)
  }

  public func transformForPush(_ record: Record) async throws -> Record {
    try await transformForPushClosure(record)
  }

  public func transformForPull(_ record: Record) async throws -> Record {
    try await transformForPullClosure(record)
  }

  public func shouldApplyPulledItem(_ item: PullItem<Record>) async throws -> Bool {
    try await shouldApplyPulledItemClosure(item)
  }

  public func filterDeletionCandidates(
    _ candidates: [String], context: SyncAdapterContext
  ) async throws -> [String] {
    try await filterDeletionCandidatesClosure(candidates, context)
  }

  public func recordPushMetadata(
    _ record: Record, remoteId: String, state: inout SyncEntityState
  ) throws {
    try recordPushMetadataClosure(record, remoteId, &state)
  }

  public func recordPullMetadata(
    _ record: Record, remoteId: String, state: inout SyncEntityState
  ) throws {
    try recordPullMetadataClosure(record, remoteId, &state)
  }

  public func isNotFound(_ error: any Error) -> Bool {
    isNotFoundClosure(error)
  }

  public func changes(context: SyncAdapterContext) async throws -> LocalSyncChanges<Record> {
    let items = try await fetchRecords()
    let uniqueItems = SyncPushHelpers.dedup(items, getId: getId)
    let fallback = ISO8601DateFormatter.syncISO8601.string(from: Date())
    var pending = [Record]()
    var timestamps = [String: String]()

    for item in uniqueItems {
      let localId = getId(item)
      let remoteId = context.localToRemoteId[localId] ?? localId
      let lastModified = try context.entityState.lastModified(
        for: item, remoteId: remoteId, fallback: fallback, volatileKeys: volatileKeys)
      if lastModified == fallback {
        pending.append(item)
        timestamps[remoteId] = lastModified
      }
    }

    let currentRemoteIds = SyncPushHelpers.currentRemoteIds(
      items: uniqueItems, getId: getId, localToRemote: context.localToRemoteId)
    let deletions = context.entityState.deletionCandidates(currentRemoteIds: currentRemoteIds)
    let deletionObservation = ISO8601DateFormatter.syncISO8601.string(from: Date())
    return LocalSyncChanges(
      records: pending,
      lastModifiedByRemoteId: timestamps,
      deletionCandidates: deletions,
      deletionLastModifiedByRemoteId: Dictionary(
        uniqueKeysWithValues: deletions.map { ($0, deletionObservation) })
    )
  }

  public func acknowledgePushed(localIds: [String]) async throws {
    try await acknowledgePushedClosure(localIds)
  }

  public func finalizeDeleted(localId: String) async throws {
    try await finalizeDeletedClosure(localId)
  }

  public func applyRemoteUpsert(
    _ record: Record, localId: String, remoteId: String, lastModified: String
  ) async throws -> String? {
    try await applyUpsertClosure(record, localId, remoteId, lastModified)
  }

  public func applyRemoteDelete(localId: String) async throws {
    try await applyDeleteClosure(localId)
  }
}

// MARK: - Flagged Sync Source (Linux / SQLite)

/// Adapter for flag-based change detection backed by `SQLiteSyncStore`.
/// Reads dirty records with `is_local_only = 1` and deleted records with `deleted = 1`.
public struct FlaggedSyncSource<Record: Codable & Sendable>: LocalSyncSource {
  public let entityName: String
  public let table: String
  public let store: SQLiteSyncStore
  public let getId: @Sendable (Record) -> String
  public let transformForPushClosure: @Sendable (Record) async throws -> Record
  public let transformForPullClosure: @Sendable (Record) async throws -> Record
  public let shouldApplyPulledItemClosure: @Sendable (PullItem<Record>) async throws -> Bool
  public let filterDeletionCandidatesClosure:
    @Sendable ([String], SyncAdapterContext) async throws -> [String]
  public let recordPushMetadataClosure:
    @Sendable (Record, String, inout SyncEntityState) throws -> Void
  public let recordPullMetadataClosure:
    @Sendable (Record, String, inout SyncEntityState) throws -> Void
  public let isNotFoundClosure: @Sendable (any Error) -> Bool
  public let acknowledgePushedClosure: (@Sendable ([String]) async throws -> Void)?
  public let finalizeDeletedClosure: (@Sendable (String) async throws -> Void)?
  public let applyUpsertClosure:
    (@Sendable (Record, String, String, String) async throws -> String?)?
  public let applyDeleteClosure: (@Sendable (String) async throws -> Void)?

  public init(
    entityName: String,
    table: String,
    store: SQLiteSyncStore,
    getId: @escaping @Sendable (Record) -> String,
    transformForPush: @escaping @Sendable (Record) async throws -> Record = { $0 },
    transformForPull: @escaping @Sendable (Record) async throws -> Record = { $0 },
    shouldApplyPulledItem: @escaping @Sendable (PullItem<Record>) async throws -> Bool = { _ in true
    },
    filterDeletionCandidates:
      @escaping @Sendable ([String], SyncAdapterContext) async throws -> [String] = { values, _ in
        values
      },
    recordPushMetadata:
      @escaping @Sendable (Record, String, inout SyncEntityState) throws -> Void = { _, _, _ in },
    recordPullMetadata:
      @escaping @Sendable (Record, String, inout SyncEntityState) throws -> Void = { _, _, _ in },
    isNotFound: @escaping @Sendable (any Error) -> Bool = {
      ($0 as? any SyncNotFound)?.isNotFound == true
    },
    acknowledgePushed: (@Sendable ([String]) async throws -> Void)? = nil,
    finalizeDeleted: (@Sendable (String) async throws -> Void)? = nil,
    applyUpsert: (@Sendable (Record, String, String, String) async throws -> String?)? = nil,
    applyDelete: (@Sendable (String) async throws -> Void)? = nil
  ) {
    self.entityName = entityName
    self.table = table
    self.store = store
    self.getId = getId
    self.transformForPushClosure = transformForPush
    self.transformForPullClosure = transformForPull
    self.shouldApplyPulledItemClosure = shouldApplyPulledItem
    self.filterDeletionCandidatesClosure = filterDeletionCandidates
    self.recordPushMetadataClosure = recordPushMetadata
    self.recordPullMetadataClosure = recordPullMetadata
    self.isNotFoundClosure = isNotFound
    self.acknowledgePushedClosure = acknowledgePushed
    self.finalizeDeletedClosure = finalizeDeleted
    self.applyUpsertClosure = applyUpsert
    self.applyDeleteClosure = applyDelete
  }

  public func getLocalId(_ record: Record) -> String {
    getId(record)
  }

  public func localRecordState(for localId: String) async throws -> LocalRecordState {
    guard let timestamp = try store.fetchLastModified(table: table, id: localId) else {
      return .absent
    }
    return .timestamp(timestamp)
  }

  public func transformForPush(_ record: Record) async throws -> Record {
    try await transformForPushClosure(record)
  }

  public func transformForPull(_ record: Record) async throws -> Record {
    try await transformForPullClosure(record)
  }

  public func shouldApplyPulledItem(_ item: PullItem<Record>) async throws -> Bool {
    try await shouldApplyPulledItemClosure(item)
  }

  public func filterDeletionCandidates(
    _ candidates: [String], context: SyncAdapterContext
  ) async throws -> [String] {
    try await filterDeletionCandidatesClosure(candidates, context)
  }

  public func recordPushMetadata(
    _ record: Record, remoteId: String, state: inout SyncEntityState
  ) throws {
    try recordPushMetadataClosure(record, remoteId, &state)
  }

  public func recordPullMetadata(
    _ record: Record, remoteId: String, state: inout SyncEntityState
  ) throws {
    try recordPullMetadataClosure(record, remoteId, &state)
  }

  public func isNotFound(_ error: any Error) -> Bool {
    isNotFoundClosure(error)
  }

  public func changes(context: SyncAdapterContext) async throws -> LocalSyncChanges<Record> {
    let localOnly: [Record] = try store.fetchLocalOnly(from: table)
    let uniqueItems = SyncPushHelpers.dedup(localOnly, getId: getId)
    let fallback = ISO8601DateFormatter.syncISO8601.string(from: Date())
    var timestamps = [String: String]()

    for item in uniqueItems {
      let localId = getId(item)
      let remoteId = context.localToRemoteId[localId] ?? localId
      timestamps[remoteId] = fallback
    }

    let nonDeleted: [Record] = try store.fetchNonDeleted(from: table)
    let currentRemoteIds = SyncPushHelpers.currentRemoteIds(
      items: nonDeleted,
      getId: getId,
      localToRemote: context.localToRemoteId
    )
    let missingRemoteIds = context.entityState.deletionCandidates(
      currentRemoteIds: currentRemoteIds)
    var deletions = Set(missingRemoteIds)
    let deletionObservation = ISO8601DateFormatter.syncISO8601.string(from: Date())
    var deletionTimestamps = Dictionary(
      uniqueKeysWithValues: missingRemoteIds.map { ($0, deletionObservation) })
    let deletedRecords = try store.fetchDeletedRecords(from: table)
    for record in deletedRecords {
      let remoteId = context.localToRemoteId[record.id] ?? record.id
      deletions.insert(remoteId)
      deletionTimestamps[remoteId] = record.lastModified
    }
    return LocalSyncChanges(
      records: uniqueItems,
      lastModifiedByRemoteId: timestamps,
      deletionCandidates: deletions.sorted(),
      deletionLastModifiedByRemoteId: deletionTimestamps
    )
  }

  public func acknowledgePushed(localIds: [String]) async throws {
    if let acknowledgePushedClosure {
      try await acknowledgePushedClosure(localIds)
    } else {
      try store.clearLocalOnly(table: table, ids: localIds)
    }
  }

  public func finalizeDeleted(localId: String) async throws {
    if let finalizeDeletedClosure {
      try await finalizeDeletedClosure(localId)
    } else {
      try store.hardDeleteRecord(table: table, id: localId)
    }
  }

  public func applyRemoteUpsert(
    _ record: Record, localId: String, remoteId: String, lastModified: String
  ) async throws -> String? {
    if let applyUpsertClosure {
      return try await applyUpsertClosure(record, localId, remoteId, lastModified)
    }
    try store.upsertRecord(table: table, id: localId, data: record, lastModified: lastModified)
    return nil
  }

  public func applyRemoteDelete(localId: String) async throws {
    if let applyDeleteClosure {
      try await applyDeleteClosure(localId)
    } else {
      try store.hardDeleteRecord(table: table, id: localId)
    }
  }
}
