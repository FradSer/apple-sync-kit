import Foundation

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

// MARK: - Encryption Service

/// AES-GCM encryption of any `Codable` payload, with the record id and modified
/// date bound as additional authenticated data. Entity-agnostic: each project
/// defines its own payload type and passes it through here.
public actor EncryptionService {
  private let key: SymmetricKey

  public init(key: SymmetricKey) {
    self.key = key
  }

  /// Encrypt a payload, returning base64-encoded ciphertext (with appended tag)
  /// and IV.
  public func encrypt<T: Encodable>(
    _ payload: T,
    recordId: String,
    modifiedDate: String
  ) throws -> (encryptedPayload: String, encryptedIV: String) {
    let plaintext = try JSONEncoder().encode(payload)
    let nonce = AES.GCM.Nonce()
    let aad = buildAAD(recordId: recordId, modifiedDate: modifiedDate)

    let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
    guard let combined = sealedBox.combined else {
      throw EncryptionError.sealFailed
    }
    return (Data(combined).base64EncodedString(), Data(nonce).base64EncodedString())
  }

  /// Decrypt a base64-encoded payload using the supplied IV and AAD context.
  public func decrypt<T: Decodable>(
    _ encryptedPayload: String,
    iv encryptedIV: String,
    recordId: String,
    modifiedDate: String,
    as type: T.Type = T.self
  ) throws -> T {
    guard let ciphertextData = Data(base64Encoded: encryptedPayload) else {
      throw EncryptionError.invalidBase64Payload
    }
    guard let nonceData = Data(base64Encoded: encryptedIV) else {
      throw EncryptionError.invalidBase64IV
    }

    let nonce = try AES.GCM.Nonce(data: nonceData)
    // `combined` is nonce || ciphertext || tag, so strip the nonce prefix and the
    // tag suffix to recover the raw ciphertext.
    let ciphertext = ciphertextData.dropFirst(nonceData.count).dropLast(16)
    let tag = ciphertextData.suffix(16)
    let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
    let aad = buildAAD(recordId: recordId, modifiedDate: modifiedDate)

    let plaintext: Data
    do {
      plaintext = try AES.GCM.open(sealedBox, using: key, authenticating: aad)
    } catch {
      throw EncryptionError.decryptionFailed
    }
    do {
      return try JSONDecoder().decode(T.self, from: plaintext)
    } catch {
      throw EncryptionError.payloadDecodeFailed
    }
  }

  // MARK: - Key Helpers

  /// Create a 256-bit symmetric key from a base64-encoded string.
  public static func keyFromBase64(_ base64: String) throws -> SymmetricKey {
    guard let data = Data(base64Encoded: base64) else {
      throw EncryptionError.invalidBase64Key
    }
    guard data.count == 32 else {
      throw EncryptionError.invalidKeyLength
    }
    return SymmetricKey(data: data)
  }

  /// Load the encryption key from the named environment variable.
  public static func keyFromEnvironment(
    _ varName: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> SymmetricKey {
    guard let value = environment[varName], !value.isEmpty else {
      throw EncryptionError.keyNotConfigured(varName)
    }
    return try keyFromBase64(value)
  }

  private func buildAAD(recordId: String, modifiedDate: String) -> Data {
    Data("\(recordId)|\(modifiedDate)".utf8)
  }
}

// MARK: - Encryption Errors

public enum EncryptionError: LocalizedError, Sendable, Equatable {
  case sealFailed
  case invalidBase64Payload
  case invalidBase64IV
  case invalidBase64Key
  case invalidKeyLength
  case keyNotConfigured(String)
  case decryptionFailed
  case payloadDecodeFailed

  public var errorDescription: String? {
    switch self {
    case .sealFailed:
      return "Encryption seal failed"
    case .invalidBase64Payload:
      return "Encrypted payload is not valid base64"
    case .invalidBase64IV:
      return "Encrypted IV is not valid base64"
    case .invalidBase64Key:
      return "Encryption key is not valid base64"
    case .invalidKeyLength:
      return "Encryption key must be 32 bytes (256 bits)"
    case .keyNotConfigured(let varName):
      return
        "\(varName) environment variable is not set. Generate one with "
        + "'openssl rand -base64 32' and export it on every device."
    case .decryptionFailed:
      return "Decryption failed: wrong key or tampered data"
    case .payloadDecodeFailed:
      return "Decrypted data could not be decoded"
    }
  }
}
