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
import ORSSerial

// MARK: - CH9329 Control Chipset Implementation

class CH9329ControlChipset: BaseControlChipset {
    private static let VENDOR_ID = 0x1A86
    private static let PRODUCT_ID = 0x7523

    private var lastCTSState: Bool?
    private var lastCTSUpdateTime: Date?
    private var ctsMonitoringTimer: Timer?

    init?() {
        let info = ChipsetInfo(
            name: "CH9329",
            vendorID: CH9329ControlChipset.VENDOR_ID,
            productID: CH9329ControlChipset.PRODUCT_ID,
            firmwareVersion: nil,
            manufacturer: "WCH",
            chipsetType: .control(.ch9329)
        )

        let capabilities = ChipsetCapabilities(
            supportsHDMI: false,
            supportsAudio: false,
            supportsHID: true,
            supportsFirmwareUpdate: false,
            supportsEEPROM: false,
            maxDataTransferRate: 115200,
            features: ["Serial Communication", "HID Events", "CTS Monitoring", "Baudrate Detection"]
        )

        super.init(chipsetInfo: info, capabilities: capabilities)
    }

    override var communicationInterface: CommunicationInterface {
        return .serial(baudRate: currentBaudRate)
    }

    override var supportedBaudRates: [Int] {
        return [BaseControlChipset.LOWSPEED_BAUDRATE, BaseControlChipset.HIGHSPEED_BAUDRATE]
    }

    override func initialize() -> Bool {
        guard detectDevice() else {
            logger.log(content: "❌ CH9329 device not detected")
            return false
        }

        if establishCommunication() {
            isConnected = true
            startCTSMonitoring()
            logger.log(content: "✅ CH9329 chipset initialized successfully")
            return true
        }

        logger.log(content: "❌ CH9329 chipset initialization failed")
        return false
    }

    override func deinitialize() {
        stopCTSMonitoring()
        super.deinitialize()
    }

    override func detectDevice() -> Bool {
        // Check if CH9329 device is connected via USB manager
        for device in AppStatus.USBDevices {
            if device.vendorID == CH9329ControlChipset.VENDOR_ID &&
               device.productID == CH9329ControlChipset.PRODUCT_ID {
                logger.log(content: "🔍 CH9329 device detected: \(device.productName)")
                return true
            }
        }

        return false
    }

    override func validateConnection() -> Bool {
        // Validate by sending a parameter configuration request
        serialManager.getChipParameterCfg()

        // Connection validation is handled asynchronously by the serial manager
        return true
    }

    override func establishCommunication() -> Bool {
        // CH9329 requires baudrate detection and validation
        serialManager.tryOpenSerialPort()

        // Check if communication was established
        currentBaudRate = serialManager.baudrate
        
        if currentBaudRate > 0 {
            logger.log(content: "✅ CH9329 communication established at \(currentBaudRate) baud")
            // Trigger HAL integration with managers after successful communication
            HALIntegrationManager.shared.reintegrateControlChipset()
            return true
        } else {
            logger.log(content: "❌ CH9329 communication establishment failed. Baudrate: \(currentBaudRate)")
            return false
        }
    }

    override func configureDevice(baudRate: Int, mode: UInt8) -> Bool {
        // CH9329-specific configuration command
        // Command format: [0x57, 0xAB, 0x00, 0x09, 0x32, mode, baudrate_bytes..., checksum]
        var command: [UInt8] = [0x57, 0xAB, 0x00, 0x09, 0x32, mode]

        // Add baudrate bytes (big-endian format)
        let baudRateBytes = withUnsafeBytes(of: UInt32(baudRate).bigEndian) { Array($0) }
        command.append(contentsOf: baudRateBytes)

        // Add remaining configuration bytes
        command.append(contentsOf: [0x01, 0xC2, 0x00])

        // Add padding to reach the expected command length
        while command.count < 32 {
            command.append(0x00)
        }

        return sendAsyncCommand(command, force: true)
    }

    override func monitorHIDEvents() -> Bool {
        // CH9329 uses CTS monitoring for HID event detection
        return startCTSMonitoring()
    }

    override func getVersion() -> String? {
        // CH9329 reports version through chip parameter configuration
        serialManager.getChipParameterCfg()
        return "CH9329-v\(AppStatus.chipVersion)"
    }

    // MARK: - CH9329 Specific Methods

    private func startCTSMonitoring() -> Bool {
        guard ctsMonitoringTimer == nil else {
            return true // Already monitoring
        }

        ctsMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkCTSState()
        }

        logger.log(content: "🔄 Started CTS monitoring for CH9329 HID event detection")
        return true
    }

    private func stopCTSMonitoring() {
        ctsMonitoringTimer?.invalidate()
        ctsMonitoringTimer = nil
        logger.log(content: "⏹️ Stopped CTS monitoring for CH9329")
    }

    private func checkCTSState() {
        guard let serialPort = serialManager.serialPort else { return }

        let currentCTS = serialPort.cts

        if lastCTSState == nil {
            lastCTSState = currentCTS
            return
        }

        if lastCTSState != currentCTS {
            // CTS state changed - indicates HID activity
            AppStatus.isKeyboardConnected = true
            AppStatus.isMouseConnected = true
            lastCTSState = currentCTS
            lastCTSUpdateTime = Date()

            logger.log(content: "📡 CH9329 HID activity detected via CTS change")
        }
    }

    override func getDeviceStatus() -> ControlDeviceStatus {
        let baseStatus = super.getDeviceStatus()

        var isTargetConnected = baseStatus.isTargetConnected

        // For MS2109, check if CTS was updated within 2 seconds
        if let lastTime = lastCTSUpdateTime, Date().timeIntervalSince(lastTime) <= 2.0 {
            isTargetConnected = true
        } else {
            isTargetConnected = false
        }

        return ControlDeviceStatus(
            isTargetConnected: isTargetConnected,
            isKeyboardConnected: baseStatus.isKeyboardConnected,
            isMouseConnected: baseStatus.isMouseConnected,
            lockStates: baseStatus.lockStates,
            chipVersion: baseStatus.chipVersion,
            communicationQuality: baseStatus.communicationQuality,
            lastResponseTime: baseStatus.lastResponseTime
        )
    }
}
