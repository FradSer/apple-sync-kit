import Foundation

// MARK: - Sync Journal State

/// Consolidated on-disk state representing entity states, ID mappings, and pull
/// cursors across all configured entities in a single atomic snapshot.
public struct SyncJournalState: Codable, Sendable, Equatable {
  public var entityStates: [String: SyncEntityState]
  public var idMappings: [String: [String: String]]
  public var cursors: [String: String]

  public init(
    entityStates: [String: SyncEntityState] = [:],
    idMappings: [String: [String: String]] = [:],
    cursors: [String: String] = [:]
  ) {
    self.entityStates = entityStates
    self.idMappings = idMappings
    self.cursors = cursors
  }
}

// MARK: - Sync State Journal

/// Manages atomic checkpoint persistence for `SyncJournalState` to `sync-state.json`.
/// Uses temporary files and POSIX atomic renames with 0o600 permissions.
public struct SyncStateJournal: Sendable {
  public let journalPath: String

  public init(journalPath: String) {
    self.journalPath = journalPath
  }

  /// Loads current journal state from disk. Returns an empty state only when the
  /// file does not exist yet. Throws `SyncError.unknown` on I/O, permissions, or parse errors.
  public func load() throws -> SyncJournalState {
    guard FileManager.default.fileExists(atPath: journalPath) else {
      return SyncJournalState()
    }

    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: journalPath))
    } catch {
      throw SyncError.unknown(
        "Cannot read sync journal at \(journalPath): \(error.localizedDescription)")
    }

    do {
      return try JSONDecoder().decode(SyncJournalState.self, from: data)
    } catch {
      throw SyncError.unknown(
        "Could not parse sync journal at \(journalPath): \(error.localizedDescription). "
          + "Repair or remove the file before syncing again.")
    }
  }

  /// Atomically commits a new journal checkpoint to disk via 0o600 temp file and rename.
  public func commitCheckpoint(_ state: SyncJournalState) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(state)
    try AtomicJSONFile(path: journalPath).saveData(data)
  }
}
