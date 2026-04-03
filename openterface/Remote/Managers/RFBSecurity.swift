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
*    along with this program. If not, see <http://www.gnu.org/licenses/>.    *
*                                                                            *
* ========================================================================== *
*/

import Foundation
import CommonCrypto
import CryptoKit
import Security

// MARK: - RFB Security: VNC Authentication (type 2, DES)

/// VNCAuth challenge–response: encrypts the 16-byte server challenge with DES
/// using the VNC password. VNC reverses the bit order of each password byte
/// before using it as the DES key (RFC 6143 §7.2.2).
func rfbDesResponse(challenge: Data, password: String) -> Data? {
    var keyBytes = [UInt8](repeating: 0, count: 8)
    let pwBytes = Array(password.utf8.prefix(8))
    for i in 0..<pwBytes.count { keyBytes[i] = pwBytes[i] }

    // Bit-reverse each key byte (VNC-specific DES encoding)
    for i in 0..<8 {
        var b = keyBytes[i]
        b = (b & 0xF0) >> 4 | (b & 0x0F) << 4
        b = (b & 0xCC) >> 2 | (b & 0x33) << 2
        b = (b & 0xAA) >> 1 | (b & 0x55) << 1
        keyBytes[i] = b
    }

    let challengeBytes = Array(challenge)

    func encryptBlock(_ block: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: 8)
        var outLen = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            block.withUnsafeBytes { inPtr in
                keyBytes.withUnsafeBytes { keyPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmDES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, kCCKeySizeDES,
                        nil,
                        inPtr.baseAddress, 8,
                        outPtr.baseAddress, 8,
                        &outLen
                    )
                }
            }
        }
        return status == kCCSuccess ? out : nil
    }

    guard let b1 = encryptBlock(Array(challengeBytes[0..<8])),
          let b2 = encryptBlock(Array(challengeBytes[8..<16])) else { return nil }

    var result = Data(count: 16)
    result.replaceSubrange(0..<8,  with: b1)
    result.replaceSubrange(8..<16, with: b2)
    return result
}

// MARK: - RFB Security: Apple ARD Authentication (type 30, DH + AES-128-ECB)

/// Compute Apple ARD type-30 response:
///   clientPubKey = gen^priv mod prime
///   sharedSecret = serverPub^priv mod prime
///   aesKey       = MD5(sharedSecret padded to keyLen)
///   encrypted    = AES-128-ECB(username[64] | password[64], aesKey)
///   response     = clientPubKey(keyLen) | encrypted(128)
func rfbARDResponse(generator: UInt16, prime: [UInt8], serverPublicKey: [UInt8],
                    username: String, password: String) -> Data? {
    let keyLen = prime.count
    // Generator as big-endian byte array (strip leading zero if present)
    let genBytes: [UInt8] = generator > 0xFF
        ? [UInt8(generator >> 8), UInt8(generator & 0xFF)]
        : [UInt8(generator & 0xFF)]

    // Random private key – clear MSB so value < prime
    var privateKey = [UInt8](repeating: 0, count: keyLen)
    guard SecRandomCopyBytes(kSecRandomDefault, keyLen, &privateKey) == errSecSuccess else { return nil }
    privateKey[0] &= 0x7F

    let clientPub = ardModExp(base: genBytes,        exp: privateKey, mod: prime)
    let sharedRaw = ardModExp(base: serverPublicKey, exp: privateKey, mod: prime)

    // Pad shared secret to keyLen (big-endian, zero-padded on left)
    var sharedPadded = [UInt8](repeating: 0, count: keyLen)
    let copyLen = min(sharedRaw.count, keyLen)
    sharedPadded.replaceSubrange((keyLen - copyLen)..., with: sharedRaw.suffix(copyLen))

    // AES key = MD5(padded shared secret)
    let md5Digest = Insecure.MD5.hash(data: Data(sharedPadded))
    var aesKey = Array(md5Digest)  // 16 bytes

    // Plaintext: username null-padded to 64 bytes | password null-padded to 64 bytes
    var plaintext = [UInt8](repeating: 0, count: 128)
    Array(username.utf8.prefix(63)).enumerated().forEach { plaintext[$0.offset] = $0.element }
    Array(password.utf8.prefix(63)).enumerated().forEach { plaintext[64 + $0.offset] = $0.element }

    // AES-128-ECB encrypt (128 bytes input → 128 bytes output, exact multiple of block size)
    var encrypted = [UInt8](repeating: 0, count: 128 + kCCBlockSizeAES128)
    var encLen = 0
    let status = CCCrypt(
        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
        &aesKey, kCCKeySizeAES128, nil,
        &plaintext, 128, &encrypted, encrypted.count, &encLen)
    guard status == kCCSuccess else { return nil }

    // Pad client pub key to keyLen
    var clientPubPadded = [UInt8](repeating: 0, count: keyLen)
    let pubCopy = min(clientPub.count, keyLen)
    clientPubPadded.replaceSubrange((keyLen - pubCopy)..., with: clientPub.suffix(pubCopy))

    // Match TigerVNC/macOS ARD ordering for secType 30:
    // encrypted credentials first, then client DH public key.
    var response = Array(encrypted.prefix(128))
    response.append(contentsOf: clientPubPadded)
    return Data(response)
}

// MARK: - Big integer arithmetic (big-endian [UInt8]) for ARD DH
//
// Uses UInt64 word arithmetic internally for ~30-60× speedup over byte-by-byte.

/// Modular exponentiation: base^exp mod m (all big-endian [UInt8]).
func ardModExp(base: [UInt8], exp: [UInt8], mod: [UInt8]) -> [UInt8] {
    let m = ard8to64(ardTrim(mod))
    var r: [UInt64] = [1]
    let b = ard64Mod(ard8to64(ardTrim(base)), m)
    for byte in ardTrim(exp) {
        for bit in stride(from: 7, through: 0, by: -1) {
            r = ard64Mod(ard64Mul(r, r), m)
            if (byte >> bit) & 1 == 1 {
                r = ard64Mod(ard64Mul(r, b), m)
            }
        }
    }
    return ard64to8(r)
}

// MARK: - UInt64-word helpers (big-endian, MSW first)

private func ardTrim(_ a: [UInt8]) -> [UInt8] {
    var i = 0
    while i < a.count - 1 && a[i] == 0 { i += 1 }
    return Array(a[i...])
}

/// [UInt8] big-endian → [UInt64] big-endian, zero-padded to a multiple of 8 bytes.
private func ard8to64(_ b: [UInt8]) -> [UInt64] {
    var a = b
    let rem = a.count % 8; if rem != 0 { a = [UInt8](repeating: 0, count: 8 - rem) + a }
    return stride(from: 0, to: a.count, by: 8).map { i -> UInt64 in
        let hi = UInt64(a[i])<<56 | UInt64(a[i+1])<<48 | UInt64(a[i+2])<<40 | UInt64(a[i+3])<<32
        let lo = UInt64(a[i+4])<<24 | UInt64(a[i+5])<<16 | UInt64(a[i+6])<<8 | UInt64(a[i+7])
        return hi | lo
    }
}

/// [UInt64] big-endian → [UInt8] big-endian, leading-zero-trimmed, then padded to `padTo` bytes.
private func ard64to8(_ w: [UInt64], padTo: Int = 0) -> [UInt8] {
    var bytes = w.flatMap {[
        UInt8($0>>56), UInt8($0>>48&0xFF), UInt8($0>>40&0xFF), UInt8($0>>32&0xFF),
        UInt8($0>>24&0xFF), UInt8($0>>16&0xFF), UInt8($0>>8&0xFF), UInt8($0&0xFF)
    ]}
    bytes = ardTrim(bytes)
    if padTo > bytes.count { bytes = [UInt8](repeating: 0, count: padTo - bytes.count) + bytes }
    return bytes
}

/// Strip leading zero words.
private func ard64Trim(_ a: [UInt64]) -> [UInt64] {
    var i = 0; while i < a.count - 1 && a[i] == 0 { i += 1 }; return Array(a[i...])
}

/// Multiply two big-endian [UInt64] integers.
private func ard64Mul(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
    let a = ard64Trim(a), b = ard64Trim(b)
    var r = [UInt64](repeating: 0, count: a.count + b.count)
    for i in stride(from: a.count-1, through: 0, by: -1) {
        var carry: UInt64 = 0
        for j in stride(from: b.count-1, through: 0, by: -1) {
            let (hi, lo) = a[i].multipliedFullWidth(by: b[j])
            let (s1, o1) = r[i+j+1].addingReportingOverflow(lo)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            r[i+j+1] = s2
            carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
        }
        r[i] &+= carry
    }
    return ard64Trim(r)
}

/// Bit length of a big-endian [UInt64] integer.
private func ard64BitLen(_ x: [UInt64]) -> Int {
    let t = ard64Trim(x)
    guard !t.isEmpty, t.first != 0 else { return 0 }
    return (t.count - 1) * 64 + (64 - t[0].leadingZeroBitCount)
}

/// Left-shift by n bits in a single O(wordCount) pass.
private func ard64Shl(_ x: [UInt64], _ n: Int) -> [UInt64] {
    guard n > 0 else { return x }
    let ws = n / 64, bs = UInt64(n % 64)
    var r = x + [UInt64](repeating: 0, count: ws)
    if bs > 0 {
        var carry: UInt64 = 0
        for i in stride(from: r.count-1, through: 0, by: -1) {
            let nc = r[i] >> (64 - bs)
            r[i] = (r[i] << bs) | carry
            carry = nc
        }
        if carry > 0 { r.insert(carry, at: 0) }
    }
    return r
}

/// Right-shift by 1 bit, in-place (no allocation).
private func ard64Shr1(_ x: inout [UInt64]) {
    var carry: UInt64 = 0
    for i in 0..<x.count {
        let nc = x[i] & 1
        x[i] = (x[i] >> 1) | (carry << 63)
        carry = nc
    }
}

/// Element-wise compare (both arrays same length, leading zeros OK).
private func ard64CmpPadded(_ a: [UInt64], _ b: [UInt64]) -> Int {
    for (x, y) in zip(a, b) { if x != y { return x < y ? -1 : 1 } }
    return 0
}

/// Subtract b from a in-place (a ≥ b assumed; b may be shorter than a).
private func ard64SubInPlace(_ a: inout [UInt64], _ b: [UInt64]) {
    let offset = a.count - b.count
    var borrow: UInt64 = 0
    for i in stride(from: b.count-1, through: 0, by: -1) {
        let j = i + offset
        let (s1, o1) = a[j].subtractingReportingOverflow(b[i])
        let (s2, o2) = s1.subtractingReportingOverflow(borrow)
        a[j] = s2; borrow = (o1 || o2) ? 1 : 0
    }
    if borrow > 0 {
        for i in stride(from: offset-1, through: 0, by: -1) {
            let (s, o) = a[i].subtractingReportingOverflow(borrow)
            a[i] = s; if !o { break }
        }
    }
}

/// Modular reduction: returns a mod m.
/// Uses binary long-division with in-place subtract/shift to avoid per-iteration allocations.
private func ard64Mod(_ a: [UInt64], _ m: [UInt64]) -> [UInt64] {
    var rem = ard64Trim(a)
    let mod = ard64Trim(m)
    let remBits = ard64BitLen(rem), modBits = ard64BitLen(mod)
    guard remBits >= modBits else { return rem }

    let shiftTotal = remBits - modBits
    var aligned = ard64Shl(mod, shiftTotal)
    while rem.count < aligned.count { rem.insert(0, at: 0) }

    for s in stride(from: shiftTotal, through: 0, by: -1) {
        if ard64CmpPadded(rem, aligned) >= 0 {
            ard64SubInPlace(&rem, aligned)
        }
        if s > 0 { ard64Shr1(&aligned) }
    }
    return ard64Trim(rem)
}
