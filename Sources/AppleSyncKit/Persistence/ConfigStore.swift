import Foundation

// MARK: - Config Store

/// Generic sync config + state persistence under `~/.config/<namespace>/`.
/// Configured with a `namespace` (e.g. "note-sync") and env-var `prefix` (e.g.
/// "NOTE"). Consuming projects load/save their concrete `Codable` state types
/// through the generic JSON helpers, so the on-disk JSON shape is theirs — the kit
/// imposes no schema. Files are written 0o600 via atomic rename.
public struct ConfigStore: Sendable {
  public let namespace: String
  public let prefix: String

  public init(namespace: String, prefix: String) {
    self.namespace = namespace
    self.prefix = prefix
  }

  private var baseDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config")
      .appendingPathComponent(namespace)
  }

  public var configPath: String { baseDirectory.appendingPathComponent("config.json").path }
  public var cursorsPath: String { baseDirectory.appendingPathComponent("cursors.json").path }
  public var idMappingPath: String { baseDirectory.appendingPathComponent("id-mapping.json").path }
  public var statePath: String { baseDirectory.appendingPathComponent("state.json").path }

  public var apiURLEnvKey: String { "\(prefix)_SYNC_API_URL" }
  public var apiTokenEnvKey: String { "\(prefix)_SYNC_API_TOKEN" }
  public var deviceIdEnvKey: String { "\(prefix)_SYNC_DEVICE_ID" }

  // MARK: - Lock

  /// Acquire an exclusive, non-blocking file lock to prevent concurrent sync.
  /// Returns the file descriptor; call `releaseLock(_:)` when done.
  public func acquireLock() throws -> Int32 {
    let dir = baseDirectory
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lockPath = dir.appendingPathComponent(".lock").path
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else {
      throw SyncError.unknown("Could not create sync lock file")
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      throw SyncError.unknown("Another sync operation is already running")
    }
    return fd
  }

  public func releaseLock(_ fd: Int32) {
    flock(fd, LOCK_UN)
    close(fd)
  }

  // MARK: - Config

  public func validateAPIURL(_ apiURL: String) throws {
    guard apiURL.lowercased().hasPrefix("https://") else {
      throw SyncError.invalidInput("API URL must use HTTPS. Got: \(apiURL)")
    }
  }

  /// Builds a `SyncConfig` from environment variables. Returns `nil` when neither
  /// required variable is set; throws when exactly one is set or the URL isn't HTTPS.
  public func loadFromEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> SyncConfig? {
    func value(_ key: String) -> String? {
      guard let raw = environment[key], !raw.isEmpty else { return nil }
      return raw
    }
    switch (value(apiURLEnvKey), value(apiTokenEnvKey)) {
    case (nil, nil):
      return nil
    case (let apiURL?, let apiToken?):
      try validateAPIURL(apiURL)
      let deviceId = value(deviceIdEnvKey) ?? ProcessInfo.processInfo.hostName
      return SyncConfig(apiURL: apiURL, apiToken: apiToken, deviceId: deviceId)
    default:
      throw SyncError.invalidInput(
        "Both \(apiURLEnvKey) and \(apiTokenEnvKey) must be set to use environment-based config.")
    }
  }

  public func hasEnvironmentConfig(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    func isSet(_ key: String) -> Bool { !(environment[key] ?? "").isEmpty }
    return isSet(apiURLEnvKey) && isSet(apiTokenEnvKey)
  }

  /// Loads the sync config: environment variables take precedence, then the
  /// config file. `notFoundMessage` lets the caller phrase a CLI-friendly error.
  public func loadConfig(notFoundMessage: String? = nil) throws -> SyncConfig {
    if let envConfig = try loadFromEnvironment() {
      return envConfig
    }
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: configPath))
    } catch {
      throw SyncError.notFound(
        notFoundMessage
          ?? "Sync config not found. Set \(apiURLEnvKey) and \(apiTokenEnvKey), or write \(configPath)."
      )
    }
    let config = try JSONDecoder().decode(SyncConfig.self, from: data)
    try validateAPIURL(config.apiURL)
    return config
  }

  public func saveConfig(_ config: SyncConfig) throws {
    try validateAPIURL(config.apiURL)
    try saveJSON(config, to: configPath)
    if let notice = envOverrideNotice() {
      writeStderr(notice + "\n")
    }
  }

  /// Returns a notice when environment variables are set AND would actually
  /// take precedence over the config file just saved (i.e. `loadFromEnvironment`
  /// succeeds — both required vars present and the URL is valid HTTPS). `nil`
  /// otherwise. Pure for testability (defaults to the live environment).
  public func envOverrideNotice(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    // Only warn when env config loads successfully — a non-HTTPS env URL would
    // make loadFromEnvironment throw on the next load, so env would NOT win.
    guard (try? loadFromEnvironment(environment)) != nil else { return nil }
    return
      "Note: \(apiURLEnvKey)/\(apiTokenEnvKey) are set in the environment"
      + " and will take precedence over \(configPath)."
  }

  // MARK: - Generic JSON helpers

  /// Returns the default when the file is missing; logs and returns the default on
  /// parse errors (used for cursors, which are safe to rebuild).
  public func loadJSON<T: Decodable>(from path: String, default defaultValue: T) -> T {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return defaultValue }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      writeStderr("Warning: Could not parse \(path): \(error.localizedDescription)\n")
      return defaultValue
    }
  }

  /// Returns the default when the file is missing; throws on parse errors (used for
  /// state and id-mapping, which must not be silently reset).
  public func loadJSONStrict<T: Decodable>(from path: String, default defaultValue: T) throws -> T {
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      return defaultValue
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw SyncError.unknown(
        "Could not parse \(path): \(error.localizedDescription). "
          + "Repair or remove the file before syncing again.")
    }
  }

  /// Writes JSON to `path` via a 0o600 temp file plus atomic rename.
  public func saveJSON<T: Encodable>(_ value: T, to path: String) throws {
    let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(value)
    let tempPath = path + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
    let fd = open(tempPath, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
    guard fd >= 0 else { throw posixError("Cannot create \(tempPath)") }
    do {
      try data.withUnsafeBytes { bytes in
        var written = 0
        while written < bytes.count {
          let n = write(fd, bytes.baseAddress! + written, bytes.count - written)
          guard n > 0 else { throw posixError("Write failed") }
          written += n
        }
      }
    } catch {
      close(fd)
      try? FileManager.default.removeItem(atPath: tempPath)
      throw error
    }
    close(fd)
    guard rename(tempPath, path) == 0 else {
      let error = posixError("Cannot save \(path)")
      try? FileManager.default.removeItem(atPath: tempPath)
      throw error
    }
  }

  private func posixError(_ context: String, _ code: Int32 = errno) -> SyncError {
    SyncError.unknown("\(context): \(String(cString: strerror(code)))")
  }
}
