#!/usr/bin/env swift
/// Validates the Wheelp E2E crypto protocol independently of the app build.
/// Mirrors the logic in HelpCrypto.swift. Run with: swift scripts/validate.swift
import Foundation
import CryptoKit

var failures = 0
func check(_ ok: Bool, _ label: String) {
    if ok { print("ok    \(label)") } else { print("FAIL  \(label)"); failures += 1 }
}

// MARK: - Protocol functions (mirrors HelpCrypto.swift)

func approximate(_ value: Double) -> Double {
    (value * 100).rounded() / 100
}

func seal(_ data: Data, with key: SymmetricKey) -> String? {
    (try? AES.GCM.seal(data, using: key))?.combined?.base64EncodedString()
}

func open(_ base64: String, with key: SymmetricKey) -> Data? {
    guard let data = Data(base64Encoded: base64),
          let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
    return try? AES.GCM.open(box, using: key)
}

func meetingCode(from key: SymmetricKey) -> String {
    let mac = HMAC<SHA256>.authenticationCode(
        for: Data("wheelp.meeting.code.v1".utf8),
        using: key
    )
    let value = Data(mac).prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    return String(format: "%06d", value % 1_000_000)
}

func sharedKey(
    myPrivate: Curve25519.KeyAgreement.PrivateKey,
    theirPublic: Curve25519.KeyAgreement.PublicKey,
    requestId: UUID
) -> SymmetricKey? {
    guard let shared = try? myPrivate.sharedSecretFromKeyAgreement(with: theirPublic) else { return nil }
    return shared.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: Data(requestId.uuidString.utf8),
        sharedInfo: Data("wheelp-help".utf8),
        outputByteCount: 32
    )
}

// MARK: - Tests

// approximate
check(approximate(41.38512) == 41.39, "approximate rounds to 2 decimal places")
check(approximate(-3.70499) == -3.70, "approximate handles negative")
check(approximate(0.0) == 0.0,        "approximate handles zero")

// seal / open round-trip
let key = SymmetricKey(size: .bits256)
let plaintext = Data("hola wheelp".utf8)
if let ct = seal(plaintext, with: key), let recovered = open(ct, with: key) {
    check(recovered == plaintext, "seal/open round-trip")
} else {
    check(false, "seal/open round-trip")
}

// wrong key must fail
let wrongKey = SymmetricKey(size: .bits256)
if let ct = seal(plaintext, with: key) {
    check(open(ct, with: wrongKey) == nil, "open with wrong key returns nil")
}

// meetingCode: 6 digits, deterministic, key-sensitive
let code = meetingCode(from: key)
check(code.count == 6,                        "meetingCode is 6 digits")
check(code.allSatisfy(\.isNumber),            "meetingCode is all digits")
check(meetingCode(from: key) == code,         "meetingCode is deterministic")
check(meetingCode(from: wrongKey) != code,    "meetingCode is key-sensitive")

// X25519 key agreement: alice and bob derive the same key
let requestId = UUID()
let alicePriv = Curve25519.KeyAgreement.PrivateKey()
let bobPriv   = Curve25519.KeyAgreement.PrivateKey()
guard let aliceKey = sharedKey(myPrivate: alicePriv, theirPublic: bobPriv.publicKey,   requestId: requestId),
      let bobKey   = sharedKey(myPrivate: bobPriv,   theirPublic: alicePriv.publicKey, requestId: requestId) else {
    print("FAIL  key agreement produced nil"); failures += 1; exit(Int32(failures))
}
check(aliceKey.withUnsafeBytes(Array.init) == bobKey.withUnsafeBytes(Array.init),
      "X25519: alice and bob derive identical key")

// different requestId yields different key
let otherId = UUID()
let aliceKey2 = sharedKey(myPrivate: alicePriv, theirPublic: bobPriv.publicKey, requestId: otherId)
check(aliceKey.withUnsafeBytes(Array.init) != aliceKey2!.withUnsafeBytes(Array.init),
      "different requestId yields different key")

// meeting codes match after key agreement
check(meetingCode(from: aliceKey) == meetingCode(from: bobKey),
      "meeting codes match on both sides after key agreement")

// encrypt with alice's key, decrypt with bob's (they're identical, but exercise the path)
if let ct = seal(plaintext, with: aliceKey), let dec = open(ct, with: bobKey) {
    check(dec == plaintext, "cross-party seal/open with agreed key")
}

// MARK: - Result
print(failures == 0 ? "\nAll \(12) tests passed." : "\n\(failures) test(s) FAILED.")
if failures > 0 { exit(1) }
