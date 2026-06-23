import XCTest

@testable import AppleSyncKit

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

private struct Payload: Codable, Equatable {
  let body: String
}

final class EncryptionServiceTests: XCTestCase {
  private func makeKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

  func testEncryptDecryptRoundTrip() async throws {
    let service = EncryptionService(key: makeKey())
    let payload = Payload(body: "# Secret\n\nbackup code 1234")
    let sealed = try await service.encrypt(
      payload, recordId: "n1", modifiedDate: "2026-03-10T10:00:00Z")
    XCTAssertFalse(sealed.encryptedPayload.isEmpty)
    let opened: Payload = try await service.decrypt(
      sealed.encryptedPayload, iv: sealed.encryptedIV, recordId: "n1",
      modifiedDate: "2026-03-10T10:00:00Z")
    XCTAssertEqual(opened, payload)
  }

  func testWrongKeyFailsToDecrypt() async throws {
    let enc = EncryptionService(key: makeKey())
    let dec = EncryptionService(key: makeKey())
    let sealed = try await enc.encrypt(Payload(body: "secret"), recordId: "n1", modifiedDate: "d")
    do {
      let _: Payload = try await dec.decrypt(
        sealed.encryptedPayload, iv: sealed.encryptedIV, recordId: "n1", modifiedDate: "d")
      XCTFail("Expected failure with wrong key")
    } catch let error as EncryptionError {
      XCTAssertEqual(error, .decryptionFailed)
    }
  }

  func testTamperedAADFailsToDecrypt() async throws {
    let service = EncryptionService(key: makeKey())
    let sealed = try await service.encrypt(
      Payload(body: "secret"), recordId: "n1", modifiedDate: "d1")
    do {
      let _: Payload = try await service.decrypt(
        sealed.encryptedPayload, iv: sealed.encryptedIV, recordId: "n1", modifiedDate: "d2")
      XCTFail("Expected AAD mismatch failure")
    } catch let error as EncryptionError {
      XCTAssertEqual(error, .decryptionFailed)
    }
  }

  func testKeyFromBase64ValidatesLength() {
    let shortKey = Data(repeating: 0, count: 16).base64EncodedString()
    XCTAssertThrowsError(try EncryptionService.keyFromBase64(shortKey)) {
      XCTAssertEqual($0 as? EncryptionError, .invalidKeyLength)
    }
    let goodKey = Data(repeating: 0, count: 32).base64EncodedString()
    XCTAssertNoThrow(try EncryptionService.keyFromBase64(goodKey))
  }

  func testKeyFromEnvironment() throws {
    let good = Data(repeating: 7, count: 32).base64EncodedString()
    XCTAssertNoThrow(try EncryptionService.keyFromEnvironment("K", environment: ["K": good]))
    XCTAssertThrowsError(try EncryptionService.keyFromEnvironment("K", environment: [:])) {
      XCTAssertEqual($0 as? EncryptionError, .keyNotConfigured("K"))
    }
  }

  func testCarrierRoundTrip() {
    let carrier = EncryptedCarrier(p: "payload", i: "iv")
    let json = try! carrier.toJSONString()
    let parsed = EncryptedCarrier.fromJSON(json)
    XCTAssertEqual(parsed?.p, "payload")
    XCTAssertEqual(parsed?.i, "iv")
    XCTAssertNil(EncryptedCarrier.fromJSON("just plain text"))
  }
}
