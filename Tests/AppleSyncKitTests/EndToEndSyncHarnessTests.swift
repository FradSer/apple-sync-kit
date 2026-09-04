import XCTest

@testable import AppleSyncKit

private struct HarnessNote: Codable, Sendable, Equatable {
  let id: String
  let title: String
  let content: String
}

private actor MockRemoteClient: SyncRemoteClient {
  var pushedItemIds: [String] = []
  var deletedRemoteIds: [String] = []
  var pullItemsToReturn: [PullItem<HarnessNote>] = []
  var pullCallCount = 0

  func setPullItems(_ items: [PullItem<HarnessNote>]) {
    pullItemsToReturn = items
  }

  func push<T: Codable & Sendable>(
    entity: String,
    items: [T],
    id: @Sendable (T) -> String,
    idOverrides: [String: String],
    lastModifiedByRemoteId: [String: String]
  ) async throws -> PushResult {
    for item in items {
      let localId = id(item)
      pushedItemIds.append(idOverrides[localId] ?? localId)
    }
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
    pullCallCount += 1
    let items = pullItemsToReturn.compactMap { $0 as? PullItem<T> }
    return PullResponse(items: items, cursor: "cur_end", hasMore: false)
  }

  func delete(entity: String, id: String, lastModified: String?) async throws -> DeleteResult {
    deletedRemoteIds.append(id)
    return .deleted
  }
}

private struct MixedResultRemoteClient: SyncRemoteClient {
  func push<T: Codable & Sendable>(
    entity: String,
    items: [T],
    id: @Sendable (T) -> String,
    idOverrides: [String: String],
    lastModifiedByRemoteId: [String: String]
  ) async throws -> PushResult {
    let accepted = items.first.map { idOverrides[id($0)] ?? id($0) }
    return PushResult(
      synced: accepted == nil ? 0 : 1, skipped: items.count - (accepted == nil ? 0 : 1),
      syncedIds: accepted.map { [$0] } ?? [])
  }

  func pull<T: Codable & Sendable>(
    entity: String,
    cursor: String?,
    excludeOwnWrites: Bool
  ) async throws -> PullResponse<T> {
    PullResponse(items: [], cursor: cursor ?? "", hasMore: false)
  }

  func delete(entity: String, id: String, lastModified: String?) async throws -> DeleteResult {
    .deleted
  }
}

private actor InMemorySyncSource: LocalSyncSource {
  typealias Record = HarnessNote

  nonisolated let entityName = "notes"
  var records: [HarnessNote]
  var localTimestamps: [String: String]
  var unknownTimestampIds: Set<String>
  var acknowledgedLocalIds: [String] = []
  var upsertedRecords: [HarnessNote] = []
  var deletedLocalIds: [String] = []

  init(
    records: [HarnessNote] = [],
    localTimestamps: [String: String] = [:],
    unknownTimestampIds: Set<String> = []
  ) {
    self.records = records
    self.localTimestamps = localTimestamps
    self.unknownTimestampIds = unknownTimestampIds
  }

  nonisolated func getLocalId(_ record: HarnessNote) -> String {
    record.id
  }

  func localRecordState(for localId: String) async throws -> LocalRecordState {
    guard records.contains(where: { $0.id == localId }) else { return .absent }
    if unknownTimestampIds.contains(localId) { return .unknown }
    guard let timestamp = localTimestamps[localId] else { return .unknown }
    return .timestamp(timestamp)
  }

  func changes(context: SyncAdapterContext) async throws -> LocalSyncChanges<HarnessNote> {
    let fallback = ISO8601DateFormatter.syncISO8601.string(from: Date())
    var pending = [HarnessNote]()
    var timestamps = [String: String]()
    for record in records {
      let remoteId = context.localToRemoteId[record.id] ?? record.id
      if context.entityState.lastModifiedByRemoteId[remoteId] == nil {
        pending.append(record)
        timestamps[remoteId] = fallback
      }
    }
    let currentRemoteIds = Set(records.map { context.localToRemoteId[$0.id] ?? $0.id })
    let deletions = context.entityState.knownRemoteIds.subtracting(currentRemoteIds).sorted()
    return LocalSyncChanges(
      records: pending,
      lastModifiedByRemoteId: timestamps,
      deletionCandidates: deletions
    )
  }

  func acknowledgePushed(localIds: [String]) async throws {
    acknowledgedLocalIds.append(contentsOf: localIds)
  }

  func finalizeDeleted(localId: String) async throws {
    deletedLocalIds.append(localId)
  }

  func applyRemoteUpsert(
    _ record: HarnessNote, localId: String, remoteId: String, lastModified: String
  ) async throws -> String? {
    upsertedRecords.append(record)
    return nil
  }

  func applyRemoteDelete(localId: String) async throws {
    deletedLocalIds.append(localId)
    records.removeAll { $0.id == localId }
  }
}

final class EndToEndSyncHarnessTests: XCTestCase {
  private var tempDirURL: URL!
  private var store: ConfigStore!
  private var config: SyncConfig!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempDirURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("AppleSyncKitE2ETests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)

    store = ConfigStore(
      namespace: "test-e2e",
      prefix: "TEST",
      rootDirectory: tempDirURL
    )
    config = SyncConfig(
      apiURL: "https://sync.example.com",
      apiToken: "test-token",
      deviceId: "test-device"
    )
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDirURL)
    try super.tearDownWithError()
  }

  func testBidirectionalSyncLifecycle() async throws {
    let mockClient = MockRemoteClient()
    let local1 = HarnessNote(id: "n_loc1", title: "Note 1", content: "Content 1")
    let local2 = HarnessNote(id: "n_loc2", title: "Note 2", content: "Content 2")
    let remote = HarnessNote(id: "n_remote", title: "Remote", content: "Pulled")
    await mockClient.setPullItems([
      PullItem(
        id: "n_remote",
        data: remote,
        deleted: false,
        updatedAt: "2026-06-01T00:00:00Z",
        lastModified: "2026-06-01T00:00:00Z"
      )
    ])
    let source = InMemorySyncSource(records: [local1, local2])
    let coordinator = SyncCoordinator(config: config, store: store, client: mockClient)

    let summary = try await coordinator.sync(source: source)

    XCTAssertEqual(summary.push.synced, 2)
    XCTAssertEqual(summary.pull.pulled, 1)
    let pushedIds = await mockClient.pushedItemIds
    let acknowledgedIds = await source.acknowledgedLocalIds
    XCTAssertEqual(Set(pushedIds), Set(["n_loc1", "n_loc2"]))
    XCTAssertEqual(Set(acknowledgedIds), Set(["n_loc1", "n_loc2"]))
    let upsertedRecords = await source.upsertedRecords
    XCTAssertEqual(upsertedRecords, [remote])

    let journal = try store.journal.load()
    XCTAssertEqual(journal.cursors["notes"], "cur_end")
    XCTAssertTrue(journal.entityStates["notes"]?.knownRemoteIds.contains("n_loc1") == true)
    XCTAssertTrue(journal.entityStates["notes"]?.knownRemoteIds.contains("n_loc2") == true)
    XCTAssertTrue(journal.entityStates["notes"]?.knownRemoteIds.contains("n_remote") == true)
  }

  func testPushOnlyExecution() async throws {
    let mockClient = MockRemoteClient()
    let source = InMemorySyncSource(records: [
      HarnessNote(id: "n_push_only", title: "Only Push", content: "Content")
    ])
    let coordinator = SyncCoordinator(config: config, store: store, client: mockClient)

    let result = try await coordinator.push(source: source)

    XCTAssertEqual(result.synced, 1)
    let pushedIds = await mockClient.pushedItemIds
    let pullCallCount = await mockClient.pullCallCount
    XCTAssertEqual(pushedIds, ["n_push_only"])
    XCTAssertEqual(pullCallCount, 0)
    XCTAssertNil(try store.journal.load().cursors["notes"])
  }

  func testMixedPushResultAcknowledgesOnlyAcceptedRecords() async throws {
    let source = InMemorySyncSource(records: [
      HarnessNote(id: "n_accepted", title: "Accepted", content: "Content"),
      HarnessNote(id: "n_skipped", title: "Skipped", content: "Content"),
    ])
    let coordinator = SyncCoordinator(
      config: config,
      store: store,
      client: MixedResultRemoteClient()
    )

    let result = try await coordinator.push(source: source)

    XCTAssertEqual(result, PushResult(synced: 1, skipped: 1, syncedIds: ["n_accepted"]))
    let acknowledgedIds = await source.acknowledgedLocalIds
    XCTAssertEqual(acknowledgedIds, ["n_accepted"])
    let journal = try store.journal.load()
    XCTAssertTrue(journal.entityStates["notes"]?.knownRemoteIds.contains("n_accepted") == true)
    XCTAssertFalse(journal.entityStates["notes"]?.knownRemoteIds.contains("n_skipped") == true)
  }

  func testLWWConflictResolutionSkipsOlderRemoteUpdate() async throws {
    let mockClient = MockRemoteClient()
    let localNote = HarnessNote(id: "n_conflict", title: "Newer Local", content: "Keep this")
    let source = InMemorySyncSource(
      records: [localNote],
      localTimestamps: ["n_conflict": "2026-06-10T00:00:00Z"]
    )
    await mockClient.setPullItems([
      PullItem(
        id: "n_conflict",
        data: HarnessNote(id: "n_conflict", title: "Stale Remote", content: "Old"),
        deleted: false,
        updatedAt: "2026-06-01T00:00:00Z",
        lastModified: "2026-06-01T00:00:00Z"
      )
    ])
    let coordinator = SyncCoordinator(config: config, store: store, client: mockClient)

    let summary = try await coordinator.sync(source: source)

    XCTAssertEqual(summary.pull.skipped, 1)
    let upsertedRecords = await source.upsertedRecords
    XCTAssertTrue(upsertedRecords.isEmpty)
  }

  func testUnknownLocalTimestampSkipsRemoteUpdate() async throws {
    let mockClient = MockRemoteClient()
    let localNote = HarnessNote(id: "n_unknown", title: "Unsynced", content: "Keep this")
    let source = InMemorySyncSource(
      records: [localNote],
      unknownTimestampIds: ["n_unknown"]
    )
    await mockClient.setPullItems([
      PullItem(
        id: "n_unknown",
        data: HarnessNote(id: "n_unknown", title: "Remote", content: "Overwrite"),
        deleted: false,
        updatedAt: "2026-06-01T00:00:00Z",
        lastModified: "2026-06-01T00:00:00Z"
      )
    ])

    let summary = try await SyncCoordinator(config: config, store: store, client: mockClient)
      .pull(source: source)

    XCTAssertEqual(summary.skipped, 1)
    let upsertedRecords = await source.upsertedRecords
    XCTAssertTrue(upsertedRecords.isEmpty)
  }

  func testRemoteDeletionRemovesLocalRecordAndMapping() async throws {
    let mockClient = MockRemoteClient()
    let localNote = HarnessNote(id: "n_del", title: "To be deleted", content: "Content")
    let source = InMemorySyncSource(records: [localNote])
    var initialJournal = SyncJournalState()
    initialJournal.idMappings["notes"] = ["rem_del": "n_del"]
    initialJournal.entityStates["notes"] = SyncEntityState(knownRemoteIds: ["rem_del"])
    try store.journal.commitCheckpoint(initialJournal)
    await mockClient.setPullItems([
      PullItem(
        id: "rem_del",
        data: localNote,
        deleted: true,
        updatedAt: "2026-06-02T00:00:00Z",
        lastModified: "2026-06-02T00:00:00Z"
      )
    ])
    let coordinator = SyncCoordinator(config: config, store: store, client: mockClient)

    let summary = try await coordinator.pull(source: source)

    XCTAssertEqual(summary.deleted, 1)
    let deletedLocalIds = await source.deletedLocalIds
    XCTAssertEqual(deletedLocalIds, ["n_del"])
    let journal = try store.journal.load()
    XCTAssertNil(journal.idMappings["notes"]?["rem_del"])
    XCTAssertFalse(journal.entityStates["notes"]?.knownRemoteIds.contains("rem_del") == true)
  }
}
