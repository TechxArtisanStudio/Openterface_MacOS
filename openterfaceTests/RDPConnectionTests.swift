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
import AppKit
import Darwin
@testable import openterface

/// Integration test: connect to a real Windows RDP server, complete CredSSP/NLA,
/// and receive the first desktop frame.
final class RDPConnectionTests: XCTestCase {

    // Captured print() output
    private var stdoutPipe: Pipe!
    private var savedStdout: Int32 = -1
    private var capturedOutput = ""
    private let capturedLock = NSLock()
    private var pipeReaderRunning = false

    override func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
        
        // Redirect stdout to a pipe so we can capture Logger.log() print() calls
        stdoutPipe = Pipe()
        savedStdout = dup(STDOUT_FILENO)
        dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        capturedOutput = ""
        pipeReaderRunning = true
        
        // Continuously read pipe output on background thread
        let pipe = stdoutPipe!
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while self?.pipeReaderRunning == true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break } // EOF
                if let str = String(data: data, encoding: .utf8) {
                    self?.capturedLock.lock()
                    self?.capturedOutput += str
                    self?.capturedLock.unlock()
                }
            }
        }
    }

    override func tearDown() {
        pipeReaderRunning = false
        // Restore stdout first so pipe write end gets no more data
        if savedStdout >= 0 {
            dup2(savedStdout, STDOUT_FILENO)
            close(savedStdout)
            savedStdout = -1
        }
        stdoutPipe?.fileHandleForWriting.closeFile()
        // Drain remaining data
        Thread.sleep(forTimeInterval: 0.05)
        if let data = try? stdoutPipe?.fileHandleForReading.availableData, !data.isEmpty,
           let str = String(data: data, encoding: .utf8) {
            capturedLock.lock()
            capturedOutput += str
            capturedLock.unlock()
        }
        stdoutPipe = nil
        super.tearDown()
    }

    /// Flush and collect all stdout captured so far
    private func flushCapturedOutput() -> String {
        fflush(stdout)
        // Give pipe reader a moment to process
        Thread.sleep(forTimeInterval: 0.2)
        capturedLock.lock()
        let result = capturedOutput
        capturedLock.unlock()
        return result
    }

    // ── Dev-fallback values (override with env vars in CI) ──────────────────
    private let devHost     = ProcessInfo.processInfo.environment["RDP_HOST"]     ?? "192.168.1.121"
    private let devPort     = Int(ProcessInfo.processInfo.environment["RDP_PORT"] ?? "3389") ?? 3389
    private let devUsername = ProcessInfo.processInfo.environment["RDP_USERNAME"] ?? "pc"
    private let devPassword = ProcessInfo.processInfo.environment["RDP_PASSWORD"] ?? "Asdfzxcv88"
    private let devDomain   = ProcessInfo.processInfo.environment["RDP_DOMAIN"]   ?? ""

    private func filteredRDPLogLines(_ logOutput: String, maxLines: Int = 100) -> String {
        logOutput.components(separatedBy: "\n")
            .filter { $0.contains("RDP") || $0.contains("CredSSP") || $0.contains("NTLM") || $0.contains("TLS") }
            .suffix(maxLines)
            .joined(separator: "\n")
    }

    /// Verify CredSSP handshake completes (or at least see what error we get).
    func testRDPCredSSPHandshake() throws {
        AppStatus.activeConnectionProtocol = .rdp
        AppStatus.protocolSessionState     = .idle
        AppStatus.protocolLastErrorMessage = ""
        UserSettings.shared.rdpEnableNLA = true

        let manager = RDPClientManager.shared

        let resolvedExpectation = XCTestExpectation(description: "RDP CredSSP resolved")
        var result = "timeout"
        var keepPolling = true
        var sawConnecting = false
        
        // Watch for errors being set
        let errorExpectation = XCTestExpectation(description: "RDP error set")
        errorExpectation.isInverted = true  // We hope no error

        let pollQueue = DispatchQueue(label: "rdp.test.credssp.poll", qos: .userInitiated)
        pollQueue.async {
            while keepPolling {
                let state = AppStatus.protocolSessionState
                let error = AppStatus.protocolLastErrorMessage
                
                switch state {
                case .connecting:
                    if !sawConnecting {
                        sawConnecting = true
                        NSLog("[RDPTest] SAW connecting")
                    }
                case .connected:
                    result = "connected"
                    NSLog("[RDPTest] CONNECTED!")
                    resolvedExpectation.fulfill()
                    keepPolling = false
                case .error:
                    result = "error: \(error)"
                    NSLog("[RDPTest] ERROR: \(error)")
                    resolvedExpectation.fulfill()
                    keepPolling = false
                case .idle:
                    // Detect idle with error message even if we missed .connecting
                    if sawConnecting || !error.isEmpty {
                        result = "idle-after-connect: \(error.isEmpty ? "(no error msg)" : error)"
                        NSLog("[RDPTest] IDLE after connecting: \(error)")
                        resolvedExpectation.fulfill()
                        keepPolling = false
                    }
                case .switching: break
                }
                if keepPolling { Thread.sleep(forTimeInterval: 0.02) }
            }
        }

        NSLog("[RDPTest] Connecting to \(devHost):\(devPort)")
        manager.connect(host: devHost, port: devPort,
                        username: devUsername, password: devPassword, domain: devDomain)

        // Wait up to 25s — pumps RunLoop so DispatchQueue.main timeouts fire
        let waiterResult = XCTWaiter.wait(for: [resolvedExpectation], timeout: 25.0)
        keepPolling = false

        let stateBeforeDisconnect = AppStatus.protocolSessionState
        let lastError = AppStatus.protocolLastErrorMessage
        
        // Collect all log output
        let logOutput = flushCapturedOutput()
        
        manager.disconnect()
        
        let rdpLines = filteredRDPLogLines(logOutput)

        if waiterResult != .completed {
            XCTFail("""
            TIMEOUT after 25s
            state=\(stateBeforeDisconnect) sawConnecting=\(sawConnecting)
            error=\(lastError.isEmpty ? "(none)" : lastError)
            result=\(result)
            --- LOG (last 100 RDP lines) ---
            \(rdpLines.isEmpty ? "(no RDP log output captured)" : rdpLines)
            """)
            return
        }

        if result.hasPrefix("error") || result.hasPrefix("idle-after-connect") {
            XCTFail("""
            CredSSP FAILED
            result=\(result)
            state=\(stateBeforeDisconnect)
            error=\(lastError.isEmpty ? "(none)" : lastError)
            --- LOG (last 100 RDP lines) ---
            \(rdpLines.isEmpty ? "(no RDP log output captured)" : rdpLines)
            """)
            return
        }

        // If we get here, connected successfully
    }

    /// Verify the session stays connected for a longer period under live Fast-Path traffic.
    /// Configure hold duration with RDP_KEEPALIVE_SECONDS (default 20).
    func testRDPConnectionStaysConnectedForDuration() throws {
        AppStatus.activeConnectionProtocol = .rdp
        AppStatus.protocolSessionState     = .idle
        AppStatus.protocolLastErrorMessage = ""
        UserSettings.shared.rdpEnableNLA = true

        let manager = RDPClientManager.shared
        let env = ProcessInfo.processInfo.environment
        let holdSeconds = max(5.0, Double(env["RDP_KEEPALIVE_SECONDS"] ?? "20") ?? 20.0)
        let resolveExpectation = XCTestExpectation(description: "RDP long-hold resolved")

        var keepPolling = true
        var sawConnecting = false
        var connectedAt: Date?
        var result = "timeout"

        let pollQueue = DispatchQueue(label: "rdp.test.keepalive.poll", qos: .userInitiated)
        pollQueue.async {
            while keepPolling {
                let state = AppStatus.protocolSessionState
                let error = AppStatus.protocolLastErrorMessage

                switch state {
                case .connecting:
                    sawConnecting = true

                case .connected:
                    if connectedAt == nil {
                        connectedAt = Date()
                        NSLog("[RDPTest] CONNECTED (keepalive), hold=%.1fs", holdSeconds)
                    }

                    if let started = connectedAt,
                       Date().timeIntervalSince(started) >= holdSeconds {
                        result = "hold-ok"
                        resolveExpectation.fulfill()
                        keepPolling = false
                    }

                case .error:
                    if connectedAt != nil {
                        result = "disconnected-during-hold: \(error)"
                    } else {
                        result = "error-before-connected: \(error)"
                    }
                    resolveExpectation.fulfill()
                    keepPolling = false

                case .idle:
                    if connectedAt != nil {
                        result = "idle-during-hold: \(error.isEmpty ? "(no error msg)" : error)"
                        resolveExpectation.fulfill()
                        keepPolling = false
                    } else if sawConnecting || !error.isEmpty {
                        result = "idle-before-connected: \(error.isEmpty ? "(no error msg)" : error)"
                        resolveExpectation.fulfill()
                        keepPolling = false
                    }

                case .switching:
                    break
                }

                if keepPolling {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        }

        NSLog("[RDPTest] Keepalive connect to \(devHost):\(devPort), hold=\(holdSeconds)s")
        manager.connect(host: devHost, port: devPort,
                        username: devUsername, password: devPassword, domain: devDomain)

        let waitTimeout = holdSeconds + 30.0
        let waiterResult = XCTWaiter.wait(for: [resolveExpectation], timeout: waitTimeout)
        keepPolling = false

        let stateBeforeDisconnect = AppStatus.protocolSessionState
        let lastError = AppStatus.protocolLastErrorMessage
        let logOutput = flushCapturedOutput()
        manager.disconnect()

        let rdpLines = filteredRDPLogLines(logOutput, maxLines: 140)

        if waiterResult != .completed {
            XCTFail("""
            KEEPALIVE TIMEOUT after \(waitTimeout)s
            holdSeconds=\(holdSeconds)
            state=\(stateBeforeDisconnect)
            sawConnecting=\(sawConnecting)
            connectedAt=\(connectedAt == nil ? "no" : "yes")
            error=\(lastError.isEmpty ? "(none)" : lastError)
            result=\(result)
            --- LOG (last 140 RDP lines) ---
            \(rdpLines.isEmpty ? "(no RDP log output captured)" : rdpLines)
            """)
            return
        }

        if result != "hold-ok" {
            XCTFail("""
            KEEPALIVE FAILED
            holdSeconds=\(holdSeconds)
            result=\(result)
            state=\(stateBeforeDisconnect)
            error=\(lastError.isEmpty ? "(none)" : lastError)
            --- LOG (last 140 RDP lines) ---
            \(rdpLines.isEmpty ? "(no RDP log output captured)" : rdpLines)
            """)
            return
        }
    }

    // MARK: - Diagnostic test for post-activation disconnect

    /// Diagnostic test that captures detailed protocol traces to debug why the server
    /// disconnects ~650ms after session activation.
    /// Writes report to /tmp/rdp_diagnostic_report.txt.
    ///
    /// Run: xcodebuild test-without-building -scheme openterface -only-testing openterfaceTests/RDPConnectionTests/testDiagnosePostActivationDisconnect
    func testDiagnosePostActivationDisconnect() throws {
        // Enable Logger file logging so we can read it after test
        let logManager = DependencyContainer.shared.resolve(LoggerProtocol.self) as? Logger
        logManager?.logToFile = true
        logManager?.createLogFile()
        logManager?.openLogFile()

        AppStatus.activeConnectionProtocol = .rdp
        AppStatus.protocolSessionState     = .idle
        AppStatus.protocolLastErrorMessage = ""
        UserSettings.shared.rdpEnableNLA   = true

        let manager = RDPClientManager.shared

        // Track timestamps of key events
        var timeline: [(Date, String)] = []
        let timelineLock = NSLock()
        func record(_ event: String) {
            let now = Date()
            timelineLock.lock()
            timeline.append((now, event))
            timelineLock.unlock()
        }

        let resolveExpectation = XCTestExpectation(description: "RDP diagnostic resolved")
        var keepPolling = true
        var sawConnecting = false
        var connectedAt: Date?
        var disconnectedAt: Date?
        var result = "timeout"

        // Hold for 10s after connecting — enough to capture the ~650ms disconnect
        let holdSeconds = 10.0

        let pollQueue = DispatchQueue(label: "rdp.test.diag.poll", qos: .userInitiated)
        pollQueue.async {
            while keepPolling {
                let state = AppStatus.protocolSessionState
                let error = AppStatus.protocolLastErrorMessage

                switch state {
                case .connecting:
                    if !sawConnecting {
                        sawConnecting = true
                        record("STATE: connecting")
                    }

                case .connected:
                    if connectedAt == nil {
                        connectedAt = Date()
                        record("STATE: connected (session active)")
                    }
                    // Wait for the full hold period
                    if let started = connectedAt,
                       Date().timeIntervalSince(started) >= holdSeconds {
                        result = "hold-ok"
                        record("HOLD: completed \(holdSeconds)s without disconnect")
                        resolveExpectation.fulfill()
                        keepPolling = false
                    }

                case .error:
                    disconnectedAt = Date()
                    let elapsed = connectedAt.map { disconnectedAt!.timeIntervalSince($0) }
                    if connectedAt != nil {
                        result = "disconnected-after-\(String(format: "%.3f", elapsed ?? 0))s: \(error)"
                        record("STATE: error (disconnected after \(String(format: "%.3fs", elapsed ?? 0))): \(error)")
                    } else {
                        result = "error-before-connected: \(error)"
                        record("STATE: error (before connected): \(error)")
                    }
                    resolveExpectation.fulfill()
                    keepPolling = false

                case .idle:
                    if connectedAt != nil {
                        disconnectedAt = Date()
                        let elapsed = disconnectedAt!.timeIntervalSince(connectedAt!)
                        result = "idle-after-\(String(format: "%.3f", elapsed))s: \(error.isEmpty ? "(no error msg)" : error)"
                        record("STATE: idle (disconnected after \(String(format: "%.3fs", elapsed))): \(error.isEmpty ? "(no msg)" : error)")
                        resolveExpectation.fulfill()
                        keepPolling = false
                    } else if sawConnecting || !error.isEmpty {
                        result = "idle-before-connected: \(error.isEmpty ? "(no error msg)" : error)"
                        record("STATE: idle (before connected): \(error.isEmpty ? "(no msg)" : error)")
                        resolveExpectation.fulfill()
                        keepPolling = false
                    }

                case .switching:
                    break
                }

                if keepPolling {
                    Thread.sleep(forTimeInterval: 0.01) // Poll faster for timing precision
                }
            }
        }

        record("TEST: connecting to \(devHost):\(devPort)")
        manager.connect(host: devHost, port: devPort,
                        username: devUsername, password: devPassword, domain: devDomain)

        let waitTimeout = holdSeconds + 30.0
        let waiterResult = XCTWaiter.wait(for: [resolveExpectation], timeout: waitTimeout)
        keepPolling = false

        let finalState = AppStatus.protocolSessionState
        let finalError = AppStatus.protocolLastErrorMessage

        // Collect log output from the stdout pipe (captured by setUp/tearDown)
        let logOutput = flushCapturedOutput()

        manager.disconnect()

        // Also try to read log file
        var logFileContent = ""
        if let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let logPath = docsDir.appendingPathComponent(AppStatus.logFileName)
            logFileContent = (try? String(contentsOf: logPath, encoding: .utf8)) ?? ""
        }

        // Use whichever log source has more data
        let combinedLog = logOutput.count > logFileContent.count ? logOutput : logFileContent

        // ── Build diagnostic report ──

        // 1. Timeline
        let startTime = timeline.first?.0 ?? Date()
        let timelineStr = timeline.map { (date, event) -> String in
            let offset = date.timeIntervalSince(startTime)
            return String(format: "+%07.3fs  %@", offset, event)
        }.joined(separator: "\n")

        // 2. All RDP-related log lines
        let allLines = combinedLog.components(separatedBy: "\n")
        let rdpLines = allLines.filter {
            $0.contains("RDP") || $0.contains("CredSSP") || $0.contains("NTLM") ||
            $0.contains("TLS") || $0.contains("MCS") || $0.contains("activation") ||
            $0.contains("Fast-Path") || $0.contains("Suppress") || $0.contains("Confirm Active") ||
            $0.contains("capability") || $0.contains("Bitmap") || $0.contains("frame")
        }

        // 3. Extract specific diagnostic sections
        let capLines = rdpLines.filter { $0.contains("caps") || $0.contains("capability") || $0.contains("Capability") || $0.contains("activation") }
        let fastPathLines = rdpLines.filter { $0.contains("Fast-Path") }
        let sendLines = rdpLines.filter { $0.contains("send:") }
        let hexLines = sendLines.filter { $0.contains("hex:") }

        // Build full report
        let report = """

        ╔══════════════════════════════════════════════════════════════════╗
        ║               RDP POST-ACTIVATION DISCONNECT DIAGNOSTIC        ║
        ╚══════════════════════════════════════════════════════════════════╝

        Result: \(result)
        Final State: \(finalState)
        Final Error: \(finalError.isEmpty ? "(none)" : finalError)
        Connected At: \(connectedAt?.description ?? "never")
        Disconnected At: \(disconnectedAt?.description ?? "n/a")
        Disconnect Latency: \(connectedAt.flatMap { c in disconnectedAt.map { d in String(format: "%.3fs", d.timeIntervalSince(c)) } } ?? "n/a")
        Wait Result: \(waiterResult == .completed ? "completed" : "timeout")
        Log Source: \(logOutput.count > logFileContent.count ? "stdout-pipe (\(logOutput.count) chars)" : "log-file (\(logFileContent.count) chars)")
        Total Log Lines: \(allLines.count)
        RDP Log Lines: \(rdpLines.count)

        ── TIMELINE ──
        \(timelineStr.isEmpty ? "(empty)" : timelineStr)

        ── CAPABILITY EXCHANGE (\(capLines.count) lines) ──
        \(capLines.suffix(50).joined(separator: "\n"))

        ── FAST-PATH UPDATES (\(fastPathLines.count) lines) ──
        \(fastPathLines.suffix(30).joined(separator: "\n"))

        ── SENT PDU HEX (first 128 bytes each, \(hexLines.count) PDUs) ──
        \(hexLines.suffix(30).joined(separator: "\n"))

        ── ALL RDP LOG (\(rdpLines.count) lines, showing last 200) ──
        \(rdpLines.suffix(200).joined(separator: "\n"))
        """

        // Write report to disk — use sandbox-friendly temporary directory
        let tempDir = NSTemporaryDirectory()
        let reportPath = (tempDir as NSString).appendingPathComponent("rdp_diagnostic_report.txt")
        do {
            try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
        } catch {
            // Fallback to Documents directory
            if let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let altPath = docsDir.appendingPathComponent("rdp_diagnostic_report.txt").path
                try? report.write(toFile: altPath, atomically: true, encoding: .utf8)
            }
        }

        // Also add report as XCTest attachment for result bundle retrieval
        let attachment = XCTAttachment(string: report)
        attachment.name = "RDP Diagnostic Report"
        attachment.lifetime = .keepAlways
        add(attachment)

        if waiterResult != .completed {
            XCTFail("DIAGNOSTIC TIMEOUT after \(waitTimeout)s — report in xcresult attachment")
            return
        }

        if result == "hold-ok" {
            return
        }

        XCTFail("POST-ACTIVATION DISCONNECT — report in xcresult attachment and \(reportPath)")
    }
}
