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

/// Parses the raw byte stream from the serial port into complete protocol messages.
///
/// The protocol uses a 3-byte prefix (0x57, 0xAB, 0x00) and includes a length
/// byte followed by a checksum.
final class SerialMessageParser {
    private let logger: LoggerProtocol?
    private var buffer = Data()

    /// Called when a complete and checksum-valid message is available.
    var onMessage: ((Data) -> Void)?

    init(logger: LoggerProtocol? = nil) {
        self.logger = logger
    }

    /// Appends incoming bytes and attempts to parse complete messages.
    func append(_ data: Data) {
        guard !data.isEmpty else { return }

        if logger?.SerialDataPrint == true {
            let dataString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            logger?.log(content: "Rx: \(dataString)")
        }

        buffer.append(data)
        processBufferedMessages()
    }

    /// Reset internal buffer state.
    func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    private func processBufferedMessages() {
        var bytes = [UInt8](buffer)

        while bytes.count >= 6 { // Minimum message size: 5 bytes header + 1 byte checksum
            guard let prefixIndex = findNextMessageStart(in: bytes, from: 0) else {
                logger?.log(content: "No valid message start found in buffer, discarding \(bytes.count) bytes")
                bytes.removeAll()
                break
            }

            // Drop invalid bytes before a valid prefix
            if prefixIndex > 0 {
                if logger?.SerialDataPrint == true {
                    let skipped = bytes[0..<prefixIndex]
                    let skippedString = skipped.map { String(format: "%02X", $0) }.joined(separator: " ")
                    logger?.log(content: "Skipping invalid data: \(skippedString)")
                }
                bytes.removeFirst(prefixIndex)
            }

            // Need at least 6 bytes for a complete header+checksum
            if bytes.count < 6 {
                if logger?.SerialDataPrint == true {
                    logger?.log(content: "Not enough data for complete message, waiting for more data")
                }
                break
            }

            let len = bytes[4]
            let expectedLength = Int(len) + 6
            if bytes.count < expectedLength {
                if logger?.SerialDataPrint == true {
                    logger?.log(content: "Incomplete message in buffer, waiting for more data, expected length: \(expectedLength), current length: \(bytes.count)")
                }
                break
            }

            let messageBytes = Array(bytes[0..<expectedLength])
            let checksum = SerialProtocolCommands.calculateChecksum(for: Array(messageBytes[0..<(messageBytes.count - 1)]))
            let receivedChecksum = messageBytes.last!

            if receivedChecksum == checksum {
                onMessage?(Data(messageBytes))
            } else {
                if logger?.SerialDataPrint == true {
                    let messageString = messageBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                    let checksumHex = String(format: "%02X", checksum)
                    let receivedHex = String(format: "%02X", receivedChecksum)
                    logger?.log(content: "Checksum error, discard message: \(messageString), calculated: \(checksumHex), received: \(receivedHex)")
                }
            }

            // Remove processed bytes (whether valid or not)
            bytes.removeFirst(expectedLength)
        }

        buffer = Data(bytes)
    }

    private func findNextMessageStart(in bytes: [UInt8], from startIndex: Int) -> Int? {
        let prefix: [UInt8] = [0x57, 0xAB, 0x00]
        for i in startIndex..<(bytes.count - 2) {
            if bytes[i] == prefix[0] && bytes[i + 1] == prefix[1] && bytes[i + 2] == prefix[2] {
                return i
            }
        }
        return nil
    }
}
