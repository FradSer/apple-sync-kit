import XCTest

@testable import AppleSyncKit

private struct HookRecord: Codable, Sendable, Equatable {
  let id: String
  let value: String
}

private enum HookError: Error {
  case missing
}

private actor HookRemoteClient: SyncRemoteClient {
  var pushedRecords: [HookRecord] = []
  var pullItems: [PullItem<HookRecord>] = []

  func setPullItems(_ items: [PullItem<HookRecord>]) {
    pullItems = items
  }

  func push<T: Codable & Sendable>(
    entity: String,
    items: [T],
    id: @Sendable (T) -> String,
    idOverrides: [String: String],
    lastModifiedByRemoteId: [String: String]
  ) async throws -> PushResult {
    pushedRecords = items.compactMap { $0 as? HookRecord }
    return PushResult(
      synced: items.count,
      skipped: 0,
      syncedIds: items.map { idOverrides[id($0)] ?? id($0) }
    )
  }

  func pull<T: Codable & Sendable>(
    entity: String,
    cursor: String?,
    excludeOwnWrites: Bool
  ) async throws -> PullResponse<T> {
    PullResponse(
      items: pullItems.compactMap { $0 as? PullItem<T> },
      cursor: "hook-cursor",
      hasMore: false
    )
  }

  func delete(entity: String, id: String, lastModified: String?) async throws -> DeleteResult {
    .deleted
  }
}

private actor HookRecorder {
  var applied: [HookRecord] = []
  var deletedIds: [String] = []
  var finalizedIds: [String] = []
  var filteredDeletedFlags: [Bool] = []

  func recordApplied(_ record: HookRecord) { applied.append(record) }
  func recordDeleted(_ id: String) { deletedIds.append(id) }
  func recordFinalized(_ id: String) { finalizedIds.append(id) }
  func recordFilter(_ deleted: Bool) { filteredDeletedFlags.append(deleted) }

  func snapshot() -> (
    applied: [HookRecord], deletedIds: [String], finalizedIds: [String], filtered: [Bool]
  ) {
    (applied, deletedIds, finalizedIds, filteredDeletedFlags)
  }
}

final class ConsumerSyncHooksTests: XCTestCase {
  private func makeStore() throws -> (ConfigStore, URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AppleSyncKitHookTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (
      ConfigStore(namespace: "hooks", prefix: "TEST", rootDirectory: root),
      root
    )
  }

  private var config: SyncConfig {
    SyncConfig(apiURL: "https://sync.example.com", apiToken: "token", deviceId: "device")
  }

  func testSnapshotSourceTransformsPayloadsAndRecordsLocalSnapshotsAndMetadata() async throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let remote = HookRemoteClient()
    let recorder = HookRecorder()
    let local = HookRecord(id: "local", value: "local-value")
    let wirePull = HookRecord(id: "remote", value: "wire-pull")
    await remote.setPullItems([
      PullItem(
        id: "remote",
        data: wirePull,
        deleted: false,
        updatedAt: "2026-06-01T00:00:00Z",
        lastModified: "2026-06-01T00:00:00Z"
      )
    ])
    let source = SnapshotSyncSource<HookRecord>(
      entityName: "hooks",
      fetchRecords: { [local] },
      getId: { $0.id },
      transformForPush: { HookRecord(id: $0.id, value: "wire-push") },
      transformForPull: { HookRecord(id: $0.id, value: "local-pull") },
      recordPushMetadata: { _, remoteId, state in
        state.recordDateRange(SyncDateRange(start: "push", end: "push"), for: remoteId)
      },
      recordPullMetadata: { _, remoteId, state in
        state.recordDateRange(SyncDateRange(start: "pull", end: "pull"), for: remoteId)
      },
      applyUpsert: { record, _, _, _ in
        await recorder.recordApplied(record)
        return nil
      },
      applyDelete: { _ in }
    )

    _ = try await SyncCoordinator(config: config, store: store, client: remote).sync(source: source)

    let pushedRecords = await remote.pushedRecords
    let recorded = await recorder.snapshot()
    XCTAssertEqual(pushedRecords, [HookRecord(id: "local", value: "wire-push")])
    XCTAssertEqual(recorded.applied, [HookRecord(id: "remote", value: "local-pull")])
    let state = try XCTUnwrap(try store.journal.load().entityStates["hooks"])
    let localSnapshot = try XCTUnwrap(state.snapshotsByRemoteId["local"])
    let pulledSnapshot = try XCTUnwrap(state.snapshotsByRemoteId["remote"])
    XCTAssertTrue(localSnapshot.contains("local-value"))
    XCTAssertFalse(localSnapshot.contains("wire-push"))
    XCTAssertTrue(pulledSnapshot.contains("local-pull"))
    XCTAssertEqual(state.dateRangeByRemoteId["local"], SyncDateRange(start: "push", end: "push"))
    XCTAssertEqual(state.dateRangeByRemoteId["remote"], SyncDateRange(start: "pull", end: "pull"))
  }

  func testPullItemFilterRunsBeforeTombstoneAndUpsertBookkeeping() async throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    var journal = SyncJournalState()
    journal.idMappings["hooks"] = ["delete": "local-delete"]
    journal.entityStates["hooks"] = SyncEntityState(knownRemoteIds: ["delete"])
    try store.journal.commitCheckpoint(journal)
    let remote = HookRemoteClient()
    await remote.setPullItems([
      PullItem(
        id: "delete", data: HookRecord(id: "delete", value: "x"), deleted: true,
        updatedAt: "2026-06-01T00:00:00Z", lastModified: "2026-06-01T00:00:00Z"),
      PullItem(
        id: "upsert", data: HookRecord(id: "upsert", value: "x"), deleted: false,
        updatedAt: "2026-06-01T00:00:00Z", lastModified: "2026-06-01T00:00:00Z"),
    ])
    let recorder = HookRecorder()
    let source = SnapshotSyncSource<HookRecord>(
      entityName: "hooks",
      fetchRecords: { [] },
      getId: { $0.id },
      shouldApplyPulledItem: { item in
        await recorder.recordFilter(item.deleted)
        return false
      },
      applyUpsert: { record, _, _, _ in
        await recorder.recordApplied(record)
        return nil
      },
      applyDelete: { id in await recorder.recordDeleted(id) }
    )

    let result = try await SyncCoordinator(config: config, store: store, client: remote)
      .pull(source: source)

    XCTAssertEqual(result, PullSummary(pulled: 0, deleted: 0, skipped: 2))
    let recorded = await recorder.snapshot()
    XCTAssertEqual(recorded.filtered, [true, false])
    XCTAssertTrue(recorded.applied.isEmpty)
    XCTAssertTrue(recorded.deletedIds.isEmpty)
    let saved = try store.journal.load()
    XCTAssertEqual(saved.cursors["hooks"], "hook-cursor")
    XCTAssertEqual(saved.idMappings["hooks"]?["delete"], "local-delete")
    XCTAssertTrue(saved.entityStates["hooks"]?.knownRemoteIds.contains("delete") == true)
  }

  func testNotFoundTombstoneContinuesAndRemovesMapping() async throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    var journal = SyncJournalState()
    journal.idMappings["hooks"] = ["remote": "local"]
    journal.entityStates["hooks"] = SyncEntityState(knownRemoteIds: ["remote"])
    try store.journal.commitCheckpoint(journal)
    let remote = HookRemoteClient()
    await remote.setPullItems([
      PullItem(
        id: "remote", data: HookRecord(id: "remote", value: "x"), deleted: true,
        updatedAt: "2026-06-01T00:00:00Z", lastModified: "2026-06-01T00:00:00Z")
    ])
    let source = SnapshotSyncSource<HookRecord>(
      entityName: "hooks",
      fetchRecords: { [] },
      getId: { $0.id },
      isNotFound: { _ in true },
      applyUpsert: { _, _, _, _ in nil },
      applyDelete: { _ in throw HookError.missing }
    )

    let result = try await SyncCoordinator(config: config, store: store, client: remote)
      .pull(source: source)

    XCTAssertEqual(result.deleted, 1)
    let saved = try store.journal.load()
    XCTAssertNil(saved.idMappings["hooks"]?["remote"])
    XCTAssertFalse(saved.entityStates["hooks"]?.knownRemoteIds.contains("remote") == true)
  }

  func testSnapshotSourceAcceptRemotePolicyForExistingRecordWithoutTimestamp() async throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let remote = HookRemoteClient()
    await remote.setPullItems([
      PullItem(
        id: "same", data: HookRecord(id: "same", value: "remote"), deleted: false,
        updatedAt: "2026-06-01T00:00:00Z", lastModified: "2026-06-01T00:00:00Z")
    ])
    let recorder = HookRecorder()
    let source = SnapshotSyncSource<HookRecord>(
      entityName: "hooks",
      fetchRecords: { [HookRecord(id: "same", value: "local")] },
      getId: { $0.id },
      existingRecordWithoutTimestamp: .acceptRemote,
      applyUpsert: { record, _, _, _ in
        await recorder.recordApplied(record)
        return nil
      },
      applyDelete: { _ in }
    )

    let result = try await SyncCoordinator(config: config, store: store, client: remote)
      .pull(source: source)

    XCTAssertEqual(result.pulled, 1)
    let recorded = await recorder.snapshot()
    XCTAssertEqual(recorded.applied, [HookRecord(id: "same", value: "remote")])
  }

  func testSnapshotDeletionFilterAndCustomFinalizeDeletion() async throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    var state = SyncEntityState(knownRemoteIds: ["keep", "delete"])
    try state.recordSyncedValue(
      HookRecord(id: "keep", value: "kept"), remoteId: "keep",
      lastModified: "2026-06-01T00:00:00Z", volatileKeys: [])
    var journal = SyncJournalState(entityStates: ["hooks": state])
    journal.idMappings["hooks"] = ["delete": "local-delete"]
    try store.journal.commitCheckpoint(journal)
    let recorder = HookRecorder()
    let source = SnapshotSyncSource<HookRecord>(
      entityName: "hooks",
      fetchRecords: { [HookRecord(id: "keep", value: "kept")] },
      getId: { $0.id },
      filterDeletionCandidates: { candidates, _ in candidates.filter { $0 == "delete" } },
      finalizeDeleted: { id in await recorder.recordFinalized(id) },
      applyUpsert: { _, _, _, _ in nil },
      applyDelete: { _ in }
    )

    _ = try await SyncCoordinator(config: config, store: store, client: HookRemoteClient())
      .push(source: source)

    let recorded = await recorder.snapshot()
    XCTAssertEqual(recorded.finalizedIds, ["local-delete"])
  }
}
