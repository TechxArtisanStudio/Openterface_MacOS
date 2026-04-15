/*
 * WCH Chip Database - Chip families, variants, config registers
 * Ported from wchisp-mac / WCHISPKit
 */

import Foundation

struct WCHChipFamily: Codable {
    let name: String
    let mcuType: UInt8
    let deviceType: UInt8
    let supportUSB: Bool?
    let supportSerial: Bool?
    let supportNet: Bool?
    let description: String
    let variants: [WCHChip]
    let configRegisters: [WCHConfigRegister]

    enum CodingKeys: String, CodingKey {
        case name, description, variants
        case mcuType = "mcu_type"
        case deviceType = "device_type"
        case supportUSB = "support_usb"
        case supportSerial = "support_serial"
        case supportNet = "support_net"
        case configRegisters = "config_registers"
    }
}

struct WCHChip: Codable {
    let name: String
    var chipID: UInt8
    let altChipIDs: [UInt8]
    var mcuType: UInt8
    var deviceType: UInt8
    let flashSize: UInt32
    let eepromSize: UInt32
    let eepromStartAddr: UInt32
    var supportNet: Bool?
    var supportUSB: Bool?
    var supportSerial: Bool?
    var configRegisters: [WCHConfigRegister]

    enum CodingKeys: String, CodingKey {
        case name
        case chipID = "chip_id"
        case altChipIDs = "alt_chip_ids"
        case mcuType = "mcu_type"
        case deviceType = "device_type"
        case flashSize = "flash_size"
        case eepromSize = "eeprom_size"
        case eepromStartAddr = "eeprom_start_addr"
        case supportNet = "support_net"
        case supportUSB = "support_usb"
        case supportSerial = "support_serial"
        case configRegisters = "config_registers"
    }

    var computedDeviceType: UInt8 { mcuType + 0x10 }
    var minEraseSectorNumber: UInt32 { computedDeviceType == 0x10 ? 4 : 8 }
    var uidSize: Int { computedDeviceType == 0x11 ? 4 : 8 }
    var supportsCodeFlashProtect: Bool {
        [0x14, 0x15, 0x17, 0x18, 0x19, 0x20].contains(computedDeviceType)
    }
}

struct WCHConfigRegister: Codable {
    let offset: Int
    let name: String
    let description: String
    let reset: UInt32?
    let enableDebug: UInt32?
    let explanation: [String: String]
    let fields: [WCHRegisterField]

    enum CodingKeys: String, CodingKey {
        case offset, name, description, reset, explanation, fields
        case enableDebug = "enable_debug"
    }
}

struct WCHRegisterField: Codable {
    let bitRange: [UInt8]
    let name: String
    let description: String
    let explanation: [String: String]

    enum CodingKeys: String, CodingKey {
        case name, description, explanation
        case bitRange = "bit_range"
    }
}

enum WCHChipDBError: Error {
    case deviceTypeNotFound(UInt8)
    case chipNotFound(chipID: UInt8, deviceType: UInt8)
}

class WCHChipDB {
    let families: [WCHChipFamily]

    init(families: [WCHChipFamily]) {
        self.families = families
    }

    static func load() -> WCHChipDB {
        return WCHChipDB(families: buildHardcodedDB())
    }

    func findChip(chipID: UInt8, deviceType: UInt8) throws -> WCHChip {
        guard let family = families.first(where: { $0.deviceType == deviceType }) else {
            throw WCHChipDBError.deviceTypeNotFound(deviceType)
        }
        guard let chip = family.variants.first(where: {
            $0.chipID == chipID || $0.altChipIDs.contains(chipID)
        }) else {
            throw WCHChipDBError.chipNotFound(chipID: chipID, deviceType: deviceType)
        }

        var c = chip
        c.mcuType = family.mcuType
        c.deviceType = family.deviceType
        if chipID != chip.chipID { c.chipID = chipID }
        if c.supportNet == nil    { c.supportNet = family.supportNet }
        if c.supportUSB == nil    { c.supportUSB = family.supportUSB }
        if c.supportSerial == nil { c.supportSerial = family.supportSerial }
        if c.configRegisters.isEmpty { c.configRegisters = family.configRegisters }
        return c
    }
}

private func buildHardcodedDB() -> [WCHChipFamily] {
    let rdprUserField = WCHConfigRegister(
        offset: 0x00,
        name: "RDPR_USER",
        description: "RDPR, nRDPR, USER, nUSER",
        reset: 0x00FF5AA5,
        enableDebug: nil,
        explanation: [:],
        fields: [
            WCHRegisterField(bitRange: [7, 0], name: "RDPR",
                             description: "Read Protection",
                             explanation: ["0xa5": "Unprotected", "_": "Protected"]),
            WCHRegisterField(bitRange: [16, 16], name: "IWDG_SW",
                             description: "Independent watchdog",
                             explanation: ["1": "Enabled by software", "0": "Enabled by hardware"]),
            WCHRegisterField(bitRange: [17, 17], name: "STOP_RST",
                             description: "System reset under stop mode",
                             explanation: ["1": "Disable", "0": "Enable"]),
            WCHRegisterField(bitRange: [18, 18], name: "STANDBY_RST",
                             description: "System reset under standby mode",
                             explanation: ["1": "Disable", "0": "Enable"])
        ]
    )

    let ch32f103Family = WCHChipFamily(
        name: "CH32F103 Series",
        mcuType: 4, deviceType: 0x14,
        supportUSB: true, supportSerial: true, supportNet: false,
        description: "CH32F103 (Cortex-M3) Series",
        variants: [
            WCHChip(name: "CH32F103C8T6", chipID: 0x03, altChipIDs: [],
                    mcuType: 4, deviceType: 0x14,
                    flashSize: 65536, eepromSize: 0, eepromStartAddr: 0,
                    supportNet: false, supportUSB: true, supportSerial: true,
                    configRegisters: [rdprUserField])
        ],
        configRegisters: [rdprUserField]
    )

    let ch32v20xFamily = WCHChipFamily(
        name: "CH32V20x Series",
        mcuType: 9, deviceType: 0x19,
        supportUSB: true, supportSerial: true, supportNet: false,
        description: "CH32V20x (RISC-V4B/V4C) Series",
        variants: [
            WCHChip(name: "CH32V208WBU6", chipID: 0x80, altChipIDs: [],
                    mcuType: 9, deviceType: 0x19,
                    flashSize: 131072, eepromSize: 2048, eepromStartAddr: 0x1C000,
                    supportNet: false, supportUSB: true, supportSerial: true,
                    configRegisters: [rdprUserField]),
            WCHChip(name: "CH32V208RBT6", chipID: 0x81, altChipIDs: [],
                    mcuType: 9, deviceType: 0x19,
                    flashSize: 131072, eepromSize: 2048, eepromStartAddr: 0x1C000,
                    supportNet: false, supportUSB: true, supportSerial: true,
                    configRegisters: [rdprUserField]),
            WCHChip(name: "CH32V208CBU6", chipID: 0x82, altChipIDs: [],
                    mcuType: 9, deviceType: 0x19,
                    flashSize: 131072, eepromSize: 2048, eepromStartAddr: 0x1C000,
                    supportNet: false, supportUSB: true, supportSerial: true,
                    configRegisters: [rdprUserField]),
            WCHChip(name: "CH32V208GBU6", chipID: 0x83, altChipIDs: [],
                    mcuType: 9, deviceType: 0x19,
                    flashSize: 131072, eepromSize: 0, eepromStartAddr: 0x1C000,
                    supportNet: false, supportUSB: true, supportSerial: true,
                    configRegisters: [rdprUserField])
        ],
        configRegisters: [rdprUserField]
    )

    return [ch32f103Family, ch32v20xFamily]
}
