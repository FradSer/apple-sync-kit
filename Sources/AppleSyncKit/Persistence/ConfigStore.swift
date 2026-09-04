import Foundation

// MARK: - Config Store

/// Stores sync configuration under `~/.config/<namespace>/` and coordinates
/// exclusive sync locking. Sync state is managed by `SyncStateJournal`.
public struct ConfigStore: Sendable {
  public let namespace: String
  public let prefix: String
  private let rootDirectory: URL?

  public init(namespace: String, prefix: String, rootDirectory: URL? = nil) {
    self.namespace = namespace
    self.prefix = prefix
    self.rootDirectory = rootDirectory
  }

  private var baseDirectory: URL {
    let root =
      rootDirectory
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
    return root.appendingPathComponent(namespace)
  }

  public var configPath: String { path(for: "config.json") }
  public var syncJournalPath: String {
    baseDirectory.appendingPathComponent("sync-state.json").path
  }

  public var journal: SyncStateJournal {
    SyncStateJournal(journalPath: syncJournalPath)
  }

  /// Resolves a consumer-owned filename under this store's config namespace.
  public func path(for filename: String) -> String {
    baseDirectory.appendingPathComponent(filename).path
  }

  public var apiURLEnvKey: String { "\(prefix)_SYNC_API_URL" }
  public var apiTokenEnvKey: String { "\(prefix)_SYNC_API_TOKEN" }
  public var deviceIdEnvKey: String { "\(prefix)_SYNC_DEVICE_ID" }

  // MARK: - Lock

  /// Acquires an exclusive, non-blocking file lock to prevent concurrent sync.
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
      throw SyncError.alreadyRunning
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
  /// required variable is set; throws when exactly one is set or the URL is not HTTPS.
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

  /// Loads the sync config: environment variables take precedence, then the config file.
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

  /// Returns the default when the file is missing or malformed.
  public func loadJSON<T: Decodable>(from path: String, default defaultValue: T) -> T {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
      return defaultValue
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      writeStderr("Warning: Could not parse \(path): \(error.localizedDescription)\n")
      return defaultValue
    }
  }

  /// Returns the default when the file is missing and throws when it is malformed.
  public func loadJSONStrict<T: Decodable>(from path: String, default defaultValue: T) throws -> T {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
      return defaultValue
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw SyncError.unknown(
        "Could not parse \(path): \(error.localizedDescription). "
          + "Repair or remove the file before continuing."
      )
    }
  }

  /// Atomically writes consumer-owned JSON with mode 0o600.
  public func saveJSON<T: Encodable>(_ value: T, to path: String) throws {
    try AtomicJSONFile(path: path).save(value)
  }

  /// Returns a notice when valid environment config overrides the saved file.
  public func envOverrideNotice(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    guard (try? loadFromEnvironment(environment)) != nil else { return nil }
    return
      "Note: \(apiURLEnvKey)/\(apiTokenEnvKey) are set in the environment"
      + " and will take precedence over \(configPath)."
  }
}
