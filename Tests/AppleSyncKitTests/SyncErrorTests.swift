import XCTest

@testable import AppleSyncKit

final class SyncErrorTests: XCTestCase {
  func testAlreadyRunningDescription() {
    XCTAssertEqual(
      SyncError.alreadyRunning.errorDescription,
      "Another sync operation is already running")
  }

  func testAlreadyRunningIsNotNotFound() {
    XCTAssertFalse(SyncError.alreadyRunning.isNotFound)
  }
}
