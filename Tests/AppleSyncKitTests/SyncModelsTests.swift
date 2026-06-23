import XCTest

@testable import AppleSyncKit

private struct Item: Codable {
  let id: String
  let title: String
  let body: String
  let modifiedDate: String?
}

final class SyncModelsTests: XCTestCase {
  private let volatile: Set<String> = ["id", "modifiedDate"]

  // MARK: - Mapping inversion

  func testInvertRoundTrips() {
    let result = SyncMapping.inverted(["r1": "l1", "r2": "l2"])
    XCTAssertEqual(result.mapping, ["l1": "r1", "l2": "r2"])
    XCTAssertTrue(result.collisions.isEmpty)
  }

  func testInvertReportsCollisionDeterministically() {
    let result = SyncMapping.inverted(["rB": "shared", "rA": "shared"])
    XCTAssertEqual(result.mapping["shared"], "rA")
    XCTAssertEqual(result.collisions.first?.keptRemoteId, "rA")
    XCTAssertEqual(result.collisions.first?.droppedRemoteId, "rB")
  }

  // MARK: - Snapshot change detection

  func testSnapshotIgnoresVolatileKeys() throws {
    let base = Item(id: "a", title: "T", body: "b", modifiedDate: "2026-01-02")
    let other = Item(id: "z", title: "T", body: "b", modifiedDate: "2030-10-10")
    var state = SyncEntityState()
    try state.recordSyncedValue(
      base, remoteId: "remote", lastModified: "2026-01-02", volatileKeys: volatile)
    let unchanged = try state.lastModified(
      for: other, remoteId: "remote", fallback: "FALLBACK", volatileKeys: volatile)
    XCTAssertEqual(unchanged, "2026-01-02")
  }

  func testSnapshotDetectsContentChange() throws {
    let base = Item(id: "a", title: "T", body: "b", modifiedDate: nil)
    let changed = Item(id: "a", title: "T", body: "DIFFERENT", modifiedDate: nil)
    var state = SyncEntityState()
    try state.recordSyncedValue(
      base, remoteId: "remote", lastModified: "2026-01-02", volatileKeys: volatile)
    let result = try state.lastModified(
      for: changed, remoteId: "remote", fallback: "FALLBACK", volatileKeys: volatile)
    XCTAssertEqual(result, "FALLBACK")
  }

  func testDeletionCandidates() {
    var state = SyncEntityState()
    state.recordKnownRemoteId("r1")
    state.recordKnownRemoteId("r2")
    state.recordKnownRemoteId("r3")
    XCTAssertEqual(state.deletionCandidates(currentRemoteIds: ["r1", "r3"]), ["r2"])
  }

  func testDecodesLegacyStateWithoutDateRange() throws {
    // State written before `dateRangeByRemoteId` existed (e.g. note's pre-kit
    // state.json) must still decode -- the missing key defaults to empty.
    let legacy = """
      {"knownRemoteIds":["r1"],"lastModifiedByRemoteId":{"r1":"2026-01-01"},\
      "snapshotsByRemoteId":{"r1":"{}"}}
      """
    let state = try JSONDecoder().decode(
      SyncEntityState.self, from: Data(legacy.utf8))
    XCTAssertEqual(state.knownRemoteIds, ["r1"])
    XCTAssertEqual(state.lastModifiedByRemoteId["r1"], "2026-01-01")
    XCTAssertTrue(state.dateRangeByRemoteId.isEmpty)
  }

  func testDecodesEmptyStateObject() throws {
    let state = try JSONDecoder().decode(SyncEntityState.self, from: Data("{}".utf8))
    XCTAssertTrue(state.knownRemoteIds.isEmpty)
    XCTAssertTrue(state.dateRangeByRemoteId.isEmpty)
  }

  // MARK: - Timestamp parsing

  func testTimestampParsing() {
    XCTAssertNotNil(SyncTimestamp.parse("2026-03-10T14:00:00Z"))
    XCTAssertNotNil(SyncTimestamp.parse("2026-03-10T14:00:00.123Z"))
    XCTAssertNotNil(SyncTimestamp.parse("2026-03-10 14:00:00"))
    XCTAssertNil(SyncTimestamp.parse(""))
    XCTAssertNil(SyncTimestamp.parse("nonsense"))
  }

  // MARK: - Cursor policy

  func testCursorPolicy() {
    XCTAssertEqual(
      SyncCursorPolicy.nextCursor(currentCursor: "1|a", responseCursor: "2|b", hadFailures: false),
      "2|b")
    XCTAssertEqual(
      SyncCursorPolicy.nextCursor(currentCursor: "1|a", responseCursor: "2|b", hadFailures: true),
      "1|a")
  }
}
