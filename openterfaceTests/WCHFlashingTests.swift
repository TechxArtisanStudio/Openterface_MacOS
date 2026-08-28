import XCTest
@testable import openterface

final class WCHFlashingTests: XCTestCase {

    // MARK: - WCHHexFileParser Tests

    func testHexParserBasicRecord() throws {
        // Intel HEX format: :BBAAAATT[DD...]CC
        // BB = byte count, AAAA = address, TT = type, DD = data, CC = checksum
        let hexData = """
        :020000040800F2
        :040000001122334488
        :00000001FF
        """.data(using: .utf8)!

        let binary = try WCHHexFileParser.parse(data: hexData)

        // Extended address 0x0800 sets base to 0x08000000
        // Data record at 0x0000 writes [0x11, 0x22, 0x33, 0x44] at 0x08000000
        XCTAssertEqual(binary.count, 4)
        XCTAssertEqual(binary, [0x11, 0x22, 0x33, 0x44])
    }

    func testHexParserMultipleRecords() throws {
        let hexData = """
        :020000040800F2
        :02000000AABB3C
        :02000200CCDD1F
        :00000001FF
        """.data(using: .utf8)!

        let binary = try WCHHexFileParser.parse(data: hexData)

        // First record: [0xAA, 0xBB] at 0x08000000
        // Second record: [0xCC, 0xDD] at 0x08000002
        XCTAssertEqual(binary.count, 4)
        XCTAssertEqual(binary, [0xAA, 0xBB, 0xCC, 0xDD])
    }

    func testHexParserWithGaps() throws {
        let hexData = """
        :020000040800F2
        :01000000AA56
        :01001000BB45
        :00000001FF
        """.data(using: .utf8)!

        let binary = try WCHHexFileParser.parse(data: hexData)

        // Gap between 0x08000000 and 0x08000010 should be filled with 0xFF
        XCTAssertEqual(binary.count, 17) // 0x11 bytes from 0x00 to 0x10 inclusive
        XCTAssertEqual(binary[0], 0xAA)
        XCTAssertEqual(binary[16], 0xBB)
        // Middle bytes should be 0xFF (erased flash pattern)
        for i in 1..<16 {
            XCTAssertEqual(binary[i], 0xFF, "Gap byte at index \(i) should be 0xFF")
        }
    }

    func testHexParserEmptyFile() throws {
        let hexData = """
        :00000001FF
        """.data(using: .utf8)!

        let binary = try WCHHexFileParser.parse(data: hexData)
        XCTAssertEqual(binary.count, 0)
    }

    func testHexParserWithBOM() throws {
        // UTF-8 BOM + hex content
        var hexData = Data([0xEF, 0xBB, 0xBF]) // UTF-8 BOM
        hexData.append("""
        :020000040800F2
        :02000000AABB3C
        :00000001FF
        """.data(using: .utf8)!)

        let binary = try WCHHexFileParser.parse(data: hexData)
        XCTAssertEqual(binary, [0xAA, 0xBB])
    }

    func testHexParserInvalidFormat() {
        let hexData = "not a hex file".data(using: .utf8)!

        XCTAssertThrowsError(try WCHHexFileParser.parse(data: hexData)) { error in
            XCTAssertTrue(error is WCHHexParseError)
        }
    }

    // MARK: - Array Chunking Tests

    func testChunkingExactMultiple() {
        let array = [1, 2, 3, 4, 5, 6]
        let chunks = array.wchChunked(into: 2)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0], [1, 2])
        XCTAssertEqual(chunks[1], [3, 4])
        XCTAssertEqual(chunks[2], [5, 6])
    }

    func testChunkingWithRemainder() {
        let array = [1, 2, 3, 4, 5]
        let chunks = array.wchChunked(into: 2)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0], [1, 2])
        XCTAssertEqual(chunks[1], [3, 4])
        XCTAssertEqual(chunks[2], [5])
    }

    func testChunkingEmptyArray() {
        let array: [Int] = []
        let chunks = array.wchChunked(into: 2)

        XCTAssertEqual(chunks.count, 0)
    }

    func testChunkingLargerThanArray() {
        let array = [1, 2, 3]
        let chunks = array.wchChunked(into: 10)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], [1, 2, 3])
    }

    func testChunkingSize56() {
        // WCH protocol uses 56-byte chunks
        let array = Array(0..<100)
        let chunks = array.wchChunked(into: 56)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, 56)
        XCTAssertEqual(chunks[1].count, 44)
    }

    // MARK: - WCHProtocol Tests

    func testIdentifyCommandEncoding() {
        let cmd = WCHCommand.identify(deviceID: 0x12, deviceType: 0x34)
        let bytes = cmd.toRawBytes()

        XCTAssertEqual(bytes[0], WCHCommands.identify) // 0xa1
        XCTAssertEqual(bytes[1], 0x12) // length
        XCTAssertEqual(bytes[2], 0x00)
        XCTAssertEqual(bytes[3], 0x12) // deviceID
        XCTAssertEqual(bytes[4], 0x34) // deviceType
        // Rest should be "MCU ISP & WCH.CN" ASCII
        let expectedString = "MCU ISP & WCH.CN"
        let actualString = String(bytes: bytes[5..<19], encoding: .ascii)
        XCTAssertEqual(actualString, expectedString)
    }

    func testEraseCommandEncoding() {
        let cmd = WCHCommand.erase(sectors: 0x00000010) // 16 sectors
        let bytes = cmd.toRawBytes()

        XCTAssertEqual(bytes[0], WCHCommands.erase) // 0xa4
        XCTAssertEqual(bytes[1], 0x04) // length low
        XCTAssertEqual(bytes[2], 0x00) // length high
        // Sectors in little-endian
        XCTAssertEqual(bytes[3], 0x10)
        XCTAssertEqual(bytes[4], 0x00)
        XCTAssertEqual(bytes[5], 0x00)
        XCTAssertEqual(bytes[6], 0x00)
    }

    func testProgramCommandEncoding() {
        let data: [UInt8] = [0x11, 0x22, 0x33]
        let cmd = WCHCommand.program(address: 0x08000100, padding: 0xAB, data: data)
        let bytes = cmd.toRawBytes()

        XCTAssertEqual(bytes[0], WCHCommands.program) // 0xa5
        // Payload size = 4 (address) + 1 (padding) + 3 (data) = 8
        XCTAssertEqual(bytes[1], 0x08) // length low
        XCTAssertEqual(bytes[2], 0x00) // length high
        // Address in little-endian
        XCTAssertEqual(bytes[3], 0x00)
        XCTAssertEqual(bytes[4], 0x01)
        XCTAssertEqual(bytes[5], 0x00)
        XCTAssertEqual(bytes[6], 0x08)
        // Padding
        XCTAssertEqual(bytes[7], 0xAB)
        // Data
        XCTAssertEqual(bytes[8], 0x11)
        XCTAssertEqual(bytes[9], 0x22)
        XCTAssertEqual(bytes[10], 0x33)
    }

    func testVerifyCommandEncoding() {
        let data: [UInt8] = [0xAA, 0xBB]
        let cmd = WCHCommand.verify(address: 0x08000200, padding: 0xCD, data: data)
        let bytes = cmd.toRawBytes()

        XCTAssertEqual(bytes[0], WCHCommands.verify) // 0xa6
        // Payload size = 4 + 1 + 2 = 7
        XCTAssertEqual(bytes[1], 0x07)
        XCTAssertEqual(bytes[2], 0x00)
        // Address in little-endian
        XCTAssertEqual(bytes[3], 0x00)
        XCTAssertEqual(bytes[4], 0x02)
        XCTAssertEqual(bytes[5], 0x00)
        XCTAssertEqual(bytes[6], 0x08)
        // Padding
        XCTAssertEqual(bytes[7], 0xCD)
        // Data
        XCTAssertEqual(bytes[8], 0xAA)
        XCTAssertEqual(bytes[9], 0xBB)
    }

    func testReadConfigCommandEncoding() {
        let cmd = WCHCommand.readConfig(bitMask: WCHConstants.cfgMaskAll)
        let bytes = cmd.toRawBytes()

        XCTAssertEqual(bytes[0], WCHCommands.readConfig) // 0xa7
        XCTAssertEqual(bytes[1], 0x02) // length
        XCTAssertEqual(bytes[2], 0x00)
        XCTAssertEqual(bytes[3], WCHConstants.cfgMaskAll) // 0x1f
        XCTAssertEqual(bytes[4], 0x00)
    }

    func testDataReadCommandEncoding() {
        let cmd = WCHCommand.dataRead(address: 0x08001000, length: 0x0038) // 56 bytes
        let bytes = cmd.toRawBytes()

        XCTAssertEqual(bytes[0], WCHCommands.dataRead) // 0xab
        XCTAssertEqual(bytes[1], 0x06) // length
        XCTAssertEqual(bytes[2], 0x00)
        // Address in little-endian
        XCTAssertEqual(bytes[3], 0x00)
        XCTAssertEqual(bytes[4], 0x10)
        XCTAssertEqual(bytes[5], 0x00)
        XCTAssertEqual(bytes[6], 0x08)
        // Length in little-endian
        XCTAssertEqual(bytes[7], 0x38)
        XCTAssertEqual(bytes[8], 0x00)
    }

    // MARK: - WCHResponse Tests

    func testResponseParsingOK() throws {
        // OK response: command, status, length (2 bytes), payload
        let rawBytes: [UInt8] = [0xa6, 0x00, 0x02, 0x00, 0x11, 0x22]
        let response = try WCHResponse.fromRawBytes(rawBytes)

        XCTAssertTrue(response.isOK)
        XCTAssertEqual(response.payload, [0x11, 0x22])
    }

    func testResponseParsingEmptyPayload() throws {
        let rawBytes: [UInt8] = [0xa6, 0x00, 0x00, 0x00]
        let response = try WCHResponse.fromRawBytes(rawBytes)

        XCTAssertTrue(response.isOK)
        XCTAssertEqual(response.payload.count, 0)
    }

    func testResponseParsingInvalidLength() {
        // Length says 5 bytes but only 2 bytes of payload
        let rawBytes: [UInt8] = [0xa6, 0x00, 0x05, 0x00, 0x11, 0x22]

        XCTAssertThrowsError(try WCHResponse.fromRawBytes(rawBytes)) { error in
            XCTAssertTrue(error is WCHProtocolError)
        }
    }

    func testResponseParsingTooShort() {
        let rawBytes: [UInt8] = [0xa6, 0x00]

        XCTAssertThrowsError(try WCHResponse.fromRawBytes(rawBytes)) { error in
            XCTAssertEqual(error as? WCHProtocolError, WCHProtocolError.invalidResponse)
        }
    }

    // MARK: - XOR Encryption Symmetry Tests

    func testXOREncryptionSymmetry() {
        // XOR encryption should be symmetric: encrypt(encrypt(x)) == x
        let originalData: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55]
        let xorKey: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE]

        // First encryption
        let encrypted = originalData.enumerated().map { offset, byte in
            byte ^ xorKey[offset % xorKey.count]
        }

        // Second encryption (should give back original)
        let decrypted = encrypted.enumerated().map { offset, byte in
            byte ^ xorKey[offset % xorKey.count]
        }

        XCTAssertEqual(decrypted, originalData)
    }

    func testXOREncryptionWrapping() {
        // Key should wrap around for data longer than key
        let data: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66]
        let key: [UInt8] = [0xAA, 0xBB] // 2-byte key

        let encrypted = data.enumerated().map { offset, byte in
            byte ^ key[offset % key.count]
        }

        // Verify wrapping: data[0] ^ key[0], data[1] ^ key[1], data[2] ^ key[0], etc.
        XCTAssertEqual(encrypted[0], 0x11 ^ 0xAA)
        XCTAssertEqual(encrypted[1], 0x22 ^ 0xBB)
        XCTAssertEqual(encrypted[2], 0x33 ^ 0xAA) // key wraps
        XCTAssertEqual(encrypted[3], 0x44 ^ 0xBB)
        XCTAssertEqual(encrypted[4], 0x55 ^ 0xAA)
        XCTAssertEqual(encrypted[5], 0x66 ^ 0xBB)
    }

    // MARK: - WriteConfig Command Tests

    func testWriteConfigCommandEncoding() {
        // Test WriteConfig command (0xA8) used for protect/unprotect
        let configData: [UInt8] = [0xA5, 0x5A, 0x3F, 0xC0, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF]
        let cmd = WCHCommand.writeConfig(bitMask: WCHConstants.cfgMaskRDPRUserDataWPR, data: configData)
        let bytes = cmd.toRawBytes()

        XCTAssertEqual(bytes[0], WCHCommands.writeConfig) // 0xa8
        XCTAssertEqual(bytes[1], 0x0E) // length low (14 bytes: 2 mask + 12 config)
        XCTAssertEqual(bytes[2], 0x00) // length high
        XCTAssertEqual(bytes[3], WCHConstants.cfgMaskRDPRUserDataWPR) // bitmask
        XCTAssertEqual(bytes[4], 0x00)
        // Config data follows
        XCTAssertEqual(bytes[5], 0xA5) // RDPR
        XCTAssertEqual(bytes[6], 0x5A) // RDPR complement
    }

    // MARK: - IspEnd Command Tests

    func testIspEndCommandEncoding() {
        // Test IspEnd command (0xA2) used for reset
        let cmd = WCHCommand.ispEnd(reason: 1)
        let bytes = cmd.toRawBytes()

        XCTAssertEqual(bytes[0], WCHCommands.ispEnd) // 0xa2
        XCTAssertEqual(bytes[1], 0x01) // length
        XCTAssertEqual(bytes[2], 0x00)
        XCTAssertEqual(bytes[3], 0x01) // reason (1 = reset to user code)
    }

    // MARK: - Config Value Tests

    func testProtectionConfigValues() {
        // Test that we use correct RDPR values for protection states
        let unprotectedRDPR: UInt8 = 0xA5
        let unprotectedComplement: UInt8 = 0x5A
        let protectedRDPR: UInt8 = 0xFF
        let protectedComplement: UInt8 = 0x00

        // Verify complement relationship (bitwise NOT)
        XCTAssertEqual(~unprotectedRDPR, unprotectedComplement)
        XCTAssertEqual(~protectedRDPR, protectedComplement)

        // Verify the values are different
        XCTAssertNotEqual(unprotectedRDPR, protectedRDPR)
    }
}
