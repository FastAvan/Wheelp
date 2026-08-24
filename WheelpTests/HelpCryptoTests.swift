import XCTest
import CryptoKit
@testable import Wheelp

/// Prueba el protocolo E2E real de HelpCrypto (no una reimplementación aparte,
/// como scripts/validate.swift) contra el código que corre en producción.
final class HelpCryptoTests: XCTestCase {

    // MARK: - approximate(): redondeo a ~1km sin revelar el punto exacto

    func testApproximateRoundsToTwoDecimals() {
        XCTAssertEqual(HelpCrypto.approximate(40.4168123), 40.42, accuracy: 0.0001)
        XCTAssertEqual(HelpCrypto.approximate(-3.7038), -3.7, accuracy: 0.0001)
    }

    // MARK: - seal/open: cifrado y descifrado simétrico

    func testSealOpenRoundTrip() {
        let key = SymmetricKey(size: .bits256)
        let original = "mensaje de prueba con ñ y emoji 🚀".data(using: .utf8)!

        guard let sealed = HelpCrypto.seal(original, with: key) else {
            return XCTFail("seal() no debería devolver nil")
        }
        guard let opened = HelpCrypto.open(sealed, with: key) else {
            return XCTFail("open() no debería devolver nil con la clave correcta")
        }
        XCTAssertEqual(opened, original)
    }

    func testOpenFailsWithWrongKey() {
        let key = SymmetricKey(size: .bits256)
        let wrongKey = SymmetricKey(size: .bits256)
        let sealed = HelpCrypto.seal(Data("secreto".utf8), with: key)!
        XCTAssertNil(HelpCrypto.open(sealed, with: wrongKey))
    }

    func testSealJSONOpenJSONRoundTrip() {
        let key = SymmetricKey(size: .bits256)
        let details = RequesterDetails(
            name: "Álvaro",
            originLatitude: 40.42,
            originLongitude: -3.70,
            destinationLatitude: 40.43,
            destinationLongitude: -3.71,
            meetingPoint: "Puerta del Sol",
            meetingName: nil,
            meetingLatitude: 40.4169,
            meetingLongitude: -3.7035
        )
        guard let sealed = HelpCrypto.sealJSON(details, with: key) else {
            return XCTFail("sealJSON() no debería devolver nil")
        }
        guard let opened = HelpCrypto.openJSON(RequesterDetails.self, from: sealed, with: key) else {
            return XCTFail("openJSON() no debería devolver nil")
        }
        XCTAssertEqual(opened.name, details.name)
        XCTAssertEqual(opened.meetingPoint, details.meetingPoint)
        XCTAssertEqual(opened.destinationLatitude, details.destinationLatitude, accuracy: 0.0001)
    }

    func testOpenJSONReturnsNilForNilInput() {
        let key = SymmetricKey(size: .bits256)
        XCTAssertNil(HelpCrypto.openJSON(RequesterDetails.self, from: nil, with: key))
    }

    // MARK: - Acuerdo de claves X25519: dos dispositivos derivan la misma clave

    func testSymmetricKeyAgreementMatchesBothSides() {
        let requestId = UUID()
        let alicePrivate = Curve25519.KeyAgreement.PrivateKey()
        let bobPrivate = Curve25519.KeyAgreement.PrivateKey()
        let alicePublicB64 = alicePrivate.publicKey.rawRepresentation.base64EncodedString()
        let bobPublicB64 = bobPrivate.publicKey.rawRepresentation.base64EncodedString()

        guard let aliceKey = HelpCrypto.symmetricKey(
            requestId: requestId, myPrivateKey: alicePrivate, otherPublicKeyBase64: bobPublicB64
        ) else {
            return XCTFail("Alice no pudo derivar la clave compartida")
        }
        guard let bobKey = HelpCrypto.symmetricKey(
            requestId: requestId, myPrivateKey: bobPrivate, otherPublicKeyBase64: alicePublicB64
        ) else {
            return XCTFail("Bob no pudo derivar la clave compartida")
        }

        XCTAssertEqual(aliceKey.withUnsafeBytes { Data($0) }, bobKey.withUnsafeBytes { Data($0) })
    }

    func testSymmetricKeyDiffersForDifferentRequestIds() {
        let alicePrivate = Curve25519.KeyAgreement.PrivateKey()
        let bobPrivate = Curve25519.KeyAgreement.PrivateKey()
        let bobPublicB64 = bobPrivate.publicKey.rawRepresentation.base64EncodedString()

        let keyA = HelpCrypto.symmetricKey(requestId: UUID(), myPrivateKey: alicePrivate, otherPublicKeyBase64: bobPublicB64)!
        let keyB = HelpCrypto.symmetricKey(requestId: UUID(), myPrivateKey: alicePrivate, otherPublicKeyBase64: bobPublicB64)!

        XCTAssertNotEqual(keyA.withUnsafeBytes { Data($0) }, keyB.withUnsafeBytes { Data($0) })
    }

    func testSymmetricKeyReturnsNilForInvalidBase64() {
        let alicePrivate = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertNil(HelpCrypto.symmetricKey(requestId: UUID(), myPrivateKey: alicePrivate, otherPublicKeyBase64: "no es base64 válido!!"))
    }

    // MARK: - meetingCode: código de 6 dígitos determinista y compartido

    func testMeetingCodeIsDeterministicAndSixDigits() {
        let key = SymmetricKey(size: .bits256)
        let code1 = HelpCrypto.meetingCode(from: key)
        let code2 = HelpCrypto.meetingCode(from: key)
        XCTAssertEqual(code1, code2)
        XCTAssertEqual(code1.count, 6)
        XCTAssertNotNil(Int(code1))
    }

    func testMeetingCodeMatchesOnBothDevices() {
        let requestId = UUID()
        let alicePrivate = Curve25519.KeyAgreement.PrivateKey()
        let bobPrivate = Curve25519.KeyAgreement.PrivateKey()
        let alicePublicB64 = alicePrivate.publicKey.rawRepresentation.base64EncodedString()
        let bobPublicB64 = bobPrivate.publicKey.rawRepresentation.base64EncodedString()

        let aliceKey = HelpCrypto.symmetricKey(requestId: requestId, myPrivateKey: alicePrivate, otherPublicKeyBase64: bobPublicB64)!
        let bobKey = HelpCrypto.symmetricKey(requestId: requestId, myPrivateKey: bobPrivate, otherPublicKeyBase64: alicePublicB64)!

        XCTAssertEqual(HelpCrypto.meetingCode(from: aliceKey), HelpCrypto.meetingCode(from: bobKey))
    }

    func testMeetingCodeDiffersForDifferentKeys() {
        let code1 = HelpCrypto.meetingCode(from: SymmetricKey(size: .bits256))
        let code2 = HelpCrypto.meetingCode(from: SymmetricKey(size: .bits256))
        XCTAssertNotEqual(code1, code2)
    }

    // Nota: savePrivateKey/privateKey/forget usan el Llavero (SecItemAdd/Copy),
    // que requiere un app host firmado con entitlement de keychain-access-group.
    // No se prueban aquí porque el build de CI/simulador corre sin firma
    // (CODE_SIGNING_ALLOWED=NO) y SecItemAdd falla silenciosamente en ese modo
    // — no es un caso que XCTest pueda cubrir de forma fiable sin firma real.
}
