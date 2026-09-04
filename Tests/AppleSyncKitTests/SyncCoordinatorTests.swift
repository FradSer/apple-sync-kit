import XCTest

@testable import AppleSyncKit

private struct TestItem: Codable, Sendable, Equatable {
  let id: String
  let title: String
}

private struct FinalizeFailure: Error {}

private actor DeleteRecordingRemoteClient: SyncRemoteClient {
  private(set) var deletedIds: [String] = []
  private(set) var deletionTimestamps: [String?] = []
  private let result: DeleteResult

  init(result: DeleteResult = .deleted) {
    self.result = result
  }

  func push<T: Codable & Sendable>(
    entity: String,
    items: [T],
    id: @Sendable (T) -> String,
    idOverrides: [String: String],
    lastModifiedByRemoteId: [String: String]
  ) async throws -> PushResult {
    PushResult(synced: 0, skipped: 0)
  }

  func pull<T: Codable & Sendable>(
    entity: String,
    cursor: String?,
    excludeOwnWrites: Bool
  ) async throws -> PullResponse<T> {
    PullResponse(items: [], cursor: cursor ?? "", hasMore: false)
  }

  func delete(entity: String, id: String, lastModified: String?) async throws -> DeleteResult {
    deletedIds.append(id)
    deletionTimestamps.append(lastModified)
    return result
  }
}

private actor FailingOnceFinalizer {
  private(set) var localIds: [String] = []

  func finalize(localId: String) throws {
    localIds.append(localId)
    if localIds.count == 1 { throw FinalizeFailure() }
  }
}

private struct TimestampedDeletionSource: LocalSyncSource {
  let entityName = "items"

  func getLocalId(_ record: TestItem) -> String { record.id }

  func changes(context: SyncAdapterContext) async throws -> LocalSyncChanges<TestItem> {
    LocalSyncChanges(
      records: [],
      lastModifiedByRemoteId: [:],
      deletionCandidates: ["remote-id"],
      deletionLastModifiedByRemoteId: ["remote-id": "2026-06-03T00:00:00Z"]
    )
  }

  func acknowledgePushed(localIds: [String]) async throws {}
  func finalizeDeleted(localId: String) async throws {}
  func applyRemoteUpsert(
    _ record: TestItem, localId: String, remoteId: String, lastModified: String
  ) async throws -> String? { nil }
  func applyRemoteDelete(localId: String) async throws {}
}

private struct EmptyRemoteClient: SyncRemoteClient {
  func push<T: Codable & Sendable>(
    entity: String,
    items: [T],
    id: @Sendable (T) -> String,
    idOverrides: [String: String],
    lastModifiedByRemoteId: [String: String]
  ) async throws -> PushResult {
    PushResult(synced: items.count, skipped: 0, syncedIds: items.map(id))
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

final class SyncCoordinatorTests: XCTestCase {
  private var tempDirURL: URL!
  private var store: ConfigStore!
  private var config: SyncConfig!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempDirURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("AppleSyncKitCoordinatorTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)

    store = ConfigStore(
      namespace: "test-coord-\(UUID().uuidString)",
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

  func testCallerManagedSessionUsesOneLockAcrossMultipleOperations() async throws {
    let coordinator = SyncCoordinator(config: config, store: store, client: EmptyRemoteClient())
    let source = SnapshotSyncSource<TestItem>(
      entityName: "items",
      fetchRecords: { [] },
      getId: { $0.id },
      applyUpsert: { _, _, _, _ in nil as String? },
      applyDelete: { _ in }
    )

    try await coordinator.withLock { session in
      _ = try await session.pull(source: source)
      _ = try await session.push(source: source)
    }

    let lockFd = try store.acquireLock()
    store.releaseLock(lockFd)
  }

  func testDeletionUsesSourceObservationTimestampInsteadOfLastSyncedTimestamp() async throws {
    var state = SyncEntityState()
    state.recordKnownRemoteId("remote-id")
    state.lastModifiedByRemoteId["remote-id"] = "2026-06-01T00:00:00Z"
    try store.journal.commitCheckpoint(SyncJournalState(entityStates: ["items": state]))
    let remote = DeleteRecordingRemoteClient()
    let source = TimestampedDeletionSource()

    _ = try await SyncCoordinator(config: config, store: store, client: remote).push(source: source)

    let timestamps = await remote.deletionTimestamps
    XCTAssertEqual(timestamps, ["2026-06-03T00:00:00Z"])
  }

  func testRejectedRemoteDeletePreservesCandidateWithoutFinalizing() async throws {
    var state = SyncEntityState()
    state.recordKnownRemoteId("remote-id")
    let initialJournal = SyncJournalState(
      entityStates: ["items": state],
      idMappings: ["items": ["remote-id": "local-id"]]
    )
    try store.journal.commitCheckpoint(initialJournal)
    let remote = DeleteRecordingRemoteClient(result: .rejected)
    let finalizer = FailingOnceFinalizer()
    let source = SnapshotSyncSource<TestItem>(
      entityName: "items",
      fetchRecords: { [] },
      getId: { $0.id },
      finalizeDeleted: { localId in try await finalizer.finalize(localId: localId) },
      applyUpsert: { _, _, _, _ in nil },
      applyDelete: { _ in }
    )

    _ = try await SyncCoordinator(config: config, store: store, client: remote).push(source: source)

    let journal = try store.journal.load()
    let finalizedIds = await finalizer.localIds
    XCTAssertTrue(finalizedIds.isEmpty)
    XCTAssertEqual(journal.idMappings["items"]?["remote-id"], "local-id")
    XCTAssertTrue(journal.entityStates["items"]?.knownRemoteIds.contains("remote-id") == true)
  }

  func testAlreadyAbsentRemoteDeleteFinalizesLocalBookkeeping() async throws {
    var state = SyncEntityState()
    state.recordKnownRemoteId("remote-id")
    try store.journal.commitCheckpoint(
      SyncJournalState(
        entityStates: ["items": state],
        idMappings: ["items": ["remote-id": "local-id"]]
      ))
    let remote = DeleteRecordingRemoteClient(result: .alreadyAbsent)
    let finalized = XCTestExpectation(description: "local deletion finalized")
    let source = SnapshotSyncSource<TestItem>(
      entityName: "items",
      fetchRecords: { [] },
      getId: { $0.id },
      finalizeDeleted: { localId in
        XCTAssertEqual(localId, "local-id")
        finalized.fulfill()
      },
      applyUpsert: { _, _, _, _ in nil },
      applyDelete: { _ in }
    )

    _ = try await SyncCoordinator(config: config, store: store, client: remote).push(source: source)

    await fulfillment(of: [finalized], timeout: 1)
    let journal = try store.journal.load()
    XCTAssertNil(journal.idMappings["items"]?["remote-id"])
    XCTAssertFalse(journal.entityStates["items"]?.knownRemoteIds.contains("remote-id") == true)
  }

  func testFailedFinalizePreservesMappedDeletionForRetry() async throws {
    var state = SyncEntityState()
    state.recordKnownRemoteId("remote-id")
    let initialJournal = SyncJournalState(
      entityStates: ["items": state],
      idMappings: ["items": ["remote-id": "local-id"]]
    )
    try store.journal.commitCheckpoint(initialJournal)
    let remote = DeleteRecordingRemoteClient()
    let finalizer = FailingOnceFinalizer()
    let source = SnapshotSyncSource<TestItem>(
      entityName: "items",
      fetchRecords: { [] },
      getId: { $0.id },
      finalizeDeleted: { localId in try await finalizer.finalize(localId: localId) },
      applyUpsert: { _, _, _, _ in nil },
      applyDelete: { _ in }
    )
    let coordinator = SyncCoordinator(config: config, store: store, client: remote)

    do {
      _ = try await coordinator.push(source: source)
      XCTFail("Expected first local finalization to fail")
    } catch is FinalizeFailure {}

    var journal = try store.journal.load()
    XCTAssertEqual(journal.idMappings["items"]?["remote-id"], "local-id")
    XCTAssertTrue(journal.entityStates["items"]?.knownRemoteIds.contains("remote-id") == true)

    _ = try await coordinator.push(source: source)

    let deletedIds = await remote.deletedIds
    let finalizedIds = await finalizer.localIds
    XCTAssertEqual(deletedIds, ["remote-id", "remote-id"])
    XCTAssertEqual(finalizedIds, ["local-id", "local-id"])
    journal = try store.journal.load()
    XCTAssertNil(journal.idMappings["items"]?["remote-id"])
    XCTAssertFalse(journal.entityStates["items"]?.knownRemoteIds.contains("remote-id") == true)
  }

  func testLockContentionThrowsAlreadyRunning() async throws {
    let coordinator = SyncCoordinator(config: config, store: store)

    // Acquire lock manually to simulate another running process
    let lockFd = try store.acquireLock()
    defer { store.releaseLock(lockFd) }

    let source = SnapshotSyncSource<TestItem>(
      entityName: "items",
      fetchRecords: { [] },
      getId: { $0.id },
      volatileKeys: [],
      applyUpsert: { _, _, _, _ in nil as String? },
      applyDelete: { _ in }
    )

    do {
      _ = try await coordinator.sync(source: source)
      XCTFail("Expected SyncError.alreadyRunning")
    } catch let error as SyncError {
      guard case .alreadyRunning = error else {
        return XCTFail("Expected .alreadyRunning, got \(error)")
      }
    }
  }
}
