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
import Darwin
import Security

// MARK: - FD reference box for SecureTransport I/O callbacks

private final class FDBox {
    var fd: Int32
    init(_ fd: Int32) { self.fd = fd }
}

// MARK: - SecureTransport I/O callbacks (C function pointers)

private let sslReadFunc: SSLReadFunc = { connRef, buf, dataLen in
    let box = Unmanaged<FDBox>.fromOpaque(connRef).takeUnretainedValue()
    let n = Darwin.read(box.fd, buf, dataLen.pointee)
    if n > 0 { dataLen.pointee = n; return noErr }
    dataLen.pointee = 0
    if n == 0 { return errSSLClosedGraceful }
    return (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) ? errSSLWouldBlock : errSecIO
}

private let sslWriteFunc: SSLWriteFunc = { connRef, buf, dataLen in
    let box = Unmanaged<FDBox>.fromOpaque(connRef).takeUnretainedValue()
    let n = Darwin.write(box.fd, buf, dataLen.pointee)
    if n >= 0 { dataLen.pointee = n; return noErr }
    dataLen.pointee = 0
    return errSecIO
}

// MARK: - RDPTLSError

enum RDPTLSError: Error, LocalizedError {
    case notConnected
    case connectFailed(String)
    case sendFailed(String)
    case tlsFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "RDPTLSChannel: socket not connected"
        case .connectFailed(let s): return "RDPTLSChannel: TCP connect failed – \(s)"
        case .sendFailed(let s): return "RDPTLSChannel: send failed – \(s)"
        case .tlsFailed(let s): return "RDPTLSChannel: TLS error – \(s)"
        }
    }
}

// MARK: - RDPTLSChannel

/// Thin transport layer for RDP over NLA:
///  1. Plain TCP for the X.224 connection-negotiation phase
///  2. TLS upgrade (SecureTransport SSLHandshake) immediately after the server
///     selects HYBRID in the X.224 Connection Confirm
///  3. All subsequent I/O (CredSSP + RDP traffic) passes through SSLRead/SSLWrite
///
/// Threading model: the `queue` passed at init is the RDP serial queue.
/// `connect()` performs the TCP handshake on a global background queue then
/// fires callbacks on `queue`.  Reads arrive via DispatchSourceRead on `queue`.
/// Writes and `upgradeToTLS()` must be called on `queue`.
final class RDPTLSChannel {

    // Callbacks – always delivered on `queue`
    var onData: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    var onEOF: (() -> Void)?

    /// RSAPublicKey DER bytes (PKCS#1 SEQUENCE) from the server's TLS leaf certificate.
    /// Populated after a successful `upgradeToTLS()` call.
    private(set) var serverPublicKeyDER: Data?

    /// Full SubjectPublicKeyInfo DER (SEQUENCE { AlgorithmIdentifier, BIT STRING })
    /// from the server's TLS leaf certificate. Used for CredSSP v6 binding hash.
    private(set) var serverSubjectPublicKeyInfo: Data?

    private var sockfd: Int32 = -1
    var socketFD: Int32 { sockfd }
    private var fdBox: FDBox?
    private var sslCtx: SSLContext?
    private var readSource: DispatchSourceRead?
    private let queue: DispatchQueue
    private var consecutiveSSLParamReadErrors = 0

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    private func connectionFailureDetail(forSocketError code: Int32, host: String, port: Int) -> String {
        switch code {
        case 51:
            return "Cannot reach \(host):\(port). The network is unreachable. Check that the host is online, the address is correct, and any VPN or routing required for that network is active."
        case 60:
            return "Timed out while connecting to \(host):\(port). Check that the host is reachable and that the RDP port is open."
        case 61:
            return "Connection to \(host):\(port) was refused. Verify that Remote Desktop is enabled on the host and that the port is correct."
        case 64, 65:
            return "The remote host \(host) is unreachable. Check the address, network path, and firewall settings."
        default:
            let systemMessage = String(cString: Darwin.strerror(code))
            return "Failed to connect to \(host):\(port): \(systemMessage)"
        }
    }

    private func connectionFailureDetail(forErrno code: Int32, host: String, port: Int) -> String {
        connectionFailureDetail(forSocketError: code, host: host, port: port)
    }

    deinit { close() }

    // MARK: - Connect

    /// Initiates a non-blocking TCP connect.  The `completion` is called on `queue`.
    func connect(host: String, port: Int, completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let fd = try self.tcpConnect(host: host, port: port)
                self.queue.async {
                    self.sockfd = fd
                    self.fdBox  = FDBox(fd)
                    self.startReadSource()
                    completion(nil)
                }
            } catch {
                self.queue.async { completion(error) }
            }
        }
    }

    /// Blocking TCP connect with a 10-second timeout (runs on caller's thread).
    private func tcpConnect(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family   = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags    = AI_NUMERICSERV

        var res: UnsafeMutablePointer<addrinfo>?
        let rv = getaddrinfo(host, String(port), &hints, &res)
        guard rv == 0, let addrList = res else {
            let msg = rv == 0 ? "no addresses" : String(cString: gai_strerror(rv))
            throw RDPTLSError.connectFailed("getaddrinfo('\(host)'): \(msg)")
        }
        defer { freeaddrinfo(res) }

        var connectError = ""
        var ai: UnsafeMutablePointer<addrinfo>? = addrList
        while let info = ai {
            let fd = Darwin.socket(info.pointee.ai_family,
                                   info.pointee.ai_socktype,
                                   info.pointee.ai_protocol)
            if fd >= 0 {
                // TCP_NODELAY – reduces latency for small RDP PDUs
                var one: Int32 = 1
                Darwin.setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one,
                                  socklen_t(MemoryLayout<Int32>.size))

                // SO_NOSIGPIPE – prevent SIGPIPE when writing to a closed socket
                Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one,
                                  socklen_t(MemoryLayout<Int32>.size))

                // Non-blocking so we can impose a connect timeout via select()
                let origFlags = fcntl(fd, F_GETFL, 0)
                fcntl(fd, F_SETFL, origFlags | O_NONBLOCK)

                let r = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
                if r == 0 || errno == EINPROGRESS || errno == EWOULDBLOCK {
                    // Wait for writable (connect complete) up to 10 s
                    var wfds = fd_set()
                    fdSetZero(&wfds)
                    fdSetBit(fd, &wfds)
                    var tv = timeval(tv_sec: 10, tv_usec: 0)
                    let n = Darwin.select(fd + 1, nil, &wfds, nil, &tv)
                    if n > 0 {
                        var soErr: Int32 = 0
                        var soLen = socklen_t(MemoryLayout<Int32>.size)
                        Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soLen)
                        if soErr == 0 {
                            // Switch back to blocking for normal I/O
                            fcntl(fd, F_SETFL, origFlags & ~O_NONBLOCK)
                            return fd
                        }
                        connectError = self.connectionFailureDetail(forSocketError: soErr, host: host, port: port)
                    } else {
                        if n == 0 {
                            connectError = self.connectionFailureDetail(forSocketError: 60, host: host, port: port)
                        } else {
                            connectError = self.connectionFailureDetail(forErrno: errno, host: host, port: port)
                        }
                    }
                } else {
                    connectError = self.connectionFailureDetail(forErrno: errno, host: host, port: port)
                }
                Darwin.close(fd)
            }
            ai = info.pointee.ai_next
        }
        throw RDPTLSError.connectFailed(connectError)
    }

    // MARK: - TLS Upgrade

    /// Upgrades the existing blocking TCP socket to TLS using SecureTransport.
    /// **Must be called on `queue`.**  Blocks the queue briefly for the handshake
    /// (< 200 ms on a LAN).
    ///
    /// After this returns without throwing, all subsequent `send()` and read-source
    /// callbacks use encrypted TLS channels.
    func upgradeToTLS(hostname: String) throws {
        guard sockfd >= 0 else { throw RDPTLSError.notConnected }

        // Suspend the async read source so we own the socket during handshake
        readSource?.suspend()

        guard let ctx = SSLCreateContext(kCFAllocatorDefault, .clientSide, .streamType) else {
            readSource?.resume()
            throw RDPTLSError.tlsFailed("SSLCreateContext returned nil")
        }

        let box = fdBox!
        SSLSetIOFuncs(ctx, sslReadFunc, sslWriteFunc)
        SSLSetConnection(ctx, Unmanaged.passUnretained(box).toOpaque())
        SSLSetPeerDomainName(ctx, hostname, hostname.utf8.count)

        // We intentionally accept self-signed server certs (RDP servers use them).
        // breakOnServerAuth lets us continue past the cert-validation step.
        SSLSetSessionOption(ctx, .breakOnServerAuth, true)

        var status: OSStatus
        // errSSLServerAuthCompleted = -9841, errSSLWouldBlock = -9803
        let errServerAuthCompleted: OSStatus = -9841
        repeat {
            status = SSLHandshake(ctx)
        } while status == errServerAuthCompleted || status == errSSLWouldBlock

        guard status == noErr else {
            readSource?.resume()
            throw RDPTLSError.tlsFailed(
                "SSLHandshake failed (OSStatus \(status)); check server certificate / TLS version")
        }

        sslCtx = ctx
        extractServerPublicKey(from: ctx)

        // Restore the read source – handleReadable() now routes through SSLRead
        readSource?.resume()
    }

    // MARK: - Send

    /// Write `data` to the socket (plain or TLS).
    /// **Must be called on `queue`.**
    func send(_ data: Data) throws {
        guard sockfd >= 0 else { throw RDPTLSError.notConnected }
        if let ctx = sslCtx {
            try sendTLS(ctx: ctx, data: data)
        } else {
            try sendPlain(data: data)
        }
    }

    // MARK: - Close

    func close() {
        readSource?.cancel()
        readSource = nil
        if let ctx = sslCtx {
            SSLClose(ctx)
            sslCtx = nil
        }
        if sockfd >= 0 {
            Darwin.close(sockfd)
            sockfd = -1
        }
        fdBox = nil
    }

    // MARK: - Private helpers

    private func startReadSource() {
        let src = DispatchSource.makeReadSource(fileDescriptor: sockfd, queue: queue)
        readSource = src
        src.setEventHandler { [weak self] in self?.handleReadable() }
        src.setCancelHandler { }
        src.resume()
    }

    private func handleReadable() {
        var buf = [UInt8](repeating: 0, count: 65536)

        if let ctx = sslCtx {
            // Drain all buffered TLS application-data records
            var sawCloseStatus = false
            repeat {
                var processed = 0
                let status = SSLRead(ctx, &buf, buf.count, &processed)
                if processed > 0 {
                    consecutiveSSLParamReadErrors = 0
                    onData?(Data(buf[0..<processed]))
                }
                switch status {
                case noErr:
                    consecutiveSSLParamReadErrors = 0
                    break   // check SSLGetBufferedReadSize for more
                case errSSLWouldBlock:
                    return  // no full TLS record available yet
                 case errSSLClosedGraceful, errSSLClosedAbort, errSSLClosedNoNotify,
                     -9838, -9839, -9840:   // raw values in case SDK constants differ at runtime
                    let reason: String
                    switch status {
                    case errSSLClosedGraceful: reason = "TLS close_notify (graceful)"
                    case errSSLClosedAbort: reason = "TLS connection aborted"
                    case errSSLClosedNoNotify: reason = "TCP closed without TLS close_notify"
                    default: reason = "SSL close status=\(status)"
                    }
                    NSLog("[RDP] TLS EOF status observed: %@ processed=%d", reason, processed)
                    sawCloseStatus = true
                    // If SecureTransport surfaced application data alongside the close status,
                    // keep draining first so trailing records are not dropped.
                    if processed == 0 {
                        onEOF?(); return
                    }
                    break
                case -50:   // errSSLParam
                    if isSocketPeerClosed() {
                        onEOF?(); return
                    }

                    // errSSLParam can be transient in SecureTransport under heavy record churn.
                    // Tolerate a few consecutive hits before surfacing channel error.
                    consecutiveSSLParamReadErrors += 1
                    if consecutiveSSLParamReadErrors <= 3 {
                        return
                    }
                    onError?("SSLRead errSSLParam (-50) repeated \(consecutiveSSLParamReadErrors)x; treating as transport read error")
                    return
                    default:
                    consecutiveSSLParamReadErrors = 0
                    onError?("SSLRead error OSStatus=\(status)"); return
                }
                var buffered = 0
                SSLGetBufferedReadSize(ctx, &buffered)
                if buffered == 0 {
                    // SecureTransport's internal application-data buffer is empty, but data that
                    // arrived in the TCP kernel buffer *while* we were executing onData above
                    // (potentially hundreds of ms) would not yet be reflected here.
                    // Peek at the kernel socket buffer without consuming any bytes: if there
                    // is anything waiting, loop back so SSLRead can pull it in immediately
                    // rather than relying on DispatchSourceRead to re-fire (which adds latency
                    // and can miss the window before a TLS close_notify is processed).
                    var peek: UInt8 = 0
                    let n = Darwin.recv(sockfd, &peek, 1, MSG_PEEK | MSG_DONTWAIT)
                    if n <= 0 {
                        if sawCloseStatus {
                            onEOF?()
                        }
                        return
                    }
                    // n > 0: kernel buffer has bytes — continue draining
                }
            } while true

        } else {
            let n = Darwin.read(sockfd, &buf, buf.count)
            if n > 0 {
                onData?(Data(buf[0..<n]))
            } else if n == 0 {
                onEOF?()
            } else if errno != EAGAIN && errno != EINTR && errno != EWOULDBLOCK {
                onError?("read() errno=\(errno)")
            }
        }
    }

    private func sendPlain(data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            while offset < data.count {
                let n = Darwin.write(sockfd, ptr.baseAddress! + offset, data.count - offset)
                if n <= 0 { throw RDPTLSError.sendFailed("write() errno=\(errno)") }
                offset += n
            }
        }
    }

    private func sendTLS(ctx: SSLContext, data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            while offset < data.count {
                var written = 0
                let status = SSLWrite(ctx, ptr.baseAddress! + offset, data.count - offset, &written)
                if status == noErr || (status == errSSLWouldBlock && written > 0) {
                    offset += written
                } else if status == errSSLWouldBlock {
                    // Brief busy-wait: shouldn't happen on blocking socket after handshake
                    continue
                } else {
                    throw RDPTLSError.sendFailed("SSLWrite OSStatus=\(status)")
                }
            }
        }
    }

    private func isSocketPeerClosed() -> Bool {
        guard sockfd >= 0 else { return true }
        var byte: UInt8 = 0
        let n = Darwin.recv(sockfd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if n == 0 {
            return true
        }
        if n > 0 {
            return false
        }

        switch errno {
        case EAGAIN, EWOULDBLOCK:
            return false
        case ECONNRESET, ENOTCONN, EPIPE, ETIMEDOUT:
            return true
        default:
            return false
        }
    }

    private func extractServerPublicKey(from ctx: SSLContext) {
        var peerTrust: SecTrust?
        guard SSLCopyPeerTrust(ctx, &peerTrust) == noErr, let trust = peerTrust else { return }

        let cert: SecCertificate?
        if #available(macOS 12.0, *) {
            cert = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        } else {
            cert = SecTrustGetCertificateAtIndex(trust, 0)
        }
        guard let leafCert = cert else { return }

        // CredSSP uses the SubjectPublicKeyInfo from the certificate (MS-CSSP §3.1.5).
        // For FreeRDP compatibility this is the PKCS#1 RSAPublicKey (i2d_PublicKey format).
        // SecKeyCopyExternalRepresentation returns exactly this format for RSA keys.
        if let key = SecCertificateCopyKey(leafCert) {
            var cfErr: Unmanaged<CFError>?
            if let keyDER = SecKeyCopyExternalRepresentation(key, &cfErr) {
                serverPublicKeyDER = keyDER as Data
            }
        }

        // Also extract full SubjectPublicKeyInfo from the certificate DER for v6 hash
        let certDER = SecCertificateCopyData(leafCert) as Data
        serverSubjectPublicKeyInfo = extractSubjectPublicKeyInfo(from: certDER)
    }

    /// Extract SubjectPublicKeyInfo SEQUENCE from certificate DER.
    /// TBSCertificate ::= SEQUENCE { version [0], serial, sigAlg, issuer, validity, subject, subjectPKInfo, ... }
    private func extractSubjectPublicKeyInfo(from certDER: Data) -> Data? {
        // Peel outer SEQUENCE (Certificate)
        guard let certContent = derPeelSequence(certDER) else { return nil }
        // Peel TBSCertificate SEQUENCE
        guard let (tbsContent, _) = derFirstTLV(certContent) else { return nil }
        guard let tbsInner = derPeelSequence(tbsContent) else { return nil }

        // Walk through TBSCertificate fields to find field index 6 (subjectPublicKeyInfo)
        // Fields: version[0](optional), serialNumber, signature, issuer, validity, subject, subjectPKInfo
        var cursor = tbsInner.startIndex
        var fieldIndex = 0

        while cursor < tbsInner.endIndex {
            guard let (tag, _, nextCursor, rawTLV) = derNextTLVRaw(tbsInner, at: cursor) else { break }

            // version is [0] EXPLICIT — tagged 0xA0. If first field isn't 0xA0, version is absent
            if fieldIndex == 0 && tag == 0xA0 {
                // This is the version field; skip it and don't increment fieldIndex
                // (because if absent, field 0 is serialNumber)
                cursor = nextCursor
                continue
            }

            if fieldIndex == 5 {
                // Field index 5 (0-based, skipping version) = subjectPublicKeyInfo at position 6
                // This is the full SEQUENCE { AlgorithmIdentifier, BIT STRING }
                return rawTLV
            }

            fieldIndex += 1
            cursor = nextCursor
        }
        return nil
    }

    private func derPeelSequence(_ data: Data) -> Data? {
        guard !data.isEmpty, data[data.startIndex] == 0x30 else { return nil }
        return derPeelContent(data)
    }

    private func derFirstTLV(_ data: Data) -> (tlv: Data, rest: Data)? {
        guard let (_, _, next, raw) = derNextTLVRaw(data, at: data.startIndex) else { return nil }
        return (raw, data.suffix(from: next))
    }

    /// Returns (tag, content, nextIndex, rawTLVbytes) for the TLV at `start`.
    private func derNextTLVRaw(_ data: Data, at start: Data.Index) -> (UInt8, Data, Data.Index, Data)? {
        guard start < data.endIndex else { return nil }
        let tag = data[start]
        var pos = data.index(after: start)
        guard pos < data.endIndex else { return nil }
        let firstLen = data[pos]
        pos = data.index(after: pos)
        let length: Int
        if firstLen < 0x80 {
            length = Int(firstLen)
        } else {
            let numBytes = Int(firstLen & 0x7F)
            guard pos + numBytes <= data.endIndex else { return nil }
            var len = 0
            for i in 0..<numBytes {
                len = (len << 8) | Int(data[data.index(pos, offsetBy: i)])
            }
            pos = data.index(pos, offsetBy: numBytes)
            length = len
        }
        guard pos + length <= data.endIndex else { return nil }
        let content = data.subdata(in: pos..<data.index(pos, offsetBy: length))
        let next = data.index(pos, offsetBy: length)
        let raw = data.subdata(in: start..<next)
        return (tag, content, next, raw)
    }

    private func derPeelContent(_ data: Data) -> Data? {
        guard let (_, content, _, _) = derNextTLVRaw(data, at: data.startIndex) else { return nil }
        return content
    }
}

// MARK: - fd_set helpers (Swift equivalents of FD_ZERO / FD_SET)

private func fdSetZero(_ set: inout fd_set) {
    withUnsafeMutableBytes(of: &set) { Darwin.memset($0.baseAddress!, 0, $0.count) }
}

private func fdSetBit(_ fd: Int32, _ set: inout fd_set) {
    let slot = Int(fd) / 32
    let bit  = Int(fd) % 32
    withUnsafeMutableBytes(of: &set) {
        $0.bindMemory(to: Int32.self)[slot] |= Int32(bitPattern: 1 << UInt32(bit))
    }
}
