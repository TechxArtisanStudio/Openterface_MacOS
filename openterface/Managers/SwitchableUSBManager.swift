import Foundation

final class SwitchableUSBManager: NSObject, SwitchableUSBManagerProtocol {
    static let shared = SwitchableUSBManager()

    private let logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    private let hidManager: HIDManagerProtocol = DependencyContainer.shared.resolve(HIDManagerProtocol.self)
    private let serialPortManager: SerialPortManagerProtocol = DependencyContainer.shared.resolve(SerialPortManagerProtocol.self)

    private override init() {
        super.init()
    }

    func toggleUSB(toTarget: Bool) {
        logger.log(content: "🔄 SwitchableUSBManager: toggleUSB called: \(toTarget ? "Target" : "Host")")

        if toTarget {
            logger.log(content: "SwitchableUSBManager: Setting USB to Target")
            hidManager.setUSBtoTarget()
        } else {
            logger.log(content: "SwitchableUSBManager: Setting USB to Host")
            hidManager.setUSBtoHost()
        }

        // Update global app status
        AppStatus.switchToTarget = toTarget
        logger.log(content: "SwitchableUSBManager: Updated AppStatus.switchToTarget to: \(toTarget)")

        // Apply DTR pulse for MS2109 chipset only
        // For CH32V208, use serial commands to switch SD card direction
        if AppStatus.controlChipsetType == .ch32v208 {
            let ser = serialPortManager
            if toTarget {
                logger.log(content: "SwitchableUSBManager: CH32V208 - setting SD to TARGET via serial")
                ser.setSdToTarget(force: true) { success in
                    if success {
                        AppStatus.sdCardDirection = .target
                        self.logger.log(content: "SwitchableUSBManager: CH32V208 SD set to TARGET")
                    } else {
                        self.logger.log(content: "SwitchableUSBManager: Failed to set CH32V208 SD to TARGET")
                    }
                }
            } else {
                logger.log(content: "SwitchableUSBManager: CH32V208 - setting SD to HOST via serial")
                ser.setSdToHost(force: true) { success in
                    if success {
                        AppStatus.sdCardDirection = .host
                        self.logger.log(content: "SwitchableUSBManager: CH32V208 SD set to HOST")
                    } else {
                        self.logger.log(content: "SwitchableUSBManager: Failed to set CH32V208 SD to HOST")
                    }
                }
            }
        } else if AppStatus.videoChipsetType == .ms2109 {
            // Apply DTR pulse for MS2109 chipset only
            let ser = serialPortManager
            logger.log(content: "SwitchableUSBManager: Raising DTR signal")
            ser.raiseDTR()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.logger.log(content: "SwitchableUSBManager: Lowering DTR signal")
                ser.lowerDTR()
            }
        } else {
            logger.log(content: "SwitchableUSBManager: Skipping DTR signal for non-MS2109 and non-CH32V208 chipset")
        }
    }
}
