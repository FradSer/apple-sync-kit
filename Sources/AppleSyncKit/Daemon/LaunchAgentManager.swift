#if os(macOS)
  import Foundation

  // MARK: - Launch Agent Spec

  /// Entity-agnostic description of a launchd LaunchAgent that periodically runs
  /// a CLI sync command. The kit renders and installs the plist; the consuming
  /// project supplies the label, program arguments, and environment (typically
  /// the resolved binary path plus `<PREFIX>_ENCRYPTION_KEY`).
  public struct LaunchAgentSpec: Sendable {
    /// Reverse-DNS label, e.g. "ai.fradser.note-sync". Also the plist filename.
    public var label: String
    /// argv for the job: resolved binary path first, then arguments
    /// (e.g. ["/usr/local/bin/note", "sync", "run", "--daemon"]).
    public var programArguments: [String]
    /// `StartInterval` in seconds.
    public var startInterval: Int
    /// `EnvironmentVariables` for the job (encryption key, PATH, …).
    public var environment: [String: String]
    /// stdout/stderr destination for the job.
    public var logPath: String

    public init(
      label: String,
      programArguments: [String],
      startInterval: Int,
      environment: [String: String],
      logPath: String
    ) {
      self.label = label
      self.programArguments = programArguments
      self.startInterval = startInterval
      self.environment = environment
      self.logPath = logPath
    }
  }

  // MARK: - Launch Agent Status

  /// Parsed result of `launchctl print gui/<uid>/<label>`.
  public struct LaunchAgentStatus: Sendable, Equatable {
    public enum State: String, Sendable {
      case running
      case waiting
      case notLoaded
      case unknown
    }

    public var state: State
    /// Exit code of the most recent run, if the job has run.
    public var lastExitCode: Int?

    public init(state: State, lastExitCode: Int?) {
      self.state = state
      self.lastExitCode = lastExitCode
    }
  }

  // MARK: - Launch Agent Manager

  /// Renders, installs, removes, and inspects per-user LaunchAgents. Pure
  /// Foundation, entity-agnostic. `launchAgentsDirectory` is injectable so
  /// tests can verify path handling without touching the real
  /// `~/Library/LaunchAgents`.
  public struct LaunchAgentManager: Sendable {
    public var launchAgentsDirectory: URL

    public init(
      launchAgentsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents")
    ) {
      self.launchAgentsDirectory = launchAgentsDirectory
    }

    public func plistURL(for label: String) -> URL {
      launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    // MARK: Render

    /// Renders the plist XML. Hand-rolled to avoid a PropertyListSerialization
    /// dependency on dictionary key ordering; values are XML-escaped.
    public func plistData(for spec: LaunchAgentSpec) -> Data {
      func esc(_ value: String) -> String {
        value
          .replacingOccurrences(of: "&", with: "&amp;")
          .replacingOccurrences(of: "<", with: "&lt;")
          .replacingOccurrences(of: ">", with: "&gt;")
      }

      var lines: [String] = [
        #"<?xml version="1.0" encoding="UTF-8"?>"#,
        #"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#,
        #"<plist version="1.0">"#,
        "<dict>",
        "  <key>Label</key>",
        "  <string>\(esc(spec.label))</string>",
        "  <key>ProgramArguments</key>",
        "  <array>",
      ]
      for argument in spec.programArguments {
        lines.append("    <string>\(esc(argument))</string>")
      }
      lines.append(contentsOf: [
        "  </array>",
        "  <key>StartInterval</key>",
        "  <integer>\(spec.startInterval)</integer>",
        "  <key>RunAtLoad</key>",
        "  <true/>",
        "  <key>ProcessType</key>",
        "  <string>Background</string>",
        "  <key>LowPriorityIO</key>",
        "  <true/>",
        "  <key>EnvironmentVariables</key>",
        "  <dict>",
      ])
      for key in spec.environment.keys.sorted() {
        lines.append("    <key>\(esc(key))</key>")
        lines.append("    <string>\(esc(spec.environment[key]!))</string>")
      }
      lines.append(contentsOf: [
        "  </dict>",
        "  <key>StandardOutPath</key>",
        "  <string>\(esc(spec.logPath))</string>",
        "  <key>StandardErrorPath</key>",
        "  <string>\(esc(spec.logPath))</string>",
        "</dict>",
        "</plist>",
        "",
      ])
      return Data(lines.joined(separator: "\n").utf8)
    }

    // MARK: Install / Uninstall

    /// Writes the plist (0o600, atomic rename) and loads the agent, kicking off
    /// an immediate run. Idempotent: an existing agent is booted out first.
    public func install(_ spec: LaunchAgentSpec) throws {
      let plistPath = plistURL(for: spec.label)
      try writeAtomically(plistData(for: spec), to: plistPath)

      let domain = "gui/\(getuid())"
      // Bootout first so reinstalls reload a changed plist; a "not loaded"
      // failure is fine.
      _ = try? Self.launchctl(["bootout", "\(domain)/\(spec.label)"])
      try Self.launchctl(["bootstrap", domain, plistPath.path])
      try Self.launchctl(["kickstart", "\(domain)/\(spec.label)"])
    }

    /// Boots out the agent and removes its plist. Silent when not installed.
    public func uninstall(label: String) throws {
      let domain = "gui/\(getuid())"
      _ = try? Self.launchctl(["bootout", "\(domain)/\(label)"])
      try? FileManager.default.removeItem(at: plistURL(for: label))
    }

    // MARK: Status

    /// Runs `launchctl print` and parses the state and last exit code.
    /// Returns `.notLoaded` when the service isn't in the domain.
    public func status(label: String) -> LaunchAgentStatus {
      let domain = "gui/\(getuid())"
      guard let output = try? Self.launchctl(["print", "\(domain)/\(label)"]) else {
        return LaunchAgentStatus(state: .notLoaded, lastExitCode: nil)
      }
      return Self.parseStatus(output)
    }

    /// Parses `launchctl print` output:
    ///   state = running | waiting | ...
    ///   last exit code = 0
    static func parseStatus(_ output: String) -> LaunchAgentStatus {
      var state: LaunchAgentStatus.State = .unknown
      var lastExitCode: Int?
      for line in output.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("state = ") {
          let value = String(trimmed.dropFirst("state = ".count))
          state = LaunchAgentStatus.State(rawValue: value) ?? .unknown
        } else if trimmed.hasPrefix("last exit code = ") {
          lastExitCode = Int(trimmed.dropFirst("last exit code = ".count))
        }
      }
      return LaunchAgentStatus(state: state, lastExitCode: lastExitCode)
    }

    // MARK: - Helpers

    /// Writes 0o600 via a temp file plus rename, mirroring ConfigStore.saveJSON.
    private func writeAtomically(_ data: Data, to url: URL) throws {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let tempPath = url.path + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
      let fd = open(tempPath, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
      guard fd >= 0 else { throw SyncError.unknown("Cannot create \(tempPath)") }
      do {
        try data.withUnsafeBytes { bytes in
          var written = 0
          while written < bytes.count {
            let n = write(fd, bytes.baseAddress! + written, bytes.count - written)
            guard n > 0 else { throw SyncError.unknown("Write failed for \(tempPath)") }
            written += n
          }
        }
      } catch {
        close(fd)
        try? FileManager.default.removeItem(atPath: tempPath)
        throw error
      }
      close(fd)
      guard rename(tempPath, url.path) == 0 else {
        try? FileManager.default.removeItem(atPath: tempPath)
        throw SyncError.unknown("Cannot save \(url.path)")
      }
    }

    /// Runs launchctl, returning stdout on success and throwing on non-zero
    /// exit with stderr in the message.
    @discardableResult
    private static func launchctl(_ arguments: [String]) throws -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      process.arguments = arguments
      let stdout = Pipe()
      let stderr = Pipe()
      process.standardOutput = stdout
      process.standardError = stderr
      try process.run()
      process.waitUntilExit()
      let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      guard process.terminationStatus == 0 else {
        throw SyncError.unknown(
          "launchctl \(arguments.joined(separator: " ")) failed: \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
        )
      }
      return out
    }
  }
#endif
