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
    private var lastHIDInfoCheckTime: Date?
    private var hasObservedOpenSerialPort = false
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

    override func deinitialize() {
        stopCTSMonitoring()
        super.deinitialize()
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
        startCTSMonitoring()

//        // Check if communication was established
//        currentBaudRate = serialManager.baudrate
//        
//        if currentBaudRate > 0 {
//           // Check if the keyboard and mouse are connected
//           if let status = serialManager.getTargetConnectionStatusSync() {
//               self.isConnected = status.isKeyboardConnected || status.isMouseConnected
//           }
//        }
        return true
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
        return startCTSMonitoring()
    }

    override func getVersion() -> String? {
        // CH9329 reports version through chip parameter configuration
        serialManager.getChipParameterCfg()
        return "CH9329-v\(AppStatus.chipVersion)"
    }

    // MARK: - CH9329 Specific Methods

    private func startCTSMonitoring() -> Bool {
        guard USBDevicesManager.shared.isCH9329Connected() else {
            logger.log(content: "Skipping CTS monitoring - only applicable to CH9329 chipset")
            return false
        }

        guard ctsMonitoringTimer == nil else {
            return true
        }

        ctsMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkCTSState()
        }

        logger.log(content: "Started CTS monitoring for CH9329 HID event detection")
        return true
    }

    private func stopCTSMonitoring() {
        ctsMonitoringTimer?.invalidate()
        ctsMonitoringTimer = nil
        lastCTSState = nil
        lastHIDInfoCheckTime = nil
        hasObservedOpenSerialPort = false
    }

    private func checkCTSState() {
        guard USBDevicesManager.shared.isCH9329Connected() else {
            stopCTSMonitoring()
            return
        }

        guard let serialPort = serialManager.serialPort, serialPort.isOpen else {
            if hasObservedOpenSerialPort {
                stopCTSMonitoring()
            }
            return
        }

        hasObservedOpenSerialPort = true

        let currentCTS = serialPort.cts

        if lastCTSState == nil {
            lastCTSState = currentCTS
            lastHIDInfoCheckTime = Date()
            checkHIDEventTime()
            return
        }

        if lastCTSState != currentCTS {
            AppStatus.isKeyboardConnected = true
            AppStatus.isMouseConnected = true
            SerialPortStatus.shared.isKeyboardConnected = true
            SerialPortStatus.shared.isMouseConnected = true
            isConnected = true
            lastCTSState = currentCTS
            lastCTSUpdateTime = Date()
            lastHIDInfoCheckTime = Date()
        }

        checkHIDEventTime()
    }

    private func checkHIDEventTime() {
        guard let lastCheckTime = lastHIDInfoCheckTime else { return }

        // Treat any recent CH9329 serial response as healthy activity, even if CTS did not toggle.
        if let lastSerialDate = serialManager.lastSerialDate,
           Date().timeIntervalSince(lastSerialDate) <= 5 {
            lastHIDInfoCheckTime = max(lastCheckTime, lastSerialDate)
            return
        }

        if Date().timeIntervalSince(lastCheckTime) > 5 {
            if logger.SerialDataPrint {
                logger.log(content: "No hid update more than 5s, do a heartbeat check by requesting hid info")
            }
            lastHIDInfoCheckTime = Date()
            serialManager.getHidInfo()
        }
    }

    override func getDeviceStatus() -> ControlDeviceStatus {
        let baseStatus = super.getDeviceStatus()

        var isTargetConnected = baseStatus.isTargetConnected

        if let lastTime = lastCTSUpdateTime, Date().timeIntervalSince(lastTime) <= 2.0 {
            isTargetConnected = true
            isConnected = true
        } else {
            isTargetConnected = false
            isConnected = false
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
