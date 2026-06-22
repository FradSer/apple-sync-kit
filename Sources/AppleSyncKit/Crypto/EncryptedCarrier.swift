import Foundation

// MARK: - Encrypted Carrier

/// JSON-serializable container that carries an encrypted payload and its IV inside
/// a single plaintext field (e.g. a record's `notes`/`body`). The version tag
/// prevents false positives when plain text happens to be valid JSON.
public struct EncryptedCarrier: Codable, Sendable {
  public let v: Int
  public let p: String
  public let i: String

  public static let currentVersion = 1

  public init(p: String, i: String) {
    self.v = Self.currentVersion
    self.p = p
    self.i = i
  }

  public func toJSONString() throws -> String {
    let data = try JSONEncoder().encode(self)
    return String(decoding: data, as: UTF8.self)
  }

  public static func fromJSON(_ json: String) -> EncryptedCarrier? {
    guard let data = json.data(using: .utf8) else { return nil }
    guard let carrier = try? JSONDecoder().decode(EncryptedCarrier.self, from: data) else {
      return nil
    }
    guard carrier.v == currentVersion else { return nil }
    return carrier
  }
}
