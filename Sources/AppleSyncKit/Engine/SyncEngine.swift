import Foundation

// MARK: - Sync Engine

/// The generic bidirectional sync algorithm, shared by both the EventKit/macOS
/// (snapshot-based) and SQLite/Linux (local-only-flag) services. It is generic
/// over each project's concrete `State` / `Cursors` / `Mapping` Codable types,
/// addressed via `WritableKeyPath`s to the per-entity sub-state, so the on-disk
/// JSON shape stays owned by the project (no format change). Persistence goes
/// through the supplied `ConfigStore`.
public enum SyncEngine {

  // MARK: - Push (snapshot strategy — EventKit/macOS)

  /// Pushes `items`, records their synced state, then soft-deletes remote ids no
  /// longer present locally. State is persisted before any delete RPC fires so a
  /// deletion failure can never leave pushed items unrecorded.
  public static func pushSnapshot<
    E: Encodable & Sendable, State: Codable & Sendable, Mapping: Codable & Sendable
  >(
    items: [E],
    getId: @Sendable (E) -> String,
    store: ConfigStore,
    defaultState: State,
    stateKeyPath: WritableKeyPath<State, SyncEntityState>,
    defaultMapping: Mapping,
    mappingKeyPath: WritableKeyPath<Mapping, [String: String]>,
    volatileKeys: Set<String>,
    deletionCandidates: @Sendable (SyncEntityState, Set<String>) -> [String],
    push: @Sendable ([E], [String: String], [String: String]) async throws -> PushResult,
    recordExtra: (@Sendable (inout SyncEntityState, E, String) -> Void)? = nil,
    filterDeletionCandidates: (@Sendable ([String], Mapping) async -> [String])? = nil,
    delete: @Sendable (String, String?) async throws -> Void
  ) async throws -> PushResult {
    let uniqueItems = dedup(items, getId: getId)

    var idMapping = try store.loadJSONStrict(from: store.idMappingPath, default: defaultMapping)
    var state = try store.loadJSONStrict(from: store.statePath, default: defaultState)
    var entityState = state[keyPath: stateKeyPath]
    let localToRemote = invert(idMapping[keyPath: mappingKeyPath])

    let currentRemoteIds = SyncPushHelpers.currentRemoteIds(
      items: uniqueItems, getId: getId, localToRemote: localToRemote)
    var deletedRemoteIds = deletionCandidates(entityState, currentRemoteIds)
    if let filterDeletionCandidates {
      deletedRemoteIds = await filterDeletionCandidates(deletedRemoteIds, idMapping)
    }

    let fallback = ISO8601DateFormatter.syncISO8601.string(from: Date())
    var itemsToPush = [E]()
    var lastModifiedByRemoteId = [String: String]()
    for item in uniqueItems {
      let remoteId = localToRemote[getId(item)] ?? getId(item)
      let lastModified = try entityState.lastModified(
        for: item, remoteId: remoteId, fallback: fallback, volatileKeys: volatileKeys)
      if lastModified == fallback {
        itemsToPush.append(item)
        lastModifiedByRemoteId[remoteId] = lastModified
      }
    }

    let result = try await push(itemsToPush, localToRemote, lastModifiedByRemoteId)

    for item in itemsToPush {
      let remoteId = localToRemote[getId(item)] ?? getId(item)
      if let lastModified = lastModifiedByRemoteId[remoteId] {
        try entityState.recordSyncedValue(
          item, remoteId: remoteId, lastModified: lastModified, volatileKeys: volatileKeys)
      }
      recordExtra?(&entityState, item, remoteId)
    }
    state[keyPath: stateKeyPath] = entityState
    try store.saveJSON(state, to: store.statePath)

    guard !deletedRemoteIds.isEmpty else { return result }
    for remoteId in deletedRemoteIds {
      try await delete(remoteId, entityState.lastModifiedByRemoteId[remoteId])
      idMapping[keyPath: mappingKeyPath].removeValue(forKey: remoteId)
      entityState.removeRemoteId(remoteId)
      state[keyPath: stateKeyPath] = entityState
      try store.saveJSON(idMapping, to: store.idMappingPath)
      try store.saveJSON(state, to: store.statePath)
    }
    return result
  }

  // MARK: - Push (local-only strategy — SQLite/Linux)

  public struct DeletedRecord: Sendable {
    public let id: String
    public let lastModified: String
    public init(id: String, lastModified: String) {
      self.id = id
      self.lastModified = lastModified
    }
  }

  /// Pushes locally modified items (those flagged local-only), records their
  /// synced state, then soft-deletes remote ids no longer present locally.
  public static func pushLocalOnly<
    E: Encodable & Sendable, State: Codable & Sendable, Mapping: Codable & Sendable
  >(
    allItems: [E],
    localOnlyItems: [E],
    deletedRecords: [DeletedRecord],
    getId: @Sendable (E) -> String,
    store: ConfigStore,
    defaultState: State,
    stateKeyPath: WritableKeyPath<State, SyncEntityState>,
    defaultMapping: Mapping,
    mappingKeyPath: WritableKeyPath<Mapping, [String: String]>,
    volatileKeys: Set<String>,
    deletionCandidates: @Sendable (SyncEntityState, Set<String>) -> [String],
    push: @Sendable ([E], [String: String], [String: String]) async throws -> PushResult,
    recordExtra: (@Sendable (inout SyncEntityState, E, String) -> Void)? = nil,
    delete: @Sendable (String, String?) async throws -> Void,
    clearLocalOnly: @Sendable ([String]) async throws -> Void,
    removeRecord: @Sendable (String) async throws -> Void
  ) async throws -> PushResult {
    let uniqueItems = dedup(allItems, getId: getId)
    let uniqueLocalOnly = dedup(localOnlyItems, getId: getId)

    var idMapping = try store.loadJSONStrict(from: store.idMappingPath, default: defaultMapping)
    var state = try store.loadJSONStrict(from: store.statePath, default: defaultState)
    var entityState = state[keyPath: stateKeyPath]
    let localToRemote = invert(idMapping[keyPath: mappingKeyPath])

    let currentRemoteIds = SyncPushHelpers.currentRemoteIds(
      items: uniqueItems, getId: getId, localToRemote: localToRemote)
    var deletedRemoteIds = deletionCandidates(entityState, currentRemoteIds)
    for record in deletedRecords {
      let remoteId = localToRemote[record.id] ?? record.id
      if !deletedRemoteIds.contains(remoteId) { deletedRemoteIds.append(remoteId) }
    }

    let fallback = ISO8601DateFormatter.syncISO8601.string(from: Date())
    var lastModifiedByRemoteId = [String: String]()
    for item in uniqueLocalOnly {
      let remoteId = localToRemote[getId(item)] ?? getId(item)
      lastModifiedByRemoteId[remoteId] = fallback
    }

    let result = try await push(uniqueLocalOnly, localToRemote, lastModifiedByRemoteId)

    for item in uniqueLocalOnly {
      let remoteId = localToRemote[getId(item)] ?? getId(item)
      if let lastModified = lastModifiedByRemoteId[remoteId] {
        try entityState.recordSyncedValue(
          item, remoteId: remoteId, lastModified: lastModified, volatileKeys: volatileKeys)
      }
      recordExtra?(&entityState, item, remoteId)
    }
    state[keyPath: stateKeyPath] = entityState
    try store.saveJSON(state, to: store.statePath)

    let pushedLocalIds = uniqueLocalOnly.map { getId($0) }
    if !pushedLocalIds.isEmpty {
      try await clearLocalOnly(pushedLocalIds)
    }

    guard !deletedRemoteIds.isEmpty else { return result }
    for remoteId in deletedRemoteIds {
      try await delete(remoteId, entityState.lastModifiedByRemoteId[remoteId])
      let localId = idMapping[keyPath: mappingKeyPath][remoteId] ?? remoteId
      idMapping[keyPath: mappingKeyPath].removeValue(forKey: remoteId)
      entityState.removeRemoteId(remoteId)
      state[keyPath: stateKeyPath] = entityState
      try store.saveJSON(idMapping, to: store.idMappingPath)
      try store.saveJSON(state, to: store.statePath)
      try await removeRecord(localId)
    }
    return result
  }

  // MARK: - Pull (shared)

  /// Incremental cursor-based pull. `applyUpsert` returns a new local id when it
  /// created a record (so the mapping is recorded); `applyDelete` removes a local
  /// record. Both are project-supplied (EventKit or SQLite). Conflicts resolve by
  /// last-write-wins: a local copy newer than the server's is skipped.
  public static func pull<
    T: Codable & Sendable, State: Codable & Sendable, Cursors: Codable & Sendable,
    Mapping: Codable & Sendable
  >(
    entityName: String,
    store: ConfigStore,
    defaultState: State,
    stateKeyPath: WritableKeyPath<State, SyncEntityState>,
    defaultCursors: Cursors,
    cursorKeyPath: WritableKeyPath<Cursors, String?>,
    defaultMapping: Mapping,
    mappingKeyPath: WritableKeyPath<Mapping, [String: String]>,
    volatileKeys: Set<String>,
    localLastModifiedById: [String: String],
    localIdsWithoutTimestamp: Set<String>,
    isNotFound: @Sendable (Error) -> Bool,
    pull: @Sendable (String?) async throws -> PullResponse<T>,
    applyDelete: @Sendable (String) async throws -> Void,
    applyUpsert: @Sendable (String, PullItem<T>) async throws -> String?,
    recordExtra: (@Sendable (inout SyncEntityState, PullItem<T>) -> Void)? = nil
  ) async throws -> PullSummary {
    var cursors = store.loadJSON(from: store.cursorsPath, default: defaultCursors)
    var idMapping = try store.loadJSONStrict(from: store.idMappingPath, default: defaultMapping)
    var state = try store.loadJSONStrict(from: store.statePath, default: defaultState)
    var entityState = state[keyPath: stateKeyPath]
    var pulled = 0
    var deleted = 0
    var skipped = 0
    var hasMore = true

    func persist() throws {
      state[keyPath: stateKeyPath] = entityState
      try store.saveJSON(cursors, to: store.cursorsPath)
      try store.saveJSON(idMapping, to: store.idMappingPath)
      try store.saveJSON(state, to: store.statePath)
    }

    while hasMore {
      let response: PullResponse<T>
      do {
        response = try await pull(cursors[keyPath: cursorKeyPath])
      } catch {
        // Persist progress from earlier pages so created items keep their id
        // mapping; otherwise a retry would create duplicate local entities.
        try? persist()
        throw error
      }
      hasMore = response.hasMore
      var hadFailures = false

      for item in response.items {
        let localId = idMapping[keyPath: mappingKeyPath][item.id] ?? item.id

        if item.deleted {
          do {
            try await applyDelete(localId)
          } catch let error where isNotFound(error) {
            // Already gone locally; clean up mapping.
          } catch {
            writeStderr("Warning: Could not delete \(entityName) \(item.id): \(error)\n")
            hadFailures = true
            continue
          }
          idMapping[keyPath: mappingKeyPath].removeValue(forKey: item.id)
          entityState.removeRemoteId(item.id)
          deleted += 1
          continue
        }

        if localIdsWithoutTimestamp.contains(localId) {
          writeStderr(
            "Skipped \(entityName) \(item.id): local copy has no timestamp for conflict comparison\n"
          )
          skipped += 1
          continue
        }

        if let localValue = localLastModifiedById[localId],
          let localModified = SyncTimestamp.parse(localValue),
          let serverModified = SyncTimestamp.parse(item.lastModified),
          localModified > serverModified
        {
          writeStderr(
            "Skipped \(entityName) \(item.id): local copy is newer; it will be pushed on next sync\n"
          )
          skipped += 1
          continue
        }

        do {
          let newLocalId = try await applyUpsert(localId, item)
          if let newLocalId {
            idMapping[keyPath: mappingKeyPath][item.id] = newLocalId
          } else if idMapping[keyPath: mappingKeyPath][item.id] == nil {
            idMapping[keyPath: mappingKeyPath][item.id] = localId
          }
          try entityState.recordSyncedValue(
            item.data, remoteId: item.id, lastModified: item.lastModified,
            volatileKeys: volatileKeys)
          recordExtra?(&entityState, item)
          pulled += 1
        } catch {
          writeStderr("Warning: Could not sync \(entityName) \(item.id): \(error)\n")
          hadFailures = true
        }
      }

      cursors[keyPath: cursorKeyPath] = SyncCursorPolicy.nextCursor(
        currentCursor: cursors[keyPath: cursorKeyPath],
        responseCursor: response.cursor,
        hadFailures: hadFailures)
      try persist()

      if hadFailures {
        throw SyncError.unknown(
          "Pull \(entityName) failed for one or more items. Cursor was not advanced.")
      }
    }

    return PullSummary(pulled: pulled, deleted: deleted, skipped: skipped)
  }

  // MARK: - Helpers

  private static func dedup<E>(_ items: [E], getId: (E) -> String) -> [E] {
    var seen = Set<String>()
    var unique = [E]()
    for item in items where seen.insert(getId(item)).inserted {
      unique.append(item)
    }
    return unique
  }

  /// Inverts a remote->local map to local->remote, warning on collisions (stderr).
  private static func invert(_ mapping: [String: String]) -> [String: String] {
    let result = SyncMapping.inverted(mapping)
    for collision in result.collisions {
      writeStderr(
        "Warning: duplicate ID mapping -- local '\(collision.localId)' maps to both "
          + "'\(collision.keptRemoteId)' and '\(collision.droppedRemoteId)'\n")
    }
    return result.mapping
  }
}
