import CryptoKit
import Foundation
import XCTest

final class ProtocolV1VectorsTests: XCTestCase {
  private let vaultID = "vault-vector-1"
  private let blobID = "blob-vector-1"

  func testAcceptsCanonicalProtocolVector() throws {
    let document = try ProtocolV1VectorVerifier.parseProtocol(
      data(at: "valid/protocol.utf8.json", wrappedUTF8: true)
    )
    XCTAssertEqual(document.vaultID, vaultID)
    XCTAssertEqual(document.createdAt, "2026-07-15T00:00:00.000Z")
  }

  func testRejectsUnsupportedProtocolVersion() {
    XCTAssertThrowsError(
      try ProtocolV1VectorVerifier.parseProtocol(
        data(at: "unsupported_version/protocol.json")
      )
    )
  }

  func testRejectsTraversalAndReplayVectors() throws {
    let identifiers = try json(at: "path_traversal/identifiers.json")
    XCTAssertFalse(ProtocolV1VectorVerifier.isOpaqueID(identifiers["vaultId"] as! String))
    XCTAssertFalse(ProtocolV1VectorVerifier.isOpaqueID(identifiers["blobId"] as! String))
    XCTAssertThrowsError(
      try ProtocolV1VectorVerifier.validateOperations(
        try Data(contentsOf: vectorURL("replay/operations.json"))
      )
    )
  }

  func testRejectsForgedAndTruncatedBlobVectors() throws {
    for path in ["invalid_authentication/blob.hex", "corrupted_blob/blob.hex"] {
      XCTAssertThrowsError(
        try ProtocolV1VectorVerifier.decryptBlob(
          hexData(at: path), vaultID: vaultID, blobID: blobID, keyID: "key-1"
        )
      )
    }
  }

  func testAcceptsRFC8032Ed25519SignatureVector() throws {
    let vector = try json(at: "valid/ed25519_signature.json")
    let publicKey = try hexData(vector["publicKeyHex"] as? String ?? "")
    let signature = try hexData(vector["signatureHex"] as? String ?? "")
    let message = try hexData(vector["messageHex"] as? String ?? "")
    let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    XCTAssertTrue(verifier.isValidSignature(signature, for: message))
  }

  func testRejectsTamperedRFC8032Ed25519Signature() throws {
    let vector = try json(at: "valid/ed25519_signature.json")
    let publicKey = try hexData(vector["publicKeyHex"] as? String ?? "")
    var signature = try hexData(vector["signatureHex"] as? String ?? "")
    signature[signature.startIndex] ^= 1
    let message = try hexData(vector["messageHex"] as? String ?? "")
    let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    XCTAssertFalse(verifier.isValidSignature(signature, for: message))
  }

  private func vectorURL(_ path: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("../../test_vectors/protocol_v1/")
      .appendingPathComponent(path)
  }

  private func data(at path: String, wrappedUTF8: Bool = false) throws -> Data {
    let data = try Data(contentsOf: vectorURL(path))
    guard wrappedUTF8 else { return data }
    let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let source = value?["value"] as? String else {
      throw ProtocolV1VectorError.invalid("Invalid UTF-8 test fixture")
    }
    return Data(source.utf8)
  }

  private func json(at path: String) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data(at: path)) as? [String: Any] else {
      throw ProtocolV1VectorError.invalid("Invalid JSON test fixture")
    }
    return value
  }

  private func hexData(at path: String) throws -> Data {
    let text = try String(contentsOf: vectorURL(path), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count.isMultiple(of: 2) else {
      throw ProtocolV1VectorError.invalid("Invalid hex fixture")
    }
    return Data(stride(from: 0, to: text.count, by: 2).map {
      UInt8(text[text.index(text.startIndex, offsetBy: $0)..<text.index(text.startIndex, offsetBy: $0 + 2)], radix: 16)!
    })
  }

  private func hexData(_ text: String) throws -> Data {
    guard text.count.isMultiple(of: 2) else {
      throw ProtocolV1VectorError.invalid("Invalid hex fixture")
    }
    return Data(stride(from: 0, to: text.count, by: 2).map {
      UInt8(text[text.index(text.startIndex, offsetBy: $0)..<text.index(text.startIndex, offsetBy: $0 + 2)], radix: 16)!
    })
  }
}

private enum ProtocolV1VectorError: Error {
  case invalid(String)
}

private enum ProtocolV1VectorVerifier {
  struct ProtocolDocument {
    let vaultID: String
    let createdAt: String
    let minimumReaderVersion: Int
    let minimumWriterVersion: Int
    let cryptoSuite: String
  }

  static func parseProtocol(_ data: Data) throws -> ProtocolDocument {
    guard let source = String(data: data, encoding: .utf8),
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["protocol"] as? String == "velock-sync",
          json["protocolVersion"] as? Int == 1 else {
      throw ProtocolV1VectorError.invalid("Unsupported protocol document")
    }
    let document = ProtocolDocument(
      vaultID: try nonEmptyString(json, "vaultId"),
      createdAt: try nonEmptyString(json, "createdAt"),
      minimumReaderVersion: try positiveInt(json, "minimumReaderVersion"),
      minimumWriterVersion: try positiveInt(json, "minimumWriterVersion"),
      cryptoSuite: try nonEmptyString(json, "cryptoSuite")
    )
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard dateFormatter.date(from: document.createdAt) != nil,
          source == canonicalProtocol(document) else {
      throw ProtocolV1VectorError.invalid("Non-canonical protocol document")
    }
    return document
  }

  static func isOpaqueID(_ value: String) -> Bool {
    !value.isEmpty && !value.contains("/") && !value.contains("\\") && !value.contains("..")
  }

  static func validateOperations(_ data: Data) throws {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["protocolVersion"] as? Int == 1,
          let operations = json["operations"] as? [[String: Any]] else {
      throw ProtocolV1VectorError.invalid("Invalid operations document")
    }
    var operationIDs = Set<String>()
    for operation in operations {
      let operationID = try nonEmptyString(operation, "operationId")
      guard operationIDs.insert(operationID).inserted else {
        throw ProtocolV1VectorError.invalid("Duplicate operation ID")
      }
    }
  }

  static func decryptBlob(_ data: Data, vaultID: String, blobID: String, keyID: String) throws -> Data {
    let bytes = [UInt8](data)
    guard bytes.count >= 28, String(bytes: bytes[0..<4], encoding: .utf8) == "VLSB",
          bytes[4] == 1, bytes[5] == 0, readUInt32(bytes, 6) == 4 * 1024 * 1024 else {
      throw ProtocolV1VectorError.invalid("Unsupported VLSB header")
    }
    let plaintextLength = Int(readUInt64(bytes, 10))
    let keyLength = Int(readUInt16(bytes, 26))
    let headerLength = 28 + keyLength
    guard headerLength <= bytes.count,
          String(bytes: bytes[28..<headerLength], encoding: .utf8) == keyID else {
      throw ProtocolV1VectorError.invalid("Invalid VLSB key ID")
    }
    var offset = headerLength
    var output = Data()
    var index = 0
    while output.count < plaintextLength {
      guard offset + 4 <= bytes.count else { throw ProtocolV1VectorError.invalid("Truncated chunk length") }
      let chunkLength = Int(readUInt32(bytes, offset))
      offset += 4
      guard chunkLength > 0, offset + chunkLength + 16 <= bytes.count else {
        throw ProtocolV1VectorError.invalid("Truncated VLSB chunk")
      }
      let ciphertext = Data(bytes[offset..<(offset + chunkLength)])
      let tag = Data(bytes[(offset + chunkLength)..<(offset + chunkLength + 16)])
      let nonce = Data(bytes[18..<26]) + uint32(index)
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag
      )
      output.append(
        try AES.GCM.open(box, using: SymmetricKey(data: blobKey(vaultID: vaultID, blobID: blobID)), authenticating: blobAAD(
          vaultID: vaultID, blobID: blobID, index: index, total: plaintextLength, length: chunkLength
        ))
      )
      offset += chunkLength + 16
      index += 1
    }
    guard output.count == plaintextLength, offset == bytes.count else {
      throw ProtocolV1VectorError.invalid("Unexpected VLSB trailing data")
    }
    return output
  }

  private static func canonicalProtocol(_ document: ProtocolDocument) -> String {
    "{\"createdAt\":\(quote(document.createdAt)),\"cryptoSuite\":\(quote(document.cryptoSuite)),\"minimumReaderVersion\":\(document.minimumReaderVersion),\"minimumWriterVersion\":\(document.minimumWriterVersion),\"protocol\":\"velock-sync\",\"protocolVersion\":1,\"vaultId\":\(quote(document.vaultID))}"
  }

  private static func quote(_ value: String) -> String {
    let json = try! JSONSerialization.data(withJSONObject: [value])
    let source = String(data: json, encoding: .utf8)!
    return String(source.dropFirst().dropLast())
  }

  private static func nonEmptyString(_ json: [String: Any], _ key: String) throws -> String {
    guard let value = json[key] as? String, !value.isEmpty else {
      throw ProtocolV1VectorError.invalid("Invalid \(key)")
    }
    return value
  }

  private static func positiveInt(_ json: [String: Any], _ key: String) throws -> Int {
    guard let value = json[key] as? Int, value > 0 else {
      throw ProtocolV1VectorError.invalid("Invalid \(key)")
    }
    return value
  }

  private static func blobKey(vaultID: String, blobID: String) -> Data {
    let vault = Data(vaultID.utf8)
    let blobRoot = hkdf(Data(repeating: 0, count: 32), salt: vault, info: Data("velock-sync/v1/blob-root".utf8))
    return hkdf(blobRoot, salt: vault, info: Data("velock-sync/v1/blob/\(blobID)".utf8))
  }

  private static func hkdf(_ input: Data, salt: Data, info: Data) -> Data {
    let prk = HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: salt))
    let block = HMAC<SHA256>.authenticationCode(
      for: info + Data([1]), using: SymmetricKey(data: prk)
    )
    return Data(block.prefix(32))
  }

  private static func blobAAD(vaultID: String, blobID: String, index: Int, total: Int, length: Int) -> Data {
    Data("VLSA".utf8) + Data([1]) + uint16(vaultID.utf8.count) + Data(vaultID.utf8) +
      uint16(blobID.utf8.count) + Data(blobID.utf8) + uint32(index) + uint64(total) + uint32(length)
  }

  private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
  }

  private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    (0..<4).reduce(0) { ($0 << 8) | UInt32(bytes[offset + $1]) }
  }

  private static func readUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
    (0..<8).reduce(0) { ($0 << 8) | UInt64(bytes[offset + $1]) }
  }

  private static func uint16(_ value: Int) -> Data {
    Data([UInt8(value >> 8), UInt8(value & 0xff)])
  }

  private static func uint32(_ value: Int) -> Data {
    Data((0..<4).reversed().map { UInt8((value >> ($0 * 8)) & 0xff) })
  }

  private static func uint64(_ value: Int) -> Data {
    Data((0..<8).reversed().map { UInt8((value >> ($0 * 8)) & 0xff) })
  }
}
