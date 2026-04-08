/*
* ========================================================================== *
*                                                                            *
*    This file is part of the Openterface Mini KVM                           *
*                                                                            *
*    Copyright (C) 2024   <info@openterface.com>                             *
*                                                                            *
*    This program is free software: you can redistribute it and/or modify    *
*    it under the terms of the GNU General Public License as published by    *
*    the Free Software Foundation version 3.                                 *
*                                                                            *
*    This program is distributed in the hope that it will be useful, but     *
*    WITHOUT ANY WARRANTY; without even the implied warranty of              *
*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU        *
*    General Public License for more details.                                *
*                                                                            *
*    You should have received a copy of the GNU General Public License       *
*    along with this program. If not, see <http://www.gnu.org/licenses/>.   *
*                                                                            *
* ========================================================================== *
*/

import XCTest
import CommonCrypto
@testable import openterface

// MARK: - NTLMv2 / CredSSP pipeline tests
//
// Tests exercise the public API of NTLMAuth and validate wire-format correctness
// using the normative test vectors from MS-NLMP §4.2.2 and CredSSP observations.
//
// NOTE: NTLMAuth helpers (hmacMD5, md4Hash, …) are file-private; they are
// re-implemented below as test-local helpers to produce reference values for
// comparison rather than white-box testing of those symbols.

// MARK: - Reference crypto helpers (test-local)

private func testHmacMD5(key: Data, data: Data) -> Data {
    var mac = Data(count: Int(CC_MD5_DIGEST_LENGTH))
    mac.withUnsafeMutableBytes { macPtr in
        data.withUnsafeBytes { dataPtr in
            key.withUnsafeBytes { keyPtr in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgMD5),
                       keyPtr.baseAddress, key.count,
                       dataPtr.baseAddress, data.count,
                       macPtr.baseAddress)
            }
        }
    }
    return mac
}

private func testMD4(_ data: Data) -> Data {
    var hash = Data(count: Int(CC_MD4_DIGEST_LENGTH))
    hash.withUnsafeMutableBytes { hashPtr in
        data.withUnsafeBytes { dataPtr in
            CC_MD4(dataPtr.baseAddress, CC_LONG(data.count),
                   hashPtr.bindMemory(to: UInt8.self).baseAddress)
        }
    }
    return hash
}

private func testMD5(_ data: Data) -> Data {
    var hash = Data(count: Int(CC_MD5_DIGEST_LENGTH))
    hash.withUnsafeMutableBytes { hashPtr in
        data.withUnsafeBytes { dataPtr in
            CC_MD5(dataPtr.baseAddress, CC_LONG(data.count),
                   hashPtr.bindMemory(to: UInt8.self).baseAddress)
        }
    }
    return hash
}

private func utf16le(_ s: String) -> Data { s.data(using: .utf16LittleEndian) ?? Data() }

// MARK: - MS-NLMP §3.4 normative test vectors (abbreviated for sign/seal focus)
// Username = "User", Password = "Password", Domain = "Domain",
// ServerChallenge = 0102030405060708
private let msNlmpUsername = "User"
private let msNlmpPassword = "Password"
private let msNlmpDomain   = "Domain"
private let msNlmpServerChallenge = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

// ─────────────────────────────────────────────────────────────────────────────

final class RDPNTLMNegotiateTests: XCTestCase {

    // MARK: NEGOTIATE wire format

    func testNegotiateSignature() {
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        let msg = auth.negotiate()
        XCTAssertGreaterThanOrEqual(msg.count, 32, "NEGOTIATE must be at least 32 bytes")
        // First 8 bytes: "NTLMSSP\0"
        XCTAssertEqual(msg.prefix(8), Data("NTLMSSP\0".utf8), "Signature must be NTLMSSP\\0")
    }

    func testNegotiateMessageType() {
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        let msg = auth.negotiate()
        let msgType = msg.subdata(in: 8..<12)
            .withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(msgType, 1, "NEGOTIATE MessageType must be 1")
    }

    func testNegotiateRequiredFlags() {
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        let msg = auth.negotiate()
        let flags = msg.subdata(in: 12..<16)
            .withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }

        let unicode:          UInt32 = 0x0000_0001
        let ntlm:             UInt32 = 0x0000_0200
        let extendedSec:      UInt32 = 0x0008_0000
        let keyExchange:      UInt32 = 0x4000_0000

        XCTAssertNotEqual(flags & unicode,     0, "UNICODE flag must be set")
        XCTAssertNotEqual(flags & ntlm,        0, "NTLM flag must be set")
        XCTAssertNotEqual(flags & extendedSec, 0, "EXTENDED_SEC flag must be set")
        XCTAssertNotEqual(flags & keyExchange, 0, "KEY_EXCHANGE flag must be set")

        let bits128:          UInt32 = 0x2000_0000
        let bits56:           UInt32 = 0x8000_0000
        XCTAssertNotEqual(flags & bits128, 0, "128-bit encryption flag must be set (required by FreeRDP/mstsc)")
        XCTAssertNotEqual(flags & bits56,  0, "56-bit encryption flag must be set (required by FreeRDP/mstsc)")
    }

    func testNegotiateVersionField() {
        // Version field (10.0.19041, rev 15) starts at offset 32 in a compact NEGOTIATE
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        let msg = auth.negotiate()
        // Major = 10, Minor = 0 at offsets 32 and 33 (after 8-byte sig, 4-byte type,
        // 4-byte flags, 8-byte domain buf, 8-byte workstation buf = 32 bytes fixed header)
        XCTAssertGreaterThanOrEqual(msg.count, 40)
        XCTAssertEqual(msg[32], 10, "Version major should be 10 (Windows 10)")
        XCTAssertEqual(msg[33], 0,  "Version minor should be 0")
        // NTLM revision at offset 39 = 15
        XCTAssertEqual(msg[39], 15, "NTLM revision should be 15")
    }
}

// ─────────────────────────────────────────────────────────────────────────────

final class RDPNTLMChallengeTests: XCTestCase {

    // Minimal valid NTLM CHALLENGE blob (padded to 56 bytes minimum, no TargetInfo)
    private func makeMinimalChallenge(challenge: Data) -> Data {
        var blob = Data()
        blob.append(contentsOf: Array("NTLMSSP\0".utf8))  // signature [0..7]
        blob.append(contentsOf: [0x02, 0x00, 0x00, 0x00]) // type=2 [8..11]
        blob.append(Data(repeating: 0, count: 8))          // TargetNameFields [12..19]
        // NegotiateFlags [20..23]: NTLM | Unicode | ExtendedSec | TargetInfo
        let flags: UInt32 = 0x02820201
        blob.append(contentsOf: withUnsafeBytes(of: flags.littleEndian) { Array($0) })
        blob.append(challenge)                             // ServerChallenge [24..31]
        blob.append(Data(repeating: 0, count: 8))          // Reserved [32..39]
        // TargetInfo: empty (len=0, maxLen=0, offset=56)
        blob.append(contentsOf: [0x00, 0x00])              // len
        blob.append(contentsOf: [0x00, 0x00])              // maxLen
        blob.append(contentsOf: [0x38, 0x00, 0x00, 0x00]) // offset=56
        blob.append(Data(repeating: 0, count: 8))          // Version [48..55]
        return blob // 56 bytes
    }

    func testParseChallengeReturnsTrueOnValidBlob() {
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        let blob = makeMinimalChallenge(challenge: msNlmpServerChallenge)
        XCTAssertTrue(auth.parseChallenge(blob), "parseChallenge should return true on valid CHALLENGE message")
    }

    func testParseChallengeReturnsFalseOnShortBlob() {
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        XCTAssertFalse(auth.parseChallenge(Data(repeating: 0, count: 20)),
                       "parseChallenge should reject a blob shorter than 56 bytes")
    }

    func testParseChallengeReturnsFalseOnBadSignature() {
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        var blob = makeMinimalChallenge(challenge: msNlmpServerChallenge)
        blob[0] = 0xFF  // corrupt signature
        XCTAssertFalse(auth.parseChallenge(blob), "parseChallenge should reject bad NTLMSSP signature")
    }

    func testParseChallengeReturnsFalseOnWrongMessageType() {
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        var blob = makeMinimalChallenge(challenge: msNlmpServerChallenge)
        blob[8] = 0x03  // MessageType=3 (AUTHENTICATE)
        XCTAssertFalse(auth.parseChallenge(blob), "parseChallenge should reject non-CHALLENGE message type")
    }

    func testSessionKeyIsNilBeforeAuthenticate() {
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        XCTAssertNil(auth.sessionKey, "sessionKey must be nil before authenticate()")
    }
}

// ─────────────────────────────────────────────────────────────────────────────

final class RDPNTLMAuthenticateTests: XCTestCase {

    private func makeChallenge(serverChallenge: Data, targetInfo: Data) -> Data {
        var blob = Data()
        blob.append(contentsOf: Array("NTLMSSP\0".utf8))
        blob.append(contentsOf: [0x02, 0x00, 0x00, 0x00]) // type=2
        blob.append(Data(repeating: 0, count: 8))          // TargetNameFields
        let flags: UInt32 = 0x628A8201  // typical Windows challenge flags
        blob.append(contentsOf: withUnsafeBytes(of: flags.littleEndian) { Array($0) })
        blob.append(serverChallenge)                        // [24..31]
        blob.append(Data(repeating: 0, count: 8))           // reserved
        // TargetInfo security buffer: len/maxLen/offset
        let tiLen = UInt16(targetInfo.count)
        let tiOffset: UInt32 = 56
        blob.append(contentsOf: withUnsafeBytes(of: tiLen.littleEndian)    { Array($0) }) // len
        blob.append(contentsOf: withUnsafeBytes(of: tiLen.littleEndian)    { Array($0) }) // maxLen
        blob.append(contentsOf: withUnsafeBytes(of: tiOffset.littleEndian) { Array($0) }) // offset
        blob.append(Data(repeating: 0, count: 8))    // version [48..55]
        blob.append(targetInfo)
        return blob
    }

    // Minimal MsvAvEOL TargetInfo
    private var eolTargetInfo: Data {
        Data([0x00, 0x00, 0x00, 0x00]) // MsvAvEOL id=0 len=0
    }

    func testAuthenticateSignature() {
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        let challenge = makeChallenge(serverChallenge: msNlmpServerChallenge, targetInfo: eolTargetInfo)
        XCTAssertTrue(auth.parseChallenge(challenge))
        let msg = auth.authenticate()
        XCTAssertEqual(msg.prefix(8), Data("NTLMSSP\0".utf8), "AUTHENTICATE signature must be NTLMSSP\\0")
    }

    func testAuthenticateMessageType() {
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        let challenge = makeChallenge(serverChallenge: msNlmpServerChallenge, targetInfo: eolTargetInfo)
        _ = auth.parseChallenge(challenge)
        let msg = auth.authenticate()
        let msgType = msg.subdata(in: 8..<12)
            .withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(msgType, 3, "AUTHENTICATE MessageType must be 3")
    }

    func testAuthenticateMinimumLength() {
        // 88-byte fixed header + at least some payload
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        let challenge = makeChallenge(serverChallenge: msNlmpServerChallenge, targetInfo: eolTargetInfo)
        _ = auth.parseChallenge(challenge)
        let msg = auth.authenticate()
        XCTAssertGreaterThanOrEqual(msg.count, 88,
            "AUTHENTICATE fixed header is 88 bytes; total must be at least that")
    }

    func testAuthenticateSecurityBufferOffsets() {
        // All security buffer offsets must point within the message.
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        let challenge = makeChallenge(serverChallenge: msNlmpServerChallenge, targetInfo: eolTargetInfo)
        _ = auth.parseChallenge(challenge)
        let msg = auth.authenticate()

        // Security buffer layout starting at offset 12:
        // [12..19] LmChallengeResponse (len, maxLen, offset)
        // [20..27] NtChallengeResponse
        // [28..35] DomainName
        // [36..43] UserName
        // [44..51] Workstation
        // [52..59] EncryptedRandomSessionKey
        let fields: [(name: String, offset: Int)] = [
            ("LmResponse",   12),
            ("NtResponse",   20),
            ("Domain",       28),
            ("User",         36),
            ("Workstation",  44),
            ("SessionKey",   52),
        ]
        for field in fields {
            let len    = Int(msg.subdata(in: field.offset..<(field.offset + 2))
                              .withUnsafeBytes { $0.load(as: UInt16.self).littleEndian })
            let bufOff = Int(msg.subdata(in: (field.offset + 4)..<(field.offset + 8))
                              .withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
            XCTAssertGreaterThanOrEqual(bufOff + len, bufOff,
                "\(field.name) offset+len must not overflow")
            XCTAssertLessThanOrEqual(bufOff + len, msg.count,
                "\(field.name) data (off=\(bufOff) len=\(len)) must lie within AUTHENTICATE message (len=\(msg.count))")
        }
    }

    func testAuthenticateDomainNameCorrect() {
        let auth = NTLMAuth(username: "Alice", password: "p4ss", domain: "ACME")
        let challenge = makeChallenge(serverChallenge: msNlmpServerChallenge, targetInfo: eolTargetInfo)
        _ = auth.parseChallenge(challenge)
        let msg = auth.authenticate()
        // Domain security buffer at [28..35]
        let len    = Int(msg.subdata(in: 28..<30).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian })
        let bufOff = Int(msg.subdata(in: 32..<36).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
        let domainData = msg.subdata(in: bufOff..<(bufOff + len))
        XCTAssertEqual(domainData, "ACME".data(using: .utf16LittleEndian),
            "Domain field in AUTHENTICATE must be UTF-16LE encoded domain name")
    }

    func testAuthenticateUserNameCorrect() {
        let auth = NTLMAuth(username: "Alice", password: "p4ss", domain: "ACME")
        let challenge = makeChallenge(serverChallenge: msNlmpServerChallenge, targetInfo: eolTargetInfo)
        _ = auth.parseChallenge(challenge)
        let msg = auth.authenticate()
        // UserName security buffer at [36..43]
        let len    = Int(msg.subdata(in: 36..<38).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian })
        let bufOff = Int(msg.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
        let userNameData = msg.subdata(in: bufOff..<(bufOff + len))
        XCTAssertEqual(userNameData, "Alice".data(using: .utf16LittleEndian),
            "UserName field in AUTHENTICATE must be UTF-16LE encoded username")
    }

    func testAuthenticateSessionKeyAvailableAfterAuthenticate() {
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        let challenge = makeChallenge(serverChallenge: msNlmpServerChallenge, targetInfo: eolTargetInfo)
        _ = auth.parseChallenge(challenge)
        _ = auth.authenticate()
        XCTAssertNotNil(auth.sessionKey, "sessionKey must be set after authenticate()")
        XCTAssertEqual(auth.sessionKey?.count, 16, "ExportedSessionKey must be 16 bytes")
    }

    func testAuthenticateEncryptedSessionKeyLength() {
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        let challenge = makeChallenge(serverChallenge: msNlmpServerChallenge, targetInfo: eolTargetInfo)
        _ = auth.parseChallenge(challenge)
        _ = auth.authenticate()
        XCTAssertEqual(auth.encryptedRandomSessionKey?.count, 16,
            "EncryptedRandomSessionKey must be 16 bytes")
    }

    func testAuthenticateSignKeysAvailable() {
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        let challenge = makeChallenge(serverChallenge: msNlmpServerChallenge, targetInfo: eolTargetInfo)
        _ = auth.parseChallenge(challenge)
        _ = auth.authenticate()
        XCTAssertEqual(auth.sendSignKey?.count, 16, "sendSignKey must be 16 bytes (MD5 hash)")
        XCTAssertEqual(auth.recvSignKey?.count, 16, "recvSignKey must be 16 bytes (MD5 hash)")
    }

    // Validate sign key derivation constants (MS-NLMP §3.4.5.1)
    func testSendSignKeyMagic() {
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        let challenge = makeChallenge(serverChallenge: msNlmpServerChallenge, targetInfo: eolTargetInfo)
        _ = auth.parseChallenge(challenge)
        _ = auth.authenticate()
        guard let sessionKey = auth.sessionKey, let sendKey = auth.sendSignKey else {
            XCTFail("sessionKey or sendSignKey nil")
            return
        }
        let magic = "session key to client-to-server signing key magic constant\0"
        let expected = testMD5(sessionKey + Data(magic.utf8))
        XCTAssertEqual(sendKey, expected, "sendSignKey derivation must use client-to-server magic constant")
    }

    func testRecvSignKeyMagic() {
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        let challenge = makeChallenge(serverChallenge: msNlmpServerChallenge, targetInfo: eolTargetInfo)
        _ = auth.parseChallenge(challenge)
        _ = auth.authenticate()
        guard let sessionKey = auth.sessionKey, let recvKey = auth.recvSignKey else {
            XCTFail("sessionKey or recvSignKey nil")
            return
        }
        let magic = "session key to server-to-client signing key magic constant\0"
        let expected = testMD5(sessionKey + Data(magic.utf8))
        XCTAssertEqual(recvKey, expected, "recvSignKey derivation must use server-to-client magic constant")
    }

    // NT hash for known password: MD4(UTF-16LE("Password"))
    // Expected from MS-NLMP §4.2.2.1: a4f49c406510bdcab6824ee7c30fd852
    func testNTHashForKnownPassword() {
        let expected = Data([0xa4, 0xf4, 0x9c, 0x40, 0x65, 0x10, 0xbd, 0xca,
                             0xb6, 0x82, 0x4e, 0xe7, 0xc3, 0x0f, 0xd8, 0x52])
        let ntHash = testMD4(utf16le("Password"))
        XCTAssertEqual(ntHash, expected, "NT hash of 'Password' must match MS-NLMP §4.2.2.1 vector")
    }

    // Verify NTProofStr derivation using known MS-NLMP input (trimmed: no TargetInfo augmentation)
    func testResponseKeyNTForKnownInputs() {
        // ResponseKeyNT = HMAC_MD5(NT_Hash, UTF16LE(upper(username)) + UTF16LE(domain))
        // NT_Hash = MD4(UTF16LE("Password")) = a4f49c406510bdcab6824ee7c30fd852 (matches §4.2.2.1.1)
        // ResponseKeyNT with ("USER", "Domain") = 0c868a403bfd7a93a3001ef22ef02e3f
        let ntHash = testMD4(utf16le("Password"))
        let responseKey = testHmacMD5(key: ntHash,
                                      data: utf16le("USER") + utf16le("Domain"))
        let expected = Data([0x0c, 0x86, 0x8a, 0x40, 0x3b, 0xfd, 0x7a, 0x93,
                             0xa3, 0x00, 0x1e, 0xf2, 0x2e, 0xf0, 0x2e, 0x3f])
        XCTAssertEqual(responseKey, expected, "ResponseKeyNT must match computed HMAC-MD5(NT_Hash, USER+Domain)")
    }
}

// ─────────────────────────────────────────────────────────────────────────────

final class RDPAuthenticateOffsetTests: XCTestCase {
    // Regression test: security buffer offsets must be ≥ 88 (fixed header size).
    // Pre-fix this failed because fixedSize was 72, causing all offsets to be 16 too small.

    private func minimalChallenge() -> Data {
        var b = Data()
        b.append(contentsOf: Array("NTLMSSP\0".utf8))
        b.append(contentsOf: [0x02, 0x00, 0x00, 0x00])
        b.append(Data(repeating: 0, count: 8))
        let flags: UInt32 = 0x628A8201
        b.append(contentsOf: withUnsafeBytes(of: flags.littleEndian) { Array($0) })
        b.append(Data([1, 2, 3, 4, 5, 6, 7, 8])) // serverChallenge
        b.append(Data(repeating: 0, count: 8))
        // TargetInfo: EOL only (4 bytes) at offset 56
        b.append(contentsOf: [0x04, 0x00, 0x04, 0x00])  // len=4, maxLen=4
        b.append(contentsOf: [0x38, 0x00, 0x00, 0x00])  // offset=56
        b.append(Data(repeating: 0, count: 8))           // version
        b.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // MsvAvEOL
        return b
    }

    func testAllSecurityBufferOffsetsAtLeast88() {
        let auth = NTLMAuth(username: "user", password: "pass", domain: "DOMAIN")
        XCTAssertTrue(auth.parseChallenge(minimalChallenge()))
        let msg = auth.authenticate()

        let fieldNames = ["LmResponse", "NtResponse", "Domain", "UserName", "Workstation", "EncSessKey"]
        let fieldOffsets = [12, 20, 28, 36, 44, 52]

        for (name, off) in zip(fieldNames, fieldOffsets) {
            let len    = Int(msg.subdata(in: off..<(off + 2))
                              .withUnsafeBytes { $0.load(as: UInt16.self).littleEndian })
            let bufOff = Int(msg.subdata(in: (off + 4)..<(off + 8))
                              .withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
            if len > 0 {
                XCTAssertGreaterThanOrEqual(bufOff, 88,
                    "\(name) offset (\(bufOff)) must be ≥ 88 (fixed header size); was payload offset calculation wrong?")
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Minimal DER helpers (test-local, mirrors production impl)
// ─────────────────────────────────────────────────────────────────────────────

private func derLen(_ n: Int) -> Data {
    if n < 0x80 { return Data([UInt8(n)]) }
    var bytes = withUnsafeBytes(of: UInt32(n).bigEndian) { Data($0) }
    while bytes.first == 0 && bytes.count > 1 { bytes.removeFirst() }
    var out = Data([0x80 | UInt8(bytes.count)]); out.append(bytes); return out
}
private func derTLV(_ tag: UInt8, _ content: Data) -> Data {
    var out = Data([tag]); out.append(derLen(content.count)); out.append(content); return out
}
private func derSeq(_ c: Data) -> Data { derTLV(0x30, c) }
private func derCtx(_ tag: UInt8, _ c: Data) -> Data { derTLV(0xA0 | tag, c) }
private func derInt(_ v: UInt8) -> Data { derTLV(0x02, Data([v])) }
private func derOctet(_ d: Data) -> Data { derTLV(0x04, d) }

private let spnegoOID = Data([0x06, 0x06, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x02])
private let ntlmOID   = Data([0x06, 0x0a, 0x2b, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0a])

// Test-local SPNEGO builders for reference comparison
private func refNegTokenInit(mechToken: Data) -> Data {
    // Only NTLM OID in mechTypes — NEGOEX is not used for pure NTLM auth
    let mechTypesSeq    = derTLV(0x30, ntlmOID)
    let mechTypesField  = derCtx(0, mechTypesSeq)
    let mechTokenField  = derCtx(2, derOctet(mechToken))
    let negTokenInit    = derSeq(mechTypesField + mechTokenField)
    let ctxZero         = derCtx(0, negTokenInit)
    return derTLV(0x60, spnegoOID + ctxZero)
}

private func refNegTokenResp(token: Data) -> Data {
    let responseField = derCtx(2, derOctet(token))
    let seq           = derSeq(responseField)
    return derCtx(1, seq)
}

private func refBuildTSRequest(negoToken: Data, version: UInt8, clientNonce: Data) -> Data {
    let inner  = derCtx(0, derOctet(negoToken))
    let item   = derSeq(inner)
    let tokSeq = derSeq(item)
    let vf     = derCtx(0, derInt(version))
    let nf     = derCtx(1, tokSeq)
    let cf     = derCtx(5, derOctet(clientNonce))
    return derSeq(vf + nf + cf)
}

// ─────────────────────────────────────────────────────────────────────────────

final class SPNEGOStructureTests: XCTestCase {

    func testNegTokenInitStartByte() {
        let token = Data(repeating: 0x41, count: 16)
        let spnego = refNegTokenInit(mechToken: token)
        XCTAssertEqual(spnego.first, 0x60, "NegTokenInit must start with APPLICATION[0] tag 0x60")
    }

    func testNegTokenInitContainsSpnegoOID() {
        let token = Data(repeating: 0x41, count: 16)
        let spnego = refNegTokenInit(mechToken: token)
        // SPNEGO OID bytes must appear after the 0x60 tag+length header
        let spnegoBytes = [UInt8](spnego)
        let oidBytes: [UInt8] = [0x06, 0x06, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x02]
        let found = spnegoBytes.windows(ofCount: 8).contains { Array($0) == oidBytes }
        XCTAssertTrue(found, "SPNEGO OID (1.3.6.1.5.5.2) must be present in NegTokenInit wrapper")
    }

    func testNegTokenInitContainsNtlmOID() {
        let token = Data(repeating: 0x41, count: 16)
        let spnego = refNegTokenInit(mechToken: token)
        let spnegoBytes = [UInt8](spnego)
        let oidBytes: [UInt8] = [0x06, 0x0a, 0x2b, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0a]
        let found = spnegoBytes.windows(ofCount: 12).contains { Array($0) == oidBytes }
        XCTAssertTrue(found, "NTLM OID (1.3.6.1.4.1.311.2.2.10) must be present in mechTypes list")
    }

    func testNegTokenInitDoesNotContainNegoexOID() {
        // NEGOEX OID must NOT be present for pure NTLM — Windows SSPI would try
        // to parse the raw NTLM mechToken as NEGOEX format → SEC_E_INVALID_TOKEN
        let token = Data(repeating: 0x41, count: 16)
        let spnego = refNegTokenInit(mechToken: token)
        let spnegoBytes = [UInt8](spnego)
        let negoexBytes: [UInt8] = [0x06, 0x0a, 0x2b, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x1e]
        let found = spnegoBytes.windows(ofCount: 12).contains { Array($0) == negoexBytes }
        XCTAssertFalse(found, "NEGOEX OID must NOT be present in mechTypes for pure NTLM auth")
    }

    func testNegTokenRespStartByte() {
        let token = Data(repeating: 0x42, count: 16)
        let resp = refNegTokenResp(token: token)
        XCTAssertEqual(resp.first, 0xA1, "NegTokenResp must start with context tag [1] = 0xA1")
    }

    func testNegTokenRespContainsToken() {
        let token = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let resp = refNegTokenResp(token: token)
        let bytes = [UInt8](resp)
        let found = bytes.windows(ofCount: 4).contains { Array($0) == [0xDE, 0xAD, 0xBE, 0xEF] }
        XCTAssertTrue(found, "NegTokenResp must contain the original raw token bytes")
    }
}

// ─────────────────────────────────────────────────────────────────────────────

final class TSRequestDERTests: XCTestCase {

    func testTSRequestStartsWithSequence() {
        let nonce = Data(repeating: 0xCC, count: 32)
        let token = Data(repeating: 0x41, count: 16)
        let req = refBuildTSRequest(negoToken: token, version: 6, clientNonce: nonce)
        XCTAssertEqual(req.first, 0x30, "TSRequest must start with DER SEQUENCE tag 0x30")
    }

    func testTSRequestVersionField() {
        let nonce = Data(repeating: 0xCC, count: 32)
        let token = Data(repeating: 0x41, count: 16)
        let req = refBuildTSRequest(negoToken: token, version: 6, clientNonce: nonce)
        // After SEQUENCE TL, first element should be [0] EXPLICIT INTEGER 6
        // i.e. bytes: A0 03 02 01 06
        let reqBytes = [UInt8](req)
        // Skip SEQUENCE tag+len (which is req[0] and one or more len bytes)
        // Search for the pattern A0 03 02 01 06
        let pattern: [UInt8] = [0xA0, 0x03, 0x02, 0x01, 0x06]
        let found = reqBytes.windows(ofCount: 5).contains { Array($0) == pattern }
        XCTAssertTrue(found, "TSRequest must contain [0] version = 6 as A0 03 02 01 06")
    }

    func testTSRequestNegoTokensField() {
        let nonce = Data(repeating: 0xCC, count: 32)
        let token = Data([0x4E, 0x54, 0x4C, 0x4D]) // "NTLM"
        let req = refBuildTSRequest(negoToken: token, version: 6, clientNonce: nonce)
        let reqBytes = [UInt8](req)
        // [1] context tag 0xA1 must be present for negoTokens
        let hasA1 = reqBytes.contains(0xA1)
        XCTAssertTrue(hasA1, "TSRequest must contain [1] negoTokens field (tag 0xA1)")
    }

    func testTSRequestClientNonceField() {
        let nonce = Data(repeating: 0xAB, count: 32)
        let token = Data(repeating: 0x41, count: 8)
        let req = refBuildTSRequest(negoToken: token, version: 6, clientNonce: nonce)
        let reqBytes = [UInt8](req)
        // [5] context tag 0xA5 must be present for clientNonce (v6)
        let hasA5 = reqBytes.contains(0xA5)
        XCTAssertTrue(hasA5, "TSRequest v6 must contain [5] clientNonce field (tag 0xA5)")
    }

    func testTSRequestClientNonceValue() {
        let nonce = Data((0..<32).map { UInt8($0) })  // 0x00..0x1F
        let token = Data(repeating: 0x41, count: 8)
        let req = refBuildTSRequest(negoToken: token, version: 6, clientNonce: nonce)
        let reqBytes = [UInt8](req)
        let nonceBytes = (0..<32).map { UInt8($0) }
        let found = reqBytes.windows(ofCount: 32).contains { Array($0) == nonceBytes }
        XCTAssertTrue(found, "TSRequest must embed the exact 32-byte clientNonce value")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper: sliding window on arrays (stdlib doesn't have this outside of Algorithms package)
// ─────────────────────────────────────────────────────────────────────────────

private extension Array {
    func windows(ofCount n: Int) -> [[Element]] {
        guard n > 0, count >= n else { return [] }
        return (0...(count - n)).map { Array(self[$0..<($0 + n)]) }
    }
}
