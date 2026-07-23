import XCTest

@testable import AppleSyncKit

final class LaunchAgentManagerTests: XCTestCase {
  private let manager = LaunchAgentManager(
    launchAgentsDirectory: URL(fileURLWithPath: "/tmp/test-home/Library/LaunchAgents"))

  private func makeSpec() -> LaunchAgentSpec {
    LaunchAgentSpec(
      label: "ai.fradser.note-sync",
      programArguments: ["/usr/local/bin/note", "sync", "run", "--daemon"],
      startInterval: 1800,
      environment: [
        "NOTE_ENCRYPTION_KEY": "abc123=&<>",
        "PATH": "/usr/local/bin:/usr/bin:/bin",
      ],
      logPath: "/Users/test/.config/note-sync/logs/daemon.log")
  }

  func testPlistURLUsesLabel() {
    XCTAssertEqual(
      manager.plistURL(for: "ai.fradser.note-sync").path,
      "/tmp/test-home/Library/LaunchAgents/ai.fradser.note-sync.plist")
  }

  func testPlistContainsAllFields() {
    let plist = String(decoding: manager.plistData(for: makeSpec()), as: UTF8.self)
    XCTAssertTrue(plist.contains("<string>ai.fradser.note-sync</string>"))
    XCTAssertTrue(plist.contains("<string>/usr/local/bin/note</string>"))
    XCTAssertTrue(plist.contains("<string>sync</string>"))
    XCTAssertTrue(plist.contains("<string>--daemon</string>"))
    XCTAssertTrue(plist.contains("<integer>1800</integer>"))
    XCTAssertTrue(plist.contains("<key>RunAtLoad</key>"))
    XCTAssertTrue(plist.contains("<key>ProcessType</key>"))
    XCTAssertTrue(plist.contains("<string>Background</string>"))
    XCTAssertTrue(plist.contains("<key>LowPriorityIO</key>"))
    XCTAssertTrue(plist.contains("<key>NOTE_ENCRYPTION_KEY</key>"))
    XCTAssertTrue(plist.contains("<key>PATH</key>"))
    XCTAssertTrue(
      plist.contains("<string>/Users/test/.config/note-sync/logs/daemon.log</string>"))
  }

  func testPlistEscapesXMLSpecialCharacters() {
    let plist = String(decoding: manager.plistData(for: makeSpec()), as: UTF8.self)
    XCTAssertTrue(plist.contains("abc123=&amp;&lt;&gt;"))
    XCTAssertFalse(plist.contains("abc123=&<>"))
  }

  func testPlistEnvironmentKeysAreSorted() {
    let plist = String(decoding: manager.plistData(for: makeSpec()), as: UTF8.self)
    let keyIndex = plist.range(of: "<key>NOTE_ENCRYPTION_KEY</key>")!.lowerBound
    let pathIndex = plist.range(of: "<key>PATH</key>")!.lowerBound
    XCTAssertLessThan(keyIndex, pathIndex)
  }

  func testParseStatusWaitingWithExitCode() {
    let output = """
      gui/501/ai.fradser.note-sync = {
          active count = 0
          state = waiting
          last exit code = 0
      }
      """
    let status = LaunchAgentManager.parseStatus(output)
    XCTAssertEqual(status.state, .waiting)
    XCTAssertEqual(status.lastExitCode, 0)
  }

  func testParseStatusRunningWithoutExitCode() {
    let output = """
      gui/501/ai.fradser.note-sync = {
          active count = 1
          state = running
          pid = 12345
      }
      """
    let status = LaunchAgentManager.parseStatus(output)
    XCTAssertEqual(status.state, .running)
    XCTAssertNil(status.lastExitCode)
  }

  func testParseStatusUnknownState() {
    let status = LaunchAgentManager.parseStatus("state = spawned-on-demand\n")
    XCTAssertEqual(status.state, .unknown)
  }
}
