import XCTest

@testable import AppleSyncKit

final class SyncStateJournalTests: XCTestCase {
  private var tempDirURL: URL!
  private var journalPath: String!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempDirURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("AppleSyncKitJournalTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    journalPath = tempDirURL.appendingPathComponent("sync-state.json").path
  }

  override func tearDownWithError() throws {
    // Restore permissions if needed before teardown deletion
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalPath)
    try? FileManager.default.removeItem(at: tempDirURL)
    try super.tearDownWithError()
  }

  func testCommitAndReloadRoundTrip() throws {
    let journal = SyncStateJournal(journalPath: journalPath)
    var state = try journal.load()
    XCTAssertEqual(state, SyncJournalState())

    let entityState = SyncEntityState(
      knownRemoteIds: ["rem1"],
      lastModifiedByRemoteId: ["rem1": "2026-06-01T00:00:00Z"]
    )
    state.entityStates["notes"] = entityState
    state.idMappings["notes"] = ["rem1": "loc1"]
    state.cursors["notes"] = "cur_123"

    try journal.commitCheckpoint(state)

    XCTAssertTrue(FileManager.default.fileExists(atPath: journalPath))

    // Verify file permissions are 0o600
    let attributes = try FileManager.default.attributesOfItem(atPath: journalPath)
    let posixPermissions = attributes[.posixPermissions] as? NSNumber
    XCTAssertEqual(posixPermissions?.int16Value, 0o600)

    // Verify round-trip loading
    let reloaded = try journal.load()
    XCTAssertEqual(reloaded, state)
    XCTAssertEqual(reloaded.entityStates["notes"]?.knownRemoteIds, ["rem1"])
    XCTAssertEqual(reloaded.idMappings["notes"]?["rem1"], "loc1")
    XCTAssertEqual(reloaded.cursors["notes"], "cur_123")
  }

  func testCorruptedJournalThrowsStrictError() throws {
    let badData = Data("invalid-non-json-content".utf8)
    try badData.write(to: URL(fileURLWithPath: journalPath))

    let journal = SyncStateJournal(journalPath: journalPath)
    XCTAssertThrowsError(try journal.load()) { error in
      guard case SyncError.unknown(let message) = error else {
        return XCTFail("Expected SyncError.unknown, got \(error)")
      }
      XCTAssertTrue(message.contains("Could not parse"))
    }
  }

  func testUnreadableJournalThrowsStrictError() throws {
    let data = Data("{}".utf8)
    try data.write(to: URL(fileURLWithPath: journalPath))
    let journal = SyncStateJournal(journalPath: journalPath) { _ in
      throw CocoaError(.fileReadNoPermission)
    }

    XCTAssertThrowsError(try journal.load()) { error in
      guard case SyncError.unknown(let message) = error else {
        return XCTFail("Expected SyncError.unknown, got \(error)")
      }
      XCTAssertTrue(message.contains("Cannot read sync journal"))
    }
  }
}
