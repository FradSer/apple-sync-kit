import Foundation

extension Array where Element: Sendable {
  fileprivate func asyncMap<T: Sendable>(
    _ transform: @Sendable (Element) async throws -> T
  ) async throws -> [T] {
    var results = [T]()
    results.reserveCapacity(count)
    for element in self {
      results.append(try await transform(element))
    }
    return results
  }
}

// MARK: - Sync Cycle Summary

/// Consolidated summary of a full bidirectional synchronization run.
public struct SyncCycleSummary: Sendable, Equatable {
  public let push: PushResult
  public let pull: PullSummary

  public init(push: PushResult, pull: PullSummary) {
    self.push = push
    self.pull = pull
  }
}

// MARK: - Pull Execution State

private struct PullSessionState {
  var pulled = 0
  var deleted = 0
  var skipped = 0
}

// MARK: - Caller-Managed Locked Session

/// Coordinator operations that reuse a lock already held by `SyncCoordinator.withLock`.
/// Use this session to compose multiple entity operations without nested lock acquisition.
public struct LockedSyncSession: Sendable {
  private let coordinator: SyncCoordinator
  private let client: any SyncRemoteClient

  fileprivate init(coordinator: SyncCoordinator, client: any SyncRemoteClient) {
    self.coordinator = coordinator
    self.client = client
  }

  public func sync<S: LocalSyncSource>(source: S) async throws -> SyncCycleSummary {
    let push = try await coordinator.executePush(source: source, client: client)
    let pull = try await coordinator.executePull(source: source, client: client)
    return SyncCycleSummary(push: push, pull: pull)
  }

  public func push<S: LocalSyncSource>(source: S) async throws -> PushResult {
    try await coordinator.executePush(source: source, client: client)
  }

  public func pull<S: LocalSyncSource>(source: S) async throws -> PullSummary {
    try await coordinator.executePull(source: source, client: client)
  }
}

// MARK: - Sync Coordinator

/// Deep synchronization coordinator.
/// Encapsulates concurrency locking (`flock`), HTTP client lifecycle,
/// unified push and pull pipelines, and atomic checkpoint persistence via `SyncStateJournal`.
public struct SyncCoordinator: Sendable {
  public let config: SyncConfig
  public let store: ConfigStore
  private let transportClient: (any SyncRemoteClient)?

  public init(config: SyncConfig, store: ConfigStore, client: (any SyncRemoteClient)? = nil) {
    self.config = config
    self.store = store
    self.transportClient = client
  }

  private func withClient<R>(
    _ body: @Sendable (any SyncRemoteClient) async throws -> R
  ) async throws -> R {
    if let transportClient {
      return try await body(transportClient)
    }
    return try await D1SyncClient.withClient(config: config) { client in
      try await body(client)
    }
  }

  /// Acquires the sync lock once and exposes operations that reuse it.
  /// The session must not escape `body`; its methods do not acquire another lock.
  public func withLock<R: Sendable>(
    _ body: @Sendable (LockedSyncSession) async throws -> R
  ) async throws -> R {
    let fd = try store.acquireLock()
    defer { store.releaseLock(fd) }
    return try await withClient { client in
      try await body(LockedSyncSession(coordinator: self, client: client))
    }
  }

  /// Executes a full bidirectional sync (push modified items, then pull remote updates).
  public func sync<S: LocalSyncSource>(source: S) async throws -> SyncCycleSummary {
    try await withLock { session in
      try await session.sync(source: source)
    }
  }

  /// Executes only the push phase for the given local source.
  public func push<S: LocalSyncSource>(source: S) async throws -> PushResult {
    try await withLock { session in
      try await session.push(source: source)
    }
  }

  /// Executes only the pull phase for the given local source.
  public func pull<S: LocalSyncSource>(source: S) async throws -> PullSummary {
    try await withLock { session in
      try await session.pull(source: source)
    }
  }

  // MARK: - Push Pipeline

  fileprivate func executePush<S: LocalSyncSource>(
    source: S,
    client: any SyncRemoteClient
  ) async throws -> PushResult {
    var journal = try store.journal.load()
    let entityName = source.entityName
    var entityState = journal.entityStates[entityName] ?? SyncEntityState()
    var idMapping = journal.idMappings[entityName] ?? [:]
    let localToRemote = SyncMapping.inverted(idMapping).mapping
    let adapterContext = SyncAdapterContext(
      localToRemoteId: localToRemote,
      entityState: entityState
    )

    var changes = try await source.changes(context: adapterContext)
    changes = LocalSyncChanges(
      records: changes.records,
      lastModifiedByRemoteId: changes.lastModifiedByRemoteId,
      deletionCandidates: try await source.filterDeletionCandidates(
        changes.deletionCandidates, context: adapterContext),
      deletionLastModifiedByRemoteId: changes.deletionLastModifiedByRemoteId
    )
    let pushResult = try await pushDirtyRecords(
      source: source,
      client: client,
      context: adapterContext,
      changes: changes,
      entityState: &entityState,
      journal: &journal
    )

    // INVARIANT: Synced state is persisted before any delete RPC fires.
    journal.entityStates[entityName] = entityState
    journal.idMappings[entityName] = idMapping
    try store.journal.commitCheckpoint(journal)

    try await applyRemoteDeletions(
      source: source,
      client: client,
      deletionCandidates: changes.deletionCandidates,
      deletionLastModifiedByRemoteId: changes.deletionLastModifiedByRemoteId,
      entityState: &entityState,
      idMapping: &idMapping,
      journal: &journal
    )

    return pushResult
  }

  private func pushDirtyRecords<S: LocalSyncSource>(
    source: S,
    client: any SyncRemoteClient,
    context: SyncAdapterContext,
    changes: LocalSyncChanges<S.Record>,
    entityState: inout SyncEntityState,
    journal: inout SyncJournalState
  ) async throws -> PushResult {
    guard !changes.records.isEmpty else { return PushResult(synced: 0, skipped: 0) }

    let remoteRecords = try await changes.records.asyncMap { try await source.transformForPush($0) }
    let result = try await client.push(
      entity: source.entityName,
      items: remoteRecords,
      id: { source.getLocalId($0) },
      idOverrides: context.localToRemoteId,
      lastModifiedByRemoteId: changes.lastModifiedByRemoteId
    )

    let acceptedRemoteIds =
      result.syncedIds.isEmpty && result.skipped == 0
      ? Set(changes.lastModifiedByRemoteId.keys)
      : Set(result.syncedIds)
    guard !acceptedRemoteIds.isEmpty else { return result }

    var acknowledgedLocalIds = [String]()
    for item in changes.records {
      let localId = source.getLocalId(item)
      let remoteId = context.localToRemoteId[localId] ?? localId
      guard acceptedRemoteIds.contains(remoteId),
        let lastModified = changes.lastModifiedByRemoteId[remoteId]
      else { continue }
      try entityState.recordSyncedValue(
        item,
        remoteId: remoteId,
        lastModified: lastModified,
        volatileKeys: source.volatileKeys
      )
      try source.recordPushMetadata(item, remoteId: remoteId, state: &entityState)
      acknowledgedLocalIds.append(localId)
    }

    journal.entityStates[source.entityName] = entityState
    try store.journal.commitCheckpoint(journal)
    try await source.acknowledgePushed(localIds: acknowledgedLocalIds)
    return result
  }

  private func applyRemoteDeletions<S: LocalSyncSource>(
    source: S,
    client: any SyncRemoteClient,
    deletionCandidates: [String],
    deletionLastModifiedByRemoteId: [String: String],
    entityState: inout SyncEntityState,
    idMapping: inout [String: String],
    journal: inout SyncJournalState
  ) async throws {
    guard !deletionCandidates.isEmpty else { return }

    for remoteId in deletionCandidates {
      let localId = idMapping[remoteId] ?? remoteId
      let deletionLastModified =
        deletionLastModifiedByRemoteId[remoteId]
        ?? ISO8601DateFormatter.syncISO8601.string(from: Date())
      let result = try await client.delete(
        entity: source.entityName,
        id: remoteId,
        lastModified: deletionLastModified
      )
      guard result.accepted else { continue }
      try await source.finalizeDeleted(localId: localId)
      idMapping.removeValue(forKey: remoteId)
      entityState.removeRemoteId(remoteId)
      journal.entityStates[source.entityName] = entityState
      journal.idMappings[source.entityName] = idMapping
      try store.journal.commitCheckpoint(journal)
    }
  }

  // MARK: - Pull Pipeline

  fileprivate func executePull<S: LocalSyncSource>(
    source: S,
    client: any SyncRemoteClient
  ) async throws -> PullSummary {
    var journal = try store.journal.load()
    let entityName = source.entityName
    var entityState = journal.entityStates[entityName] ?? SyncEntityState()
    var idMapping = journal.idMappings[entityName] ?? [:]
    var cursor = journal.cursors[entityName]
    var session = PullSessionState()
    var hasMore = true

    while hasMore {
      let response: PullResponse<S.Record> = try await client.pull(
        entity: entityName,
        cursor: cursor,
        excludeOwnWrites: true
      )
      hasMore = response.hasMore
      for item in response.items {
        try await applySinglePullItem(
          item: item,
          source: source,
          entityName: entityName,
          entityState: &entityState,
          idMapping: &idMapping,
          journal: &journal,
          session: &session
        )
      }
      cursor = response.cursor
      journal.cursors[entityName] = response.cursor
      journal.entityStates[entityName] = entityState
      journal.idMappings[entityName] = idMapping
      try store.journal.commitCheckpoint(journal)
    }

    return PullSummary(pulled: session.pulled, deleted: session.deleted, skipped: session.skipped)
  }

  private func applySinglePullItem<S: LocalSyncSource>(
    item: PullItem<S.Record>,
    source: S,
    entityName: String,
    entityState: inout SyncEntityState,
    idMapping: inout [String: String],
    journal: inout SyncJournalState,
    session: inout PullSessionState
  ) async throws {
    guard try await source.shouldApplyPulledItem(item) else {
      session.skipped += 1
      return
    }

    let localId = idMapping[item.id] ?? item.id
    if item.deleted {
      try await applyRemoteDelete(source: source, localId: localId)
      idMapping.removeValue(forKey: item.id)
      entityState.removeRemoteId(item.id)
      session.deleted += 1
    } else if try await isRemoteStale(source: source, localId: localId, item: item) {
      session.skipped += 1
      return
    } else {
      let localRecord = try await source.transformForPull(item.data)
      let newLocalId = try await source.applyRemoteUpsert(
        localRecord, localId: localId, remoteId: item.id, lastModified: item.lastModified
      )
      if let newLocalId { idMapping[item.id] = newLocalId }
      try entityState.recordSyncedValue(
        localRecord,
        remoteId: item.id,
        lastModified: item.lastModified,
        volatileKeys: source.volatileKeys
      )
      try source.recordPullMetadata(localRecord, remoteId: item.id, state: &entityState)
      session.pulled += 1
    }

    journal.entityStates[entityName] = entityState
    journal.idMappings[entityName] = idMapping
    try store.journal.commitCheckpoint(journal)
  }

  private func applyRemoteDelete<S: LocalSyncSource>(source: S, localId: String) async throws {
    do {
      try await source.applyRemoteDelete(localId: localId)
    } catch {
      guard source.isNotFound(error) else { throw error }
      // Idempotent: already absent locally.
    }
  }

  private func isRemoteStale<S: LocalSyncSource>(
    source: S,
    localId: String,
    item: PullItem<S.Record>
  ) async throws -> Bool {
    switch try await source.localRecordState(for: localId) {
    case .absent:
      return false
    case .unknown:
      return true
    case .acceptRemote:
      return false
    case .timestamp(let localValue):
      guard let localDate = SyncTimestamp.parse(localValue),
        let remoteDate = SyncTimestamp.parse(item.lastModified)
      else {
        return true
      }
      return localDate > remoteDate
    }
  }
}
