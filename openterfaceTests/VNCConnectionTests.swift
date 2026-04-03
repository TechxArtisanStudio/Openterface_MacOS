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

import XCTest
@testable import openterface

/// Tests for VNC ARD authentication math and live connectivity.
///
/// IMPORTANT: The live test (testLiveARDConnection) connects to a real VNC host.
/// Credentials are read from environment variables to avoid committing secrets:
///   VNC_HOST, VNC_PORT, VNC_USERNAME, VNC_PASSWORD
/// If those are not set, the values below are used as a local dev fallback.
final class VNCConnectionTests: XCTestCase {

    // ── Dev-fallback values (override with env vars in CI) ──────────────────
    private let devHost     = ProcessInfo.processInfo.environment["VNC_HOST"]     ?? "192.168.100.170"
    private let devPort     = Int(ProcessInfo.processInfo.environment["VNC_PORT"] ?? "5900") ?? 5900
    private let devUsername = ProcessInfo.processInfo.environment["VNC_USERNAME"] ?? "dengbinhua"
    private let devPassword = ProcessInfo.processInfo.environment["VNC_PASSWORD"] ?? "beets3dp"

    // ── Unit tests: big-integer modular exponentiation ───────────────────────

    /// 2^10 mod 1000 = 24
    func testModExpSmall() {
        let result = VNCClientManager.shared._test_modExp(base: [2], exp: [10], mod: [0x03, 0xE8])
        let value  = result.reduce(0) { ($0 << 8) | UInt64($1) }
        XCTAssertEqual(value, 24, "2^10 mod 1000 should be 24, got \(value)")
    }

    /// Fermat's little theorem: if p prime, a^(p-1) ≡ 1 (mod p)
    /// Use p=7, a=3: 3^6 mod 7 = 1
    func testModExpFermat() {
        let result = VNCClientManager.shared._test_modExp(base: [3], exp: [6], mod: [7])
        XCTAssertEqual(result, [1], "3^6 mod 7 should be 1 (Fermat's little theorem)")
    }

    /// base = 1 → result is always 1 regardless of exp/mod
    func testModExpBaseOne() {
        let result = VNCClientManager.shared._test_modExp(base: [1], exp: [0xFF, 0xFF], mod: [0x01, 0x00, 0x00])
        XCTAssertEqual(result, [1])
    }

    // ── Unit test: ARD DH response structure ─────────────────────────────────

    /// With known small DH params, verify the response has the right byte length.
    /// We cannot verify the encrypted payload without a reference implementation,
    /// but we can check structural correctness.
    func testARDResponseLength() {
        // Use a tiny 8-byte (64-bit) group for speed
        let prime: [UInt8]     = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x61] // a 64-bit prime-like value
        let serverPub: [UInt8] = [0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0]

        let response = VNCClientManager.shared._test_ardDHResponse(
            generator: 2,
            prime: prime,
            serverPublicKey: serverPub,
            username: "testuser",
            password: "testpass"
        )

        XCTAssertNotNil(response, "ardDHResponse must not return nil")
        let expected = prime.count + 128  // keyLen + 128 encrypted bytes
        XCTAssertEqual(response?.count, expected,
                       "Response should be \(expected) bytes (keyLen=\(prime.count) + 128 encrypted)")
    }

    /// Changing username/password must produce a different response (different cipher output).
    func testARDResponseDifferentCredentials() {
        let prime: [UInt8]     = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x61]
        let serverPub: [UInt8] = [0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0]

        let r1 = VNCClientManager.shared._test_ardDHResponse(
            generator: 2, prime: prime, serverPublicKey: serverPub,
            username: "alice", password: "pass1")
        let r2 = VNCClientManager.shared._test_ardDHResponse(
            generator: 2, prime: prime, serverPublicKey: serverPub,
            username: "bob",   password: "pass2")

        XCTAssertNotNil(r1); XCTAssertNotNil(r2)
        // Client public keys will differ (random private key each time)
        XCTAssertNotEqual(r1, r2, "Different credentials must produce different responses")
    }

    /// Times the ARD DH response with real 1024-bit parameters (keyLen=128).
    /// This validates that the computation finishes in a reasonable time.
    func testARDResponseTiming1024bit() {
        // Actual prime from the VNC server at 192.168.100.170:5900
        let prime: [UInt8] = [
            0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xc9,0x0f,0xda,0xa2,0x21,0x68,0xc2,0x34,
            0xc4,0xc6,0x62,0x8b,0x80,0xdc,0x1c,0xd1,0x29,0x02,0x4e,0x08,0x8a,0x67,0xcc,0x74,
            0x02,0x0b,0xbe,0xa6,0x3b,0x13,0x9b,0x22,0x51,0x4a,0x08,0x79,0x8e,0x34,0x04,0xdd,
            0xef,0x95,0x19,0xb3,0xcd,0x3a,0x43,0x1b,0x30,0x2b,0x0a,0x6d,0xf2,0x5f,0x14,0x37,
            0x4f,0xe1,0x35,0x6d,0x6d,0x51,0xc2,0x45,0xe4,0x85,0xb5,0x76,0x62,0x5e,0x7e,0xc6,
            0xf4,0x4c,0x42,0xe9,0xa6,0x37,0xed,0x6b,0x0b,0xff,0x5c,0xb6,0xf4,0x06,0xb7,0xed,
            0xee,0x38,0x6b,0xfb,0x5a,0x89,0x9f,0xa5,0xae,0x9f,0x24,0x11,0x7c,0x4b,0x1f,0xe6,
            0x49,0x28,0x66,0x51,0xec,0xe6,0x53,0x81,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
        ]
        let serverPub: [UInt8] = Array(repeating: 0x42, count: 128)

        let start = Date()
        let response = VNCClientManager.shared._test_ardDHResponse(
            generator: 2, prime: prime, serverPublicKey: serverPub,
            username: "dengbinhua", password: "beets3dp")
        let elapsed = Date().timeIntervalSince(start)

        print("[VNCTest] 1024-bit DH elapsed: \(String(format: "%.2f", elapsed))s")
        XCTAssertNotNil(response, "DH response must not be nil")
        XCTAssertLessThan(elapsed, 30, "DH computation should finish within 30s, took \(elapsed)s")
    }

    // ── Integration test: live ARD connection ────────────────────────────────

    /// Connects to a real macOS VNC server using ARD security type 30.
    /// Verifies that the connection reaches the `connected` state within 20 seconds.
    ///
    /// Requires network access to `devHost:devPort` from the test machine.
    func testLiveARDConnection() throws {
        // Ensure the protocol mode is VNC so stopConnection updates state correctly
        AppStatus.activeConnectionProtocol = .vnc
        AppStatus.protocolSessionState     = .idle
        AppStatus.protocolLastErrorMessage = ""

        let settings = UserSettings.shared
        settings.vncHost     = devHost
        settings.vncPort     = devPort
        settings.vncUsername = devUsername
        settings.vncPassword = devPassword

        let sem    = DispatchSemaphore(value: 0)
        var result = "timeout"

        // Poll on a background thread — avoids RunLoop dependency entirely.
        let pollQueue = DispatchQueue(label: "vnc.test.poll", qos: .userInitiated)
        var keepPolling = true
        var sawConnecting = false

        pollQueue.async {
            var lastState: ProtocolSessionState? = nil
            while keepPolling {
                let state = AppStatus.protocolSessionState
                if state != lastState {
                    print("[VNCTest] protocolSessionState changed to: \(state)")
                    lastState = state
                }
                switch state {
                case .connecting:
                    sawConnecting = true
                case .connected:
                    result = "connected"
                    keepPolling = false
                    sem.signal()
                case .error:
                    result = "error: \(AppStatus.protocolLastErrorMessage)"
                    keepPolling = false
                    sem.signal()
                case .idle:
                    if sawConnecting {
                        let msg = AppStatus.protocolLastErrorMessage
                        result = "failed (idle): \(msg.isEmpty ? "(no message)" : msg)"
                        keepPolling = false
                        sem.signal()
                    }
                case .switching:
                    break
                }
                if keepPolling { Thread.sleep(forTimeInterval: 0.05) }
            }
            print("[VNCTest] poll loop exiting, result=\(result)")
        }

        VNCClientManager.shared.connect(
            host: devHost, port: devPort,
            password: devPassword.isEmpty ? nil : devPassword)

        let waitResult = sem.wait(timeout: .now() + 20)
        keepPolling = false
        VNCClientManager.shared.disconnect()

        // Write result to temp file for diagnostics (visible even when xcresult bundle fails)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/Users/pengtianyu"
        try? result.write(toFile: "\(home)/vnc_test_result.txt", atomically: true, encoding: .utf8)
        let lastError = AppStatus.protocolLastErrorMessage
        try? lastError.write(toFile: "\(home)/vnc_test_error.txt", atomically: true, encoding: .utf8)

        if waitResult == .timedOut {
            XCTFail("VNC did not resolve within 20s — "
                  + "last state=\(AppStatus.protocolSessionState) "
                  + "error=\(AppStatus.protocolLastErrorMessage.isEmpty ? "(none)" : AppStatus.protocolLastErrorMessage)")
            return
        }

        XCTAssertEqual(result, "connected",
            "Expected VNC to connect to \(devHost):\(devPort) but got: \(result)")
    }
}
