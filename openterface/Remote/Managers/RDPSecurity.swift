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
import Security

// MARK: - RDP Standard Security: Key Derivation (MS-RDPBCGR §5.3.5)

/// SaltedHash(S, I, clientRandom, serverRandom) = MD5(S | SHA1(I | S | clientRandom | serverRandom))
func rdpSaltedHash(_ keyMaterial: [UInt8], _ pad: [UInt8],
                   _ clientRandom: [UInt8], _ serverRandom: [UInt8]) -> [UInt8] {
    var shaIn = pad + keyMaterial + clientRandom + serverRandom
    var shaOut = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    shaIn.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(shaIn.count), &shaOut) }

    var md5In = keyMaterial + shaOut
    var md5Out = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    md5In.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(md5In.count), &md5Out) }
    return md5Out
}

/// Derive 128-bit RDP session keys from the 32-byte client and server randoms.
/// Returns (macKey 16B, clientEncKey 16B, serverEncKey 16B).
func rdpDeriveSessionKeys(clientRandom: [UInt8],
                          serverRandom: [UInt8]) -> (macKey: [UInt8], clientEncKey: [UInt8], serverEncKey: [UInt8]) {
    // PreMasterSecret = first 24 bytes of each random
    let pms = Array(clientRandom.prefix(24)) + Array(serverRandom.prefix(24))

    let ms = rdpSaltedHash(pms, [0x41],             clientRandom, serverRandom)   // "A"
           + rdpSaltedHash(pms, [0x42, 0x42],       clientRandom, serverRandom)   // "BB"
           + rdpSaltedHash(pms, [0x43, 0x43, 0x43], clientRandom, serverRandom)   // "CCC"

    let skb = rdpSaltedHash(ms, [0x58],             clientRandom, serverRandom)   // "X"
            + rdpSaltedHash(ms, [0x59, 0x59],       clientRandom, serverRandom)   // "YY"
            + rdpSaltedHash(ms, [0x5A, 0x5A, 0x5A], clientRandom, serverRandom)   // "ZZZ"

    return (Array(skb[0..<16]), Array(skb[16..<32]), Array(skb[32..<48]))
}

// MARK: - RC4 Streaming Cipher

/// Stateful RC4 context used for RDP traffic encryption/decryption.
final class RDPrc4 {
    private var s: [UInt8]
    private var i: Int = 0
    private var j: Int = 0

    init(key: [UInt8]) {
        s = Array(0...255)
        var j = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(key[i % key.count])) & 0xFF
            s.swapAt(i, j)
        }
    }

    func crypt(_ input: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: input.count)
        for k in 0..<input.count {
            i = (i + 1) & 0xFF
            j = (j + Int(s[i])) & 0xFF
            s.swapAt(i, j)
            out[k] = input[k] ^ s[(Int(s[i]) + Int(s[j])) & 0xFF]
        }
        return out
    }
}

// MARK: - RDP MAC Signature (MS-RDPBCGR §5.3.6.1, non-FIPS)

/// Compute an 8-byte MAC over `data` using `macKey` (non-FIPS MAC-MD5).
func rdpMACSignature(macKey: [UInt8], data: [UInt8]) -> [UInt8] {
    let pad1 = [UInt8](repeating: 0x36, count: 40)
    let pad2 = [UInt8](repeating: 0x5C, count: 48)

    let len = UInt32(data.count)
    let dataLen: [UInt8] = [
        UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF),
        UInt8((len >> 16) & 0xFF), UInt8((len >> 24) & 0xFF)
    ]

    var sha1In = macKey + pad1 + dataLen + data
    var sha1Out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    sha1In.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(sha1In.count), &sha1Out) }

    var md5In = macKey + pad2 + sha1Out
    var md5Out = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    md5In.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(md5In.count), &md5Out) }

    return Array(md5Out.prefix(8))
}

// MARK: - RSA PKCS#1 v1.5 Encryption (for RDP client random exchange)

/// Encrypt `message` with the RDP server's RSA public key (big-endian modulus + exponent)
/// using PKCS#1 v1.5 padding.  The modulus byte-order in RDP proprietary certificates is
/// **little-endian**; callers must reverse it before passing it here.
func rdpRSAEncrypt(_ message: [UInt8], modulus: [UInt8], exponent: [UInt8]) -> [UInt8]? {
    let modLen = modulus.count
    guard message.count <= modLen - 11 else { return nil }

    // PKCS#1 v1.5 encryption block: 0x00 | 0x02 | PS (≥8 non-zero random bytes) | 0x00 | M
    let psLen = modLen - message.count - 3
    var em = [UInt8](repeating: 0, count: modLen)
    em[0] = 0x00
    em[1] = 0x02

    var offset = 2
    while offset < 2 + psLen {
        var byte: UInt8 = 0
        repeat {
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else {
                return nil
            }
        } while byte == 0
        em[offset] = byte
        offset += 1
    }
    em[2 + psLen] = 0x00
    for (idx, b) in message.enumerated() {
        em[3 + psLen + idx] = b
    }

    // c = em^e mod n  (RSA encryption)
    let cBytes = rdpBigModExp(base: em, exp: exponent, mod: modulus)

    // Left-pad result to modLen
    var result = [UInt8](repeating: 0, count: modLen)
    let copyLen = min(cBytes.count, modLen)
    result[(modLen - copyLen)...] = cBytes[(cBytes.count - copyLen)...][...]
    return result
}

// MARK: - Big-integer modular exponentiation (big-endian [UInt8], UInt64-word arithmetic)

func rdpBigModExp(base: [UInt8], exp: [UInt8], mod: [UInt8]) -> [UInt8] {
    let m = rdp8to64(rdpTrim(mod))
    guard m != [0] else { return [] }
    var r: [UInt64] = [1]
    let b = rdp64Mod(rdp8to64(rdpTrim(base)), m)
    for byte in rdpTrim(exp) {
        for bit in stride(from: 7, through: 0, by: -1) {
            r = rdp64Mod(rdp64Mul(r, r), m)
            if (byte >> bit) & 1 == 1 {
                r = rdp64Mod(rdp64Mul(r, b), m)
            }
        }
    }
    return rdp64to8(r)
}

// MARK: - UInt64-word big-integer internals

private func rdpTrim(_ a: [UInt8]) -> [UInt8] {
    var i = 0
    while i < a.count - 1 && a[i] == 0 { i += 1 }
    return Array(a[i...])
}

private func rdp8to64(_ b: [UInt8]) -> [UInt64] {
    var a = b
    let rem = a.count % 8
    if rem != 0 { a = [UInt8](repeating: 0, count: 8 - rem) + a }
    return stride(from: 0, to: a.count, by: 8).map { i -> UInt64 in
        let hi = UInt64(a[i]) << 56 | UInt64(a[i+1]) << 48 | UInt64(a[i+2]) << 40 | UInt64(a[i+3]) << 32
        let lo = UInt64(a[i+4]) << 24 | UInt64(a[i+5]) << 16 | UInt64(a[i+6]) << 8  | UInt64(a[i+7])
        return hi | lo
    }
}

private func rdp64to8(_ w: [UInt64]) -> [UInt8] {
    var bytes = w.flatMap { [
        UInt8($0 >> 56), UInt8($0 >> 48 & 0xFF), UInt8($0 >> 40 & 0xFF), UInt8($0 >> 32 & 0xFF),
        UInt8($0 >> 24 & 0xFF), UInt8($0 >> 16 & 0xFF), UInt8($0 >> 8 & 0xFF), UInt8($0 & 0xFF)
    ] }
    return rdpTrim(bytes)
}

private func rdp64Trim(_ a: [UInt64]) -> [UInt64] {
    var i = 0
    while i < a.count - 1 && a[i] == 0 { i += 1 }
    return Array(a[i...])
}

private func rdp64Mul(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
    let a = rdp64Trim(a), b = rdp64Trim(b)
    var r = [UInt64](repeating: 0, count: a.count + b.count)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
        var carry: UInt64 = 0
        for j in stride(from: b.count - 1, through: 0, by: -1) {
            let (hi, lo) = a[i].multipliedFullWidth(by: b[j])
            let (s1, ov1) = r[i + j + 1].addingReportingOverflow(lo)
            let (s2, ov2) = s1.addingReportingOverflow(carry)
            r[i + j + 1] = s2
            carry = hi &+ (ov1 ? 1 : 0) &+ (ov2 ? 1 : 0)
        }
        r[i] = r[i] &+ carry
    }
    return rdp64Trim(r)
}

private func rdp64Mod(_ a: [UInt64], _ n: [UInt64]) -> [UInt64] {
    guard rdp64Compare(a, n) >= 0 else { return a }
    var r = a
    var shift = 0
    var d = n
    while rdp64Compare(rdp64Shift(d, 1), r) <= 0 { d = rdp64Shift(d, 1); shift += 1 }
    while shift >= 0 {
        if rdp64Compare(r, d) >= 0 { r = rdp64Sub(r, d) }
        d = rdp64Shift(d, -1)
        shift -= 1
    }
    return rdp64Trim(r)
}

private func rdp64Compare(_ a: [UInt64], _ b: [UInt64]) -> Int {
    let a = rdp64Trim(a), b = rdp64Trim(b)
    if a.count != b.count { return a.count < b.count ? -1 : 1 }
    for i in 0..<a.count {
        if a[i] < b[i] { return -1 }
        if a[i] > b[i] { return 1 }
    }
    return 0
}

private func rdp64Sub(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
    var r = a
    var carry: UInt64 = 0
    let bPadded = [UInt64](repeating: 0, count: max(0, a.count - b.count)) + b
    for i in stride(from: r.count - 1, through: 0, by: -1) {
        let bv: UInt64 = i < bPadded.count ? bPadded[i] : 0
        let (s1, ov1) = r[i].subtractingReportingOverflow(bv)
        let (s2, ov2) = s1.subtractingReportingOverflow(carry)
        r[i] = s2
        carry = (ov1 || ov2) ? 1 : 0
    }
    return rdp64Trim(r)
}

private func rdp64Shift(_ a: [UInt64], _ n: Int) -> [UInt64] {
    if n == 0 { return a }
    if n > 0 {
        var r = a + [UInt64](repeating: 0, count: n)
        return rdp64Trim(r)
    }
    guard a.count > -n else { return [0] }
    return rdp64Trim(Array(a.dropLast(-n)))
}
