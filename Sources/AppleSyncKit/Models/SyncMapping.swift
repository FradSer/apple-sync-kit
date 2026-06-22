import Foundation

// MARK: - Sync Mapping Helpers

public enum SyncMapping {
  /// A local id claimed by more than one remote id while inverting a mapping.
  public struct InversionCollision: Sendable, Equatable {
    public let localId: String
    public let keptRemoteId: String
    public let droppedRemoteId: String

    public init(localId: String, keptRemoteId: String, droppedRemoteId: String) {
      self.localId = localId
      self.keptRemoteId = keptRemoteId
      self.droppedRemoteId = droppedRemoteId
    }
  }

  /// Inverts a remote-to-local map into local-to-remote. When two remote ids
  /// claim the same local id, the lexicographically smaller remote id is kept
  /// (deterministic) and the collision is reported for the caller to surface.
  public static func inverted(
    _ mapping: [String: String]
  ) -> (mapping: [String: String], collisions: [InversionCollision]) {
    var inverted: [String: String] = [:]
    inverted.reserveCapacity(mapping.count)
    var collisions: [InversionCollision] = []
    for (remote, local) in mapping.sorted(by: { $0.key < $1.key }) {
      if let existing = inverted[local] {
        collisions.append(
          InversionCollision(localId: local, keptRemoteId: existing, droppedRemoteId: remote))
      } else {
        inverted[local] = remote
      }
    }
    return (inverted, collisions)
  }
}
