import Foundation

// MARK: - Sync Remote Client Protocol

/// Seam representing the remote sync backend (e.g. Cloudflare D1 Worker).
/// Enables decoupled testing and alternative transport mechanisms.
public protocol SyncRemoteClient: Sendable {
  func push<T: Codable & Sendable>(
    entity: String,
    items: [T],
    id: @Sendable (T) -> String,
    idOverrides: [String: String],
    lastModifiedByRemoteId: [String: String]
  ) async throws -> PushResult

  func pull<T: Codable & Sendable>(
    entity: String,
    cursor: String?,
    excludeOwnWrites: Bool
  ) async throws -> PullResponse<T>

  /// Reports whether deletion applied, was already absent, or lost a conflict.
  func delete(entity: String, id: String, lastModified: String?) async throws -> DeleteResult
}

extension D1SyncClient: SyncRemoteClient {}
