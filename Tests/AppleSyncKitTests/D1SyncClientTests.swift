import XCTest

@testable import AppleSyncKit

final class D1SyncClientTests: XCTestCase {
  private func makeConfig() -> SyncConfig {
    SyncConfig(apiURL: "https://example.workers.dev", apiToken: "tok", deviceId: "test")
  }

  /// `withClient` must shut down the underlying HTTPClient even when `body`
  /// throws before any request is made. If shutdown were skipped, the
  /// HTTPClient's `deinit` traps with a fatalError and aborts the process.
  func testWithClientShutsDownWhenBodyThrows() async throws {
    struct Boom: Error {}
    let config = makeConfig()
    do {
      try await D1SyncClient.withClient(config: config) { _ in throw Boom() }
      XCTFail("Expected body to throw")
    } catch is Boom {
      // Expected — and the client was shut down (no fatalError).
    }
  }

  /// `withClient` returns the body's result and shuts down on the success path.
  func testWithClientReturnsResultOnSuccess() async throws {
    let config = makeConfig()
    let result = try await D1SyncClient.withClient(config: config) { _ in
      42
    }
    XCTAssertEqual(result, 42)
  }
}
