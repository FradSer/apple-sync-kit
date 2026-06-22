import Foundation

// MARK: - Sync Error

/// Errors thrown by the shared sync layer. Each consuming project keeps its own
/// CLI error type for domain/command errors; the kit uses this for the sync
/// engine, D1 client, config store, and encryption boundary.
public enum SyncError: LocalizedError, Sendable, SyncNotFound {
  case notFound(String)
  case invalidInput(String)
  case unknown(String)

  public var errorDescription: String? {
    switch self {
    case .notFound(let message):
      return "Not found: \(message)"
    case .invalidInput(let message):
      return "Invalid input: \(message)"
    case .unknown(let message):
      return "Error: \(message)"
    }
  }

  /// Whether this is a not-found error. The engine's default `isNotFound` check
  /// recognizes both this and any error a project marks via `SyncNotFound`.
  public var isNotFound: Bool {
    if case .notFound = self { return true }
    return false
  }
}

/// Marker a project's error type can adopt so the shared engine recognizes its
/// "not found" failures across the module boundary without a hard type
/// dependency. The engine also accepts an explicit `isNotFound` closure.
public protocol SyncNotFound {
  var isNotFound: Bool { get }
}
