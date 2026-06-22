import Foundation
import SQLite

// MARK: - SQLite Sync Store

/// Generic row helpers over a SQLite.swift `Connection` for the local (Linux)
/// sync path: fetch non-deleted / local-only records, soft-delete bookkeeping,
/// and JSON-blob upsert. Each record is stored as JSON in a `data` column, with
/// `deleted` / `is_local_only` flags, in a table named per entity.
public struct SQLiteSyncStore: Sendable {
  private let connection: Connection

  public init(connection: Connection) {
    self.connection = connection
  }

  public func fetchNonDeleted<T: Codable>(from table: String) throws -> [T] {
    try connection.prepare("SELECT data FROM \(table) WHERE deleted = 0").map { row in
      try Self.decode(T.self, from: row[0], table: table)
    }
  }

  public func fetchLocalOnly<T: Codable>(from table: String) throws -> [T] {
    try connection.prepare("SELECT data FROM \(table) WHERE is_local_only = 1 AND deleted = 0").map
    {
      row in
      try Self.decode(T.self, from: row[0], table: table)
    }
  }

  public func fetchDeletedRecords(from table: String) throws -> [SyncEngine.DeletedRecord] {
    try connection.prepare("SELECT id, last_modified FROM \(table) WHERE deleted = 1").map { row in
      SyncEngine.DeletedRecord(id: row[0] as! String, lastModified: row[1] as! String)
    }
  }

  public func clearLocalOnly(table: String, ids: [String]) throws {
    guard !ids.isEmpty else { return }
    let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
    try connection.run(
      "UPDATE \(table) SET is_local_only = 0 WHERE id IN (\(placeholders))",
      ids.map { $0 as Binding? })
  }

  /// Hard-deletes a single record; throws `SyncError.notFound` if none existed.
  public func removeRecord(table: String, id: String) throws {
    try connection.run("DELETE FROM \(table) WHERE id = ?", id)
    if connection.changes == 0 {
      throw SyncError.notFound("Record with ID '\(id)' not found in \(table)")
    }
  }

  /// Hard-deletes a single record; silently succeeds if none existed.
  public func hardDeleteRecord(table: String, id: String) throws {
    try connection.run("DELETE FROM \(table) WHERE id = ?", id)
  }

  /// Upserts a record (server-sourced): sets `is_local_only = 0` and `deleted = 0`.
  public func upsertRecord<T: Encodable>(
    table: String, id: String, data: T, lastModified: String
  ) throws {
    let jsonData = try JSONEncoder().encode(data)
    guard let jsonString = String(data: jsonData, encoding: .utf8) else {
      throw SyncError.unknown("Failed to encode record data for \(table)")
    }
    let sql = """
      INSERT INTO \(table) (id, data, last_modified, deleted, is_local_only)
      VALUES (?, ?, ?, 0, 0)
      ON CONFLICT(id) DO UPDATE SET
        data = excluded.data,
        last_modified = excluded.last_modified,
        deleted = 0,
        is_local_only = 0,
        updated_at = datetime('now')
      """
    try connection.run(sql, id, jsonString, lastModified)
  }

  private static func decode<T: Codable>(
    _ type: T.Type, from value: Binding?, table: String
  ) throws -> T {
    guard let jsonString = value as? String, let jsonData = jsonString.data(using: .utf8) else {
      throw SyncError.unknown("Failed to decode record data from \(table)")
    }
    return try JSONDecoder().decode(T.self, from: jsonData)
  }
}
