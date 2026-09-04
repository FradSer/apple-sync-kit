import Foundation

/// A locally deleted record awaiting propagation to the remote backend.
public struct LocalDeletedRecord: Sendable, Equatable {
  public let id: String
  public let lastModified: String

  public init(id: String, lastModified: String) {
    self.id = id
    self.lastModified = lastModified
  }
}
