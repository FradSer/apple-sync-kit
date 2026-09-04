import SQLite
import XCTest

@testable import AppleSyncKit

private struct TestNote: Codable, Sendable, Equatable {
  let id: String
  let title: String
  let content: String
}

final class LocalSyncSourceTests: XCTestCase {
  func testSnapshotSyncSourcePendingModificationsAndDeletions() async throws {
    let item1 = TestNote(id: "loc1", title: "Note 1", content: "Unchanged")
    let item2 = TestNote(id: "loc2", title: "Note 2", content: "Modified")

    var entityState = SyncEntityState()
    try entityState.recordSyncedValue(
      item1,
      remoteId: "rem1",
      lastModified: "2026-06-01T00:00:00Z",
      volatileKeys: []
    )
    entityState.recordKnownRemoteId("remOld")

    let context = SyncAdapterContext(
      localToRemoteId: ["loc1": "rem1", "loc2": "rem2"],
      entityState: entityState
    )

    let source = SnapshotSyncSource<TestNote>(
      entityName: "notes",
      fetchRecords: { [item1, item2] },
      getId: { $0.id },
      volatileKeys: [],
      applyUpsert: { _, _, _, _ in nil as String? },
      applyDelete: { _ in }
    )

    let changes = try await source.changes(context: context)
    XCTAssertEqual(changes.records.count, 1)
    XCTAssertEqual(changes.records.first?.id, "loc2")
    XCTAssertNotNil(changes.lastModifiedByRemoteId["rem2"])
    XCTAssertEqual(changes.deletionCandidates, ["remOld"])
  }

  func testFlaggedSyncSourcePendingModificationsAndAcknowledge() async throws {
    let db = try Connection(.inMemory)
    try db.run(
      """
      CREATE TABLE test_notes (
        id TEXT PRIMARY KEY,
        data TEXT NOT NULL,
        last_modified TEXT NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0,
        is_local_only INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
      )
      """
    )
    let store = SQLiteSyncStore(connection: db)

    let note1 = TestNote(id: "n1", title: "Local Note", content: "Draft")
    let note2 = TestNote(id: "n2", title: "Synced Note", content: "Clean")
    let note3 = TestNote(id: "n3", title: "Tombstone Note", content: "To be deleted")
    try store.upsertRecord(
      table: "test_notes", id: "n1", data: note1, lastModified: "2026-06-01T00:00:00Z")
    try store.upsertRecord(
      table: "test_notes", id: "n2", data: note2, lastModified: "2026-06-01T00:00:00Z")
    try store.upsertRecord(
      table: "test_notes", id: "n3", data: note3, lastModified: "2026-06-01T00:00:00Z")
    try db.run("UPDATE test_notes SET is_local_only = 1 WHERE id = 'n1'")
    try db.run("UPDATE test_notes SET deleted = 1 WHERE id = 'n3'")

    let source = FlaggedSyncSource<TestNote>(
      entityName: "notes",
      table: "test_notes",
      store: store,
      getId: { $0.id }
    )
    let context = SyncAdapterContext(
      localToRemoteId: ["n3": "rem_n3"],
      entityState: SyncEntityState()
    )

    let changes = try await source.changes(context: context)
    XCTAssertEqual(changes.records.count, 1)
    XCTAssertEqual(changes.records.first?.id, "n1")
    XCTAssertEqual(changes.deletionCandidates, ["rem_n3"])
    XCTAssertEqual(changes.deletionLastModifiedByRemoteId["rem_n3"], "2026-06-01T00:00:00Z")

    try await source.acknowledgePushed(localIds: ["n1"])
    let emptyChanges = try await source.changes(context: context)
    XCTAssertTrue(emptyChanges.records.isEmpty)

    try await source.finalizeDeleted(localId: "n3")
    let deletedRecords = try store.fetchDeletedRecords(from: "test_notes")
    XCTAssertTrue(deletedRecords.isEmpty)
  }

  func testFlaggedSyncSourceCombinesMissingKnownRecordsAndTombstones() async throws {
    let db = try Connection(.inMemory)
    try db.run(
      """
      CREATE TABLE test_notes (
        id TEXT PRIMARY KEY,
        data TEXT NOT NULL,
        last_modified TEXT NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0,
        is_local_only INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
      )
      """
    )
    let store = SQLiteSyncStore(connection: db)
    let present = TestNote(id: "local-present", title: "Present", content: "Kept")
    let tombstone = TestNote(id: "local-deleted", title: "Deleted", content: "Gone")
    try store.upsertRecord(
      table: "test_notes", id: present.id, data: present,
      lastModified: "2026-06-01T00:00:00Z")
    try store.upsertRecord(
      table: "test_notes", id: tombstone.id, data: tombstone,
      lastModified: "2026-06-01T00:00:00Z")
    try db.run("UPDATE test_notes SET deleted = 1 WHERE id = 'local-deleted'")
    let source = FlaggedSyncSource<TestNote>(
      entityName: "notes", table: "test_notes", store: store, getId: { $0.id })
    let state = SyncEntityState(
      knownRemoteIds: ["remote-present", "remote-missing", "remote-deleted"])
    let context = SyncAdapterContext(
      localToRemoteId: [
        "local-present": "remote-present",
        "local-deleted": "remote-deleted",
      ],
      entityState: state
    )

    let changes = try await source.changes(context: context)

    XCTAssertEqual(changes.deletionCandidates, ["remote-deleted", "remote-missing"])
    XCTAssertEqual(
      changes.deletionLastModifiedByRemoteId["remote-deleted"],
      "2026-06-01T00:00:00Z")
    XCTAssertNotNil(changes.deletionLastModifiedByRemoteId["remote-missing"])
  }

  func testFlaggedSyncSourceExposesConsumerHooks() async throws {
    let db = try Connection(.inMemory)
    try db.run(
      """
      CREATE TABLE test_notes (
        id TEXT PRIMARY KEY,
        data TEXT NOT NULL,
        last_modified TEXT NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0,
        is_local_only INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
      )
      """
    )
    let store = SQLiteSyncStore(connection: db)
    let note = TestNote(id: "n1", title: "Local", content: "Draft")
    try store.upsertRecord(
      table: "test_notes", id: "n1", data: note, lastModified: "2026-06-01T00:00:00Z")
    try db.run("UPDATE test_notes SET deleted = 1 WHERE id = 'n1'")
    let finalized = XCTestExpectation(description: "custom finalize")
    let source = FlaggedSyncSource<TestNote>(
      entityName: "notes",
      table: "test_notes",
      store: store,
      getId: { $0.id },
      transformForPush: { TestNote(id: $0.id, title: "Wire", content: $0.content) },
      shouldApplyPulledItem: { !$0.deleted },
      filterDeletionCandidates: { _, _ in [] },
      finalizeDeleted: { id in
        XCTAssertEqual(id, "n1")
        finalized.fulfill()
      }
    )

    let transformed = try await source.transformForPush(note)
    XCTAssertEqual(transformed.title, "Wire")
    let shouldApply = try await source.shouldApplyPulledItem(
      PullItem(id: "n1", data: note, deleted: true, updatedAt: "now", lastModified: "now"))
    XCTAssertFalse(shouldApply)
    let changes = try await source.changes(
      context: SyncAdapterContext(localToRemoteId: [:], entityState: SyncEntityState()))
    let filtered = try await source.filterDeletionCandidates(
      changes.deletionCandidates,
      context: SyncAdapterContext(localToRemoteId: [:], entityState: SyncEntityState())
    )
    XCTAssertTrue(filtered.isEmpty)
    try await source.finalizeDeleted(localId: "n1")
    await fulfillment(of: [finalized], timeout: 1)
    XCTAssertEqual(try store.fetchDeletedRecords(from: "test_notes").count, 1)
  }

  func testFlaggedSyncSourceUsesMappedLocalIDAndRemoteTimestamp() async throws {
    let db = try Connection(.inMemory)
    let testNotesTable = Table("test_notes")
    let idColumn = Expression<String>("id")
    let lastModifiedColumn = Expression<String>("last_modified")
    try db.run(
      """
      CREATE TABLE test_notes (
        id TEXT PRIMARY KEY,
        data TEXT NOT NULL,
        last_modified TEXT NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0,
        is_local_only INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
      )
      """
    )
    let store = SQLiteSyncStore(connection: db)
    let source = FlaggedSyncSource<TestNote>(
      entityName: "notes",
      table: "test_notes",
      store: store,
      getId: { $0.id }
    )
    let remoteRecord = TestNote(id: "remote-id", title: "Remote", content: "Updated")

    _ = try await source.applyRemoteUpsert(
      remoteRecord,
      localId: "local-id",
      remoteId: "remote-id",
      lastModified: "2026-06-10T00:00:00Z"
    )

    guard let row = try db.pluck(testNotesTable.filter(testNotesTable[idColumn] == "local-id"))
    else {
      return XCTFail("Expected mapped local row")
    }
    XCTAssertEqual(row[idColumn], "local-id")
    XCTAssertEqual(row[lastModifiedColumn], "2026-06-10T00:00:00Z")
  }
}
