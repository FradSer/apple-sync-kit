import XCTest

@testable import AppleSyncKit

final class ConfigStoreTests: XCTestCase {
  private let store = ConfigStore(namespace: "note-sync", prefix: "NOTE")

  func testEnvKeyNames() {
    XCTAssertEqual(store.apiURLEnvKey, "NOTE_SYNC_API_URL")
    XCTAssertEqual(store.apiTokenEnvKey, "NOTE_SYNC_API_TOKEN")
    XCTAssertEqual(store.deviceIdEnvKey, "NOTE_SYNC_DEVICE_ID")
  }

  func testLoadsFromBothEnvVars() throws {
    let env = [
      "NOTE_SYNC_API_URL": "https://example.workers.dev",
      "NOTE_SYNC_API_TOKEN": "tok",
      "NOTE_SYNC_DEVICE_ID": "laptop",
    ]
    let config = try store.loadFromEnvironment(env)
    XCTAssertEqual(config?.apiURL, "https://example.workers.dev")
    XCTAssertEqual(config?.apiToken, "tok")
    XCTAssertEqual(config?.deviceId, "laptop")
  }

  func testReturnsNilWhenNeitherSet() throws {
    XCTAssertNil(try store.loadFromEnvironment([:]))
  }

  func testThrowsWhenOnlyOneSet() {
    XCTAssertThrowsError(try store.loadFromEnvironment(["NOTE_SYNC_API_URL": "https://x.dev"]))
  }

  func testRejectsNonHTTPSURL() {
    let env = ["NOTE_SYNC_API_URL": "http://insecure.dev", "NOTE_SYNC_API_TOKEN": "tok"]
    XCTAssertThrowsError(try store.loadFromEnvironment(env))
  }

  func testValidateAPIURL() {
    XCTAssertNoThrow(try store.validateAPIURL("https://ok.dev"))
    XCTAssertThrowsError(try store.validateAPIURL("ftp://nope.dev"))
  }
}
