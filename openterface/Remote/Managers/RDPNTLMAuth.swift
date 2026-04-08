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

import Foundation
import CommonCrypto

// MARK: - NTLMv2 authentication for CredSSP (MS-NLMP)
//
// Full state machine:
//   1. NEGOTIATE_MESSAGE (client → server)
//   2. CHALLENGE_MESSAGE (server → client)
//   3. AUTHENTICATE_MESSAGE (client → server)
//
// References: [MS-NLMP], [MS-CSSP]

// swiftlint:disable function_body_length

// MARK: - NTLM Flags (subset used here)

private struct NTLMFlags {
    static let unicode:           UInt32 = 0x0000_0001  // NTLMSSP_NEGOTIATE_UNICODE
    static let oemFlag:           UInt32 = 0x0000_0002
    static let requestTarget:     UInt32 = 0x0000_0004
    static let sign:              UInt32 = 0x0000_0010  // NTLMSSP_NEGOTIATE_SIGN
    static let seal:              UInt32 = 0x0000_0020  // NTLMSSP_NEGOTIATE_SEAL
    static let alwaysSign:        UInt32 = 0x0000_8000  // NTLMSSP_NEGOTIATE_ALWAYS_SIGN
    static let ntlm:              UInt32 = 0x0000_0200  // NTLMSSP_NEGOTIATE_NTLM
    static let extendedSec:       UInt32 = 0x0008_0000  // NTLMSSP_NEGOTIATE_EXTENDED_SESSIONSECURITY
    static let targetInfo:        UInt32 = 0x0080_0000  // NTLMSSP_NEGOTIATE_TARGET_INFO
    static let version:           UInt32 = 0x0200_0000  // NTLMSSP_NEGOTIATE_VERSION
    static let bits128:           UInt32 = 0x2000_0000  // NTLMSSP_NEGOTIATE_128
    static let keyExchange:       UInt32 = 0x4000_0000  // NTLMSSP_NEGOTIATE_KEY_EXCH
    static let bits56:            UInt32 = 0x8000_0000  // NTLMSSP_NEGOTIATE_56
}

// MARK: - Helpers

private func hmacMD5(key: Data, data: Data) -> Data {
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

private func md4Hash(_ data: Data) -> Data {
    // CommonCrypto exposes CC_MD4 despite deprecation – still the correct function for NTLM
    var hash = Data(count: Int(CC_MD4_DIGEST_LENGTH))
    hash.withUnsafeMutableBytes { hashPtr in
        data.withUnsafeBytes { dataPtr in
            CC_MD4(dataPtr.baseAddress, CC_LONG(data.count), hashPtr.bindMemory(to: UInt8.self).baseAddress)
        }
    }
    return hash
}

private func md5Hash(_ data: Data) -> Data {
    var hash = Data(count: Int(CC_MD5_DIGEST_LENGTH))
    hash.withUnsafeMutableBytes { hashPtr in
        data.withUnsafeBytes { dataPtr in
            CC_MD5(dataPtr.baseAddress, CC_LONG(data.count), hashPtr.bindMemory(to: UInt8.self).baseAddress)
        }
    }
    return hash
}

/// RC4 single-use encrypt (for NTLM export key wrapping)
private func rc4(key: Data, data: Data) -> Data {
    var s = (0..<256).map { UInt8($0) }
    var j = 0
    for i in 0..<256 {
        j = (j + Int(s[i]) + Int(key[i % key.count])) & 0xFF
        s.swapAt(i, j)
    }
    var out = Data(count: data.count)
    var i = 0; j = 0
    for k in 0..<data.count {
        i = (i + 1) & 0xFF
        j = (j + Int(s[i])) & 0xFF
        s.swapAt(i, j)
        out[k] = data[k] ^ s[(Int(s[i]) + Int(s[j])) & 0xFF]
    }
    return out
}

private func le32(_ v: UInt32) -> Data {
    Data(withUnsafeBytes(of: v.littleEndian) { Array($0) })
}

private func le16(_ v: UInt16) -> Data {
    Data(withUnsafeBytes(of: v.littleEndian) { Array($0) })
}

private func randomBytes(_ n: Int) -> Data {
    var buf = Data(count: n)
    buf.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
    return buf
}

private func utf16LE(_ s: String) -> Data {
    s.data(using: .utf16LittleEndian) ?? Data()
}

// MARK: - Security Buffer helper

private func securityBuffer(data: Data, baseOffset: Int, currentPayloadOffset: Int) -> (header: Data, payload: Data) {
    let length = UInt16(data.count)
    var header = Data()
    header.append(le16(length))                               // Len
    header.append(le16(length))                               // MaxLen
    header.append(le32(UInt32(baseOffset + currentPayloadOffset)))  // Offset
    return (header, data)
}

// MARK: - NTLMAuth

final class NTLMAuth {

    // MARK: Session keys (available after authenticate() call)
    private(set) var sessionKey:    Data?   // ExportedSessionKey (16 B)
    private(set) var sendSignKey:   Data?   // Client→Server signing key
    private(set) var recvSignKey:   Data?   // Server→Client signing key
    private(set) var encryptedRandomSessionKey: Data?   // as sent on the wire

    /// Diagnostic info populated after authenticate() for logging by the caller.
    private(set) var diagnosticInfo: String = ""

    // NTLM seal state (available after authenticate())
    private var sendSealKey:  Data?
    private var recvSealKey:  Data?
    private var sendSealHandle: RC4Handle?
    private var recvSealHandle: RC4Handle?
    private var sendSeqNum: UInt32 = 0
    private var recvSeqNum: UInt32 = 0

    // Stored after parsing challenge
    private var serverChallenge  = Data(count: 8)
    private var targetInfoBlob   = Data()
    private var negotiateFlags:  UInt32 = 0

    // Raw message bytes saved for MIC computation (MS-NLMP §3.1.5.1.2)
    private var negotiateMessage = Data()
    private var challengeMessage = Data()

    // Stored from caller
    private let username:  String
    private let password:  String
    private let domain:    String
    private let workstation = "OPENTERFACE"

    init(username: String, password: String, domain: String) {
        self.username = username
        self.password = password
        self.domain   = domain
    }

    // MARK: - NTLM Seal / Unseal (MS-NLMP §3.4.4)

    /// Seal (encrypt + sign) a message. Returns `signature (16 B) || encryptedMessage`.
    func seal(_ plaintext: Data) -> Data? {
        guard let signKey = sendSignKey, let handle = sendSealHandle else { return nil }

        // 1. Encrypt the message
        let encrypted = handle.process(plaintext)

        // 2. Compute signature: HMAC_MD5(SigningKey, SeqNum || Message)[0:8], then RC4-encrypt checksum
        let seqLE = Data(withUnsafeBytes(of: sendSeqNum.littleEndian) { Array($0) })
        let mac = hmacMD5(key: signKey, data: seqLE + plaintext)
        let encChecksum = handle.process(mac.prefix(8))

        // 3. Build signature: Version(1) || EncryptedChecksum(8) || SeqNum(4)
        var sig = Data()
        sig.append(contentsOf: [0x01, 0x00, 0x00, 0x00])     // Version = 1
        sig.append(encChecksum)                                // 8 bytes
        sig.append(seqLE)                                      // 4 bytes

        print("[NTLM-SEAL] seqNum=\(sendSeqNum) plain[\(plaintext.count)] enc[\(encrypted.count)] mac-pre: \(mac.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))")
        sendSeqNum += 1
        return sig + encrypted
    }

    /// Unseal (decrypt + verify) a message. Input is `signature (16 B) || encryptedMessage`.
    /// Returns the plaintext, or nil if verification fails.
    func unseal(_ sealed: Data) -> Data? {
        guard sealed.count >= 16,
              let signKey = recvSignKey, let handle = recvSealHandle else { return nil }

        let sig = sealed.prefix(16)
        let encrypted = sealed.suffix(from: sealed.startIndex + 16)

        // 1. Decrypt
        let plaintext = handle.process(Data(encrypted))

        // 2. Verify signature
        let seqLE = Data(withUnsafeBytes(of: recvSeqNum.littleEndian) { Array($0) })
        let mac = hmacMD5(key: signKey, data: seqLE + plaintext)
        let encChecksum = handle.process(mac.prefix(8))

        var expectedSig = Data()
        expectedSig.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
        expectedSig.append(encChecksum)
        expectedSig.append(seqLE)

        recvSeqNum += 1

        // Verify (constant-time not critical here but we check fully)
        guard sig.elementsEqual(expectedSig) else { return nil }
        return plaintext
    }

    /// Sign a message (MAC only, no encryption). Returns 16-byte NTLM signature.
    /// Shares the same RC4 seal handle and SeqNum as seal(), so call order matters.
    func sign(_ message: Data) -> Data? {
        guard let signKey = sendSignKey, let handle = sendSealHandle else { return nil }

        let seqLE = Data(withUnsafeBytes(of: sendSeqNum.littleEndian) { Array($0) })
        let mac = hmacMD5(key: signKey, data: seqLE + message)
        let encChecksum = handle.process(mac.prefix(8))

        var sig = Data()
        sig.append(contentsOf: [0x01, 0x00, 0x00, 0x00])     // Version = 1
        sig.append(encChecksum)                                // 8 bytes
        sig.append(seqLE)                                      // 4 bytes

        sendSeqNum += 1
        return sig
    }

    // MARK: - Step 1: NEGOTIATE_MESSAGE

    func negotiate() -> Data {
        let flags: UInt32 =
            NTLMFlags.unicode       |
            NTLMFlags.requestTarget |
            NTLMFlags.ntlm          |
            NTLMFlags.extendedSec   |
            NTLMFlags.targetInfo    |
            NTLMFlags.keyExchange   |
            NTLMFlags.alwaysSign    |
            NTLMFlags.sign          |
            NTLMFlags.seal          |
            NTLMFlags.bits128       |   // 128-bit encryption support (matching FreeRDP/mstsc)
            NTLMFlags.bits56        |   // 56-bit encryption support (matching FreeRDP/mstsc)
            NTLMFlags.version

        var msg = Data()
        msg.append(contentsOf: Array("NTLMSSP\0".utf8)) // Signature
        msg.append(le32(1))                              // MessageType = Negotiate
        msg.append(le32(flags))                          // NegotiateFlags

        // MS-NLMP §2.2.1.1: DomainName / Workstation buffers are empty, but
        // BufferOffset MUST be set to the end of the fixed header (not 0).
        // Version field is present because NTLMSSP_NEGOTIATE_VERSION is set → header = 40 B.
        let hdrEnd: UInt32 = 40
        msg.append(Data(repeating: 0, count: 4))  // DomainName len=0, maxLen=0
        msg.append(le32(hdrEnd))                   // DomainName bufferOffset → 40
        msg.append(Data(repeating: 0, count: 4))  // Workstation len=0, maxLen=0
        msg.append(le32(hdrEnd))                   // Workstation bufferOffset → 40
        msg.append(ntlmVersion())                  // Version (8 B)
        negotiateMessage = msg                     // save for MIC computation
        return msg
    }

    // MARK: - Step 2: Parse CHALLENGE_MESSAGE

    /// Returns false if the data is not a valid NTLM Challenge.
    @discardableResult
    func parseChallenge(_ data: Data) -> Bool {
        challengeMessage = data                                // save for MIC computation
        guard data.count >= 56 else { return false }
        let sig = data.prefix(8)
        guard sig.elementsEqual("NTLMSSP\0".utf8) else { return false }
        let type = data.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard type == 2 else { return false }

        // Challenge is at offset 24 (8 bytes)
        serverChallenge = data.subdata(in: 24..<32)

        // NegotiateFlags at 20..24
        negotiateFlags = data.subdata(in: 20..<24).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }

        // TargetInfo security buffer at 40..48
        let tiLen    = Int(data.subdata(in: 40..<42).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian })
        let tiOffset = Int(data.subdata(in: 44..<48).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
        if tiLen > 0 && tiOffset + tiLen <= data.count {
            targetInfoBlob = data.subdata(in: tiOffset..<(tiOffset + tiLen))
        }
        return true
    }

    // MARK: - Step 3: AUTHENTICATE_MESSAGE

    func authenticate() -> Data {
        // --- derive NT hash (NTLM hash of UTF-16LE password) ---
        let ntHash = md4Hash(utf16LE(password))

        // --- client challenge (8 bytes) ---
        let clientChallenge = randomBytes(8)

        // --- NTProofStr (HMAC-MD5 of concatenated blob) ---
        // Per MS-NLMP §3.3.2: use server's MsvAvTimestamp if present, else current time
        let blobTimestamp = extractAvTimestamp(from: targetInfoBlob) ?? windowsTimestamp()
        // DIAGNOSTIC: use original TargetInfo (no MsvAvFlags=0x02) so server
        // won't verify MIC.  This isolates whether basic NTLMv2 auth works.
        let blob = buildNTLMv2Blob(clientChallenge: clientChallenge,
                                    targetInfo: targetInfoBlob,
                                    timestamp: blobTimestamp)

        let responseKey = hmacMD5(key: ntHash,
                                  data: utf16LE(username.uppercased()) + utf16LE(domain))
        let ntProofStr   = hmacMD5(key: responseKey,
                                   data: serverChallenge + blob)
        let ntResponse   = ntProofStr + blob

        // --- Session key ---
        let keyExchangeKey = hmacMD5(key: responseKey, data: ntProofStr)
        let randomKey      = randomBytes(16)                // ExportedSessionKey
        let encRandKey     = rc4(key: keyExchangeKey, data: randomKey)

        sessionKey                  = randomKey
        encryptedRandomSessionKey   = encRandKey
        sendSignKey = md5Hash(randomKey + Data("session key to client-to-server signing key magic constant\0".utf8))
        recvSignKey = md5Hash(randomKey + Data("session key to server-to-client signing key magic constant\0".utf8))
        sendSealKey = md5Hash(randomKey + Data("session key to client-to-server sealing key magic constant\0".utf8))
        recvSealKey = md5Hash(randomKey + Data("session key to server-to-client sealing key magic constant\0".utf8))
        sendSealHandle = RC4Handle(key: sendSealKey!)
        recvSealHandle = RC4Handle(key: recvSealKey!)

        // --- Build AUTHENTICATE_MESSAGE ---
        let domainData       = utf16LE(domain)
        let userNameData     = utf16LE(username)
        let workstationData  = utf16LE(workstation)
        let lmResponse       = Data(count: 24)              // LMv2 – omit for NTLMv2
        // For NLA/CredSSP, EncryptedRandomSessionKey is included
        let encSessKeyData   = encRandKey

        // Fixed-size header is 88 bytes:
        //   8 (signature) + 4 (type) + 6×8 (security buffer headers) + 4 (flags) + 8 (version) + 16 (MIC)
        let fixedSize = 88
        var payloadOffset = fixedSize

        func mkBuf(_ d: Data) -> (header: Data, payload: Data) {
            securityBuffer(data: d, baseOffset: 0, currentPayloadOffset: payloadOffset)
        }

        let lmBuf    = mkBuf(lmResponse);      payloadOffset += lmResponse.count
        let ntBuf    = mkBuf(ntResponse);      payloadOffset += ntResponse.count
        let domBuf   = mkBuf(domainData);      payloadOffset += domainData.count
        let userBuf  = mkBuf(userNameData);    payloadOffset += userNameData.count
        let wksBuf   = mkBuf(workstationData); payloadOffset += workstationData.count
        let skBuf    = mkBuf(encSessKeyData);  // last

        let authFlags: UInt32 = negotiateFlags != 0 ? negotiateFlags :
            (NTLMFlags.unicode | NTLMFlags.ntlm | NTLMFlags.extendedSec |
             NTLMFlags.keyExchange | NTLMFlags.sign | NTLMFlags.seal)

        var msg = Data()
        msg.append(contentsOf: Array("NTLMSSP\0".utf8))
        msg.append(le32(3))                // MessageType = Authenticate
        msg.append(lmBuf.header)
        msg.append(ntBuf.header)
        msg.append(domBuf.header)
        msg.append(userBuf.header)
        msg.append(wksBuf.header)
        msg.append(skBuf.header)
        msg.append(le32(authFlags))
        msg.append(ntlmVersion())

        // NTLMv2: append MIC (16-byte HMAC-MD5 over all three messages).
        // We leave it zeroed; compute + fill in after assembly (RFC 4178 §2.2).
        let micOffset = msg.count
        msg.append(Data(count: 16))

        // Payload
        msg.append(lmBuf.payload)
        msg.append(ntBuf.payload)
        msg.append(domBuf.payload)
        msg.append(userBuf.payload)
        msg.append(wksBuf.payload)
        msg.append(skBuf.payload)

        // --- MIC computation DISABLED (diagnostic) ---
        // With no MsvAvFlags=0x02 in TargetInfo, server ignores MIC field.
        // Leave 16 zero bytes so we can test if basic NTLMv2 auth passes.
        let mic = Data(count: 16)
        // let mic = hmacMD5(key: randomKey, data: negotiateMessage + challengeMessage + msg)
        // msg.replaceSubrange(micOffset ..< (micOffset + 16), with: mic)

        // Build diagnostic string for caller to log (print() goes to Xcode console which user may not see)
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined(separator: " ") }
        var diag = [String]()
        diag.append("NTLM negotiate=\(negotiateMessage.count)B challenge=\(challengeMessage.count)B auth=\(msg.count)B")
        diag.append("NTLM flags: challenge=0x\(String(negotiateFlags, radix: 16)) auth=0x\(String(authFlags, radix: 16))")
        diag.append("NTLM KEY_EXCH=\((authFlags & 0x40000000) != 0) SIGN=\((authFlags & 0x10) != 0) SEAL=\((authFlags & 0x20) != 0) ESS=\((authFlags & 0x80000) != 0)")
        diag.append("NTLM MIC[\(micOffset)]: \(hex(mic))")
        diag.append("NTLM ExportedSessionKey: \(hex(randomKey))")
        diag.append("NTLM SessionBaseKey: \(hex(keyExchangeKey))")
        diag.append("NTLM sendSignKey: \(hex(sendSignKey!))")
        diag.append("NTLM sendSealKey: \(hex(sendSealKey!))")
        diag.append("NTLM NTProofStr: \(hex(ntProofStr))")
        diag.append("NTLM auth header[88]: \(hex(msg.prefix(88)))")
        diag.append("NTLM negotiate hex: \(hex(negotiateMessage))")
        diag.append("NTLM challenge prefix[32]: \(hex(challengeMessage.prefix(32)))")
        diagnosticInfo = diag.joined(separator: "\n")

        return msg
    }

    // MARK: - Private helpers

    private func ntlmVersion() -> Data {
        // Windows 10 version (Product: 10.0, NTLM revision 15)
        var v = Data()
        v.append(contentsOf: [UInt8(10), UInt8(0)])  // major, minor
        v.append(le16(19041))                         // Build 10.0.19041
        v.append(Data(repeating: 0, count: 3))        // reserved
        v.append(15)                                  // NTLM revision = 15
        return v
    }

    private func windowsTimestamp() -> Data {
        // Windows FILETIME: 100-ns intervals since 1601-01-01
        let unixEpochOffset: UInt64 = 116_444_736_000_000_000
        let now = UInt64(Date().timeIntervalSince1970 * 10_000_000) + unixEpochOffset
        return Data(withUnsafeBytes(of: now.littleEndian) { Array($0) })
    }

    private func augmentedTargetInfo() -> Data {
        // Parse the server's TargetInfo AV_PAIR list properly:
        //   - Copy all pairs EXCEPT MsvAvEOL (id=0) and MsvAvFlags (id=6)
        //   - Add MsvAvFlags = 0x02 (MIC provided) — we compute a real MIC
        //   - Re-add MsvAvEOL terminator at the end
        var pairs = Data()
        var idx = targetInfoBlob.startIndex

        while idx + 4 <= targetInfoBlob.endIndex {
            let avId  = UInt16(targetInfoBlob[idx]) | (UInt16(targetInfoBlob[idx + 1]) << 8)
            let avLen = Int(UInt16(targetInfoBlob[idx + 2]) | (UInt16(targetInfoBlob[idx + 3]) << 8))
            guard idx + 4 + avLen <= targetInfoBlob.endIndex else { break }

            if avId == 0 { break }          // MsvAvEOL — stop parsing

            if avId == 6 {                  // MsvAvFlags — skip server's version
                idx += 4 + avLen
                continue
            }

            // Copy this AV_PAIR unchanged
            pairs.append(targetInfoBlob.subdata(in: idx ..< (idx + 4 + avLen)))
            idx += 4 + avLen
        }

        // Add MsvAvFlags = 0x02 (MIC provided in AUTHENTICATE)
        pairs.append(le16(6))               // AvId  = MsvAvFlags
        pairs.append(le16(4))               // AvLen = 4
        pairs.append(le32(0x0000_0002))     // Value = MIC_PROVIDED

        // MsvAvEOL terminator
        pairs.append(le16(0))
        pairs.append(le16(0))
        return pairs
    }

    private func buildNTLMv2Blob(clientChallenge: Data,
                                  targetInfo: Data,
                                  timestamp: Data) -> Data {
        var blob = Data()
        blob.append(contentsOf: [0x01, 0x01, 0x00, 0x00]) // RespType / HiRespType
        blob.append(Data(repeating: 0, count: 4))          // Reserved
        blob.append(timestamp)                             // TimeStamp
        blob.append(clientChallenge)                       // ChallengeFromClient
        blob.append(Data(repeating: 0, count: 4))          // Reserved
        blob.append(targetInfo)                            // TargetInfoFields
        blob.append(Data(repeating: 0, count: 4))          // Reserved
        return blob
    }

    /// Extract MsvAvTimestamp (AvId=7) from a TargetInfo AV_PAIR list.
    private func extractAvTimestamp(from ti: Data) -> Data? {
        var idx = ti.startIndex
        while idx + 4 <= ti.endIndex {
            let avId  = UInt16(ti[idx]) | (UInt16(ti[idx + 1]) << 8)
            let avLen = Int(UInt16(ti[idx + 2]) | (UInt16(ti[idx + 3]) << 8))
            guard idx + 4 + avLen <= ti.endIndex else { break }
            if avId == 0 { break }           // MsvAvEOL
            if avId == 7 && avLen == 8 {     // MsvAvTimestamp
                return ti.subdata(in: (idx + 4) ..< (idx + 4 + 8))
            }
            idx += 4 + avLen
        }
        return nil
    }
}

// MARK: - Stateful RC4 cipher for NTLM sealing

private final class RC4Handle {
    private var s = [UInt8](repeating: 0, count: 256)
    private var i: Int = 0
    private var j: Int = 0

    init(key: Data) {
        for n in 0..<256 { s[n] = UInt8(n) }
        var jj = 0
        for n in 0..<256 {
            jj = (jj + Int(s[n]) + Int(key[n % key.count])) & 0xFF
            s.swapAt(n, jj)
        }
    }

    func process(_ data: Data) -> Data {
        var out = Data(count: data.count)
        for k in 0..<data.count {
            i = (i + 1) & 0xFF
            j = (j + Int(s[i])) & 0xFF
            s.swapAt(i, j)
            out[k] = data[k] ^ s[(Int(s[i]) + Int(s[j])) & 0xFF]
        }
        return out
    }
}

// swiftlint:enable function_body_length
