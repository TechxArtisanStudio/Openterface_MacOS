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

import SwiftUI
import Foundation
import ORSSerial
import os.log

class SerialPortManager: NSObject, ORSSerialPortDelegate {
    static let shared = SerialPortManager()
    
    public static var MOUSE_ABS_ACTION_PREFIX: [UInt8] = [0x57, 0xAB, 0x00, 0x04, 0x07, 0x02]
    public static var MOUSE_REL_ACTION_PREFIX: [UInt8] = [0x57, 0xAB, 0x00, 0x05, 0x05, 0x01]
    public static let CMD_GET_HID_INFO: [UInt8] = [0x57, 0xAB, 0x00, 0x01, 0x00]
    public static let CMD_GET_PARA_CFG: [UInt8] = [0x57, 0xAB, 0x00, 0x08, 0x00]
    public static let CMD_RESET: [UInt8] = [0x57, 0xAB, 0x00, 0x0F, 0x00]
    
    public static let ORIGINAL_BAUDRATE:Int = 9600
    public static let DEFAULT_BAUDRATE:Int = 115200
    
    @objc let serialPortManager = ORSSerialPortManager.shared()
    @objc dynamic var serialPort: ORSSerialPort? {
        didSet {
            oldValue?.close()
            oldValue?.delegate = nil
            serialPort?.delegate = self
        }
    }
    
    let ORSSPM = ORSSerialPortManager.shared()
    @Published var serialFile: Int32 = 0
    
    @Published var selectedSerialPort: ORSSerialPort?
    @Published var serialPorts : [ORSSerialPort] = []
    
    var lastHIDEventTime: Date?
    var lastCts:Bool?
    var timer:Timer?
    
    var baudrate:Int = 0
    public var ready:Bool = false
    
    override init(){
        super.init()
        
        // Initialise the serial port
        self.initializeSerialPort()

        observerSerialPortNotifications()
    }
    
    private func observerSerialPortNotifications() {
        let serialPortNtf = NotificationCenter.default
        
        serialPortNtf.addObserver(self, selector: #selector(serialPortsWereConnected(_:)), name: NSNotification.Name.ORSSerialPortsWereConnected, object: nil)
        serialPortNtf.addObserver(self, selector: #selector(serialPortsWereDisconnected(_:)), name: NSNotification.Name.ORSSerialPortsWereDisconnected, object: nil)
    }
    
    @objc func serialPortsWereConnected(_ notification: Notification) {
        Logger.shared.log(content: "Serial port Connected")
        self.initializeSerialPort()
    }
    
    @objc func serialPortsWereDisconnected(_ notification: Notification) {
        Logger.shared.log(content: "Serial port Disconnected")
        self.closeSerialPort()
        AppStatus.isTargetConnected = false
        AppStatus.isKeyboardConnected = false
        AppStatus.isMouseConnected = false
    }

    
    func initializeSerialPort(){
        DispatchQueue.global(qos: .background).async {
            while !self.ready {
                // try DEFAULT_BAUDRATE first
                if self.selectedSerialPort != nil {
                    self.closeSerialPort()
                }   
                self.openSerialPort(name: "usbserial", baudrate: SerialPortManager.DEFAULT_BAUDRATE)
                self.getHidParameterCfg()
                usleep(1000000) // sleep 1s

                if self.ready { break }
                // try ORIGINAL_BAUDRATE
                self.closeSerialPort()
                self.openSerialPort(name: "usbserial", baudrate: SerialPortManager.ORIGINAL_BAUDRATE)
                self.getHidParameterCfg()
                usleep(1000000) // sleep 1s
                self.closeSerialPort()
            }
        }     
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval:0.5, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if self.ready {
                    // To check any HID events send to target computer
                    self.checkCTS()
                }
            }
        }
    }

    func checkCTS() {
        if let cts = self.serialPort?.cts {
            if lastCts == nil {
                lastCts = cts
                lastHIDEventTime = Date()
            }
            if lastCts != cts {
                AppStatus.isKeyboardConnected = true
                AppStatus.isMouseConnected = true
                lastHIDEventTime = Date()
                lastCts = cts
            }
        }
        
        self.checkHIDEventTime()
    }

    func checkHIDEventTime() {
        if let lastTime = lastHIDEventTime {
            if Date().timeIntervalSince(lastTime) > 5 {

                // 5 seconds pass since last HID event
                if Logger.shared.SerialDataPrint {
                    Logger.shared.log(content: "No hid update more than 5 second, check the HID information")
                }
                // Rest the time, to avoide duplicated check
                Logger.shared.log(content: "Has lastHIDEventTime")
                lastHIDEventTime = Date()
                getHidInfo()
            }
        }
    }

    func serialPortWasOpened(_ serialPort: ORSSerialPort) {
        if Logger.shared.SerialDataPrint { Logger.shared.log(content: "Serial opened") }
    }
    
    func serialPortWasClosed(_ serialPort: ORSSerialPort) {
        if Logger.shared.SerialDataPrint { Logger.shared.log(content: "Serial port was closed") }
    }
    
    /*
     * Receive data from serial
     */
    func serialPort(_ serialPort: ORSSerialPort, didReceive data: Data) {
        if Logger.shared.SerialDataPrint {
            let dataString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            Logger.shared.log(content: "Serial port receive data: \(dataString)")
        }
        // handle bytes data with prefix 57 AB 00
        let prefix: [UInt8] = [0x57, 0xAB, 0x00]
        let dataBytes = [UInt8](data)
        if dataBytes.starts(with: prefix) {
            // get check the following bytes
            let cmd = dataBytes[3]
            let len = dataBytes[4]
            switch cmd {
            case 0x81:  // HID info
                /*
                Once the k/m usb port is connected the target computer, the HID
                chip will automatically send the HID info to the host. 
                */
                var chipVersion: Int8 = 0
                if dataBytes.count > 5 {
                    let byteValue = dataBytes[5]
                    chipVersion = Int8(bitPattern: byteValue)
                    AppStatus.chipVersion = Int8(chipVersion)
                } else {
                    Logger.shared.log(content: "chipVersion data is invalid")
                }

                let isTargetConnected = dataBytes[6] == 0x01
                AppStatus.isTargetConnected = isTargetConnected
                
                AppStatus.isKeyboardConnected = isTargetConnected
                AppStatus.isMouseConnected = isTargetConnected

                // The fist byte of the data is the status of the NumLock
                let isNumLockOn = (dataBytes[7] & 0x01) == 0x01
                AppStatus.isNumLockOn = isNumLockOn

                // The seconde byte of the data is the status of the CapLock
                let isCapLockOn = (dataBytes[7] & 0x02) == 0x02
                AppStatus.isCapLockOn = isCapLockOn

                // The third byte of the data is the status of the Scroll
                let isScrollOn = (dataBytes[7] & 0x04) == 0x04
                AppStatus.isScrollOn = isScrollOn
                Logger.shared.log(content: "Receive HID info, chip version: \(chipVersion), target connected: \(isTargetConnected), NumLock: \(isNumLockOn), CapLock: \(isCapLockOn), Scroll: \(isScrollOn)")
                break
            case 0x82:  //Keyboard hid execution status 0 - success
                let kbStatus = dataBytes[5]
                if Logger.shared.SerialDataPrint  {
                    Logger.shared.log(content: "Receive keyboard status: \(String(format: "0x%02X", kbStatus))")
                }

                break
            case 0x83:  //multimedia data hid execution status 0 - success
                if Logger.shared.SerialDataPrint  {
                    let kbStatus = dataBytes[5]
                    Logger.shared.log(content: "Receive multi-meida status: \(String(format: "0x%02X", kbStatus))")
                }
                break
            case 0x84, 0x85:  //Mouse hid execution status 0 - success
                let kbStatus = dataBytes[5]
                if Logger.shared.SerialDataPrint {
                   Logger.shared.log(content: "\(cmd == 0x84 ? "Absolute" : "Relative") mouse event sent, status: \(String(format: "0x%02X", kbStatus))")
                }
                break
            case 0x86, 0x87:  //custom hid execution status 0 - success
                if Logger.shared.SerialDataPrint  {
                    let kbStatus = dataBytes[5]
                    Logger.shared.log(content: "Receive \(cmd == 0x86 ? "SEND" : "READ") custom hid status: \(String(format: "0x%02X", kbStatus))")
                }
                break
            case 0x88:  // get para cfg
                let baudrateData = Data(dataBytes[8...11])
                let mode = dataBytes[5]
                let baudrateInt32 = baudrateData.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> Int32 in
                    let intPointer = pointer.bindMemory(to: Int32.self)
                    return intPointer[0].bigEndian
                }
                self.baudrate = Int(baudrateInt32)
                Logger.shared.log(content: "Current serial port baudrate: \(self.baudrate), Mode: \(String(format: "%02X", mode))")
                if self.baudrate == SerialPortManager.DEFAULT_BAUDRATE && mode == 0x82 {
                    self.ready = true
                    
                    self.getHidInfo()
                }
                else {
                    Logger.shared.log(content: "Reset to baudrate 115200 and mode 0x82...")
                    // set baudrate to 115200 and mode 2
                    var command: [UInt8] = [0x57, 0xAB, 0x00, 0x09, 0x32, 0x82, 0x80, 0x00, 0x00, 0x01, 0xC2, 0x00]
                    command.append(contentsOf: dataBytes[12...31])
                    // append zero to the end
                    for _ in 0...22 {
                        command.append(0x00)
                    }
                    self.sendCommand(command: command, force: true)
                    do {
                        usleep(500000)
                    }
                    Logger.shared.log(content:"Reset chipset now...")
                    self.resetHidChip()
                    self.baudrate = SerialPortManager.DEFAULT_BAUDRATE
                    do {
                        usleep(1000000)
                    }
                    closeSerialPort()
                    do {
                        usleep(1000000)
                    }
                    openSerialPort(name: "usbserial", baudrate: SerialPortManager.DEFAULT_BAUDRATE)
                }
                break
            case 0x89:  // set para cfg
                if Logger.shared.SerialDataPrint {
                    let status = dataBytes[5]
                    Logger.shared.log(content: "Set para cfg status: \(String(format: "0x%02X", status))")
                }
                break
            default:
                let hexCmd = String(format: "%02hhX", cmd)
                Logger.shared.log(content: "Unknown command: \(hexCmd)")
            }
        } else {
            Logger.shared.log(content: "Data does not start with the correct prefix")
        }
    }
    
    func serialPortWasRemovedFromSystem(_ serialPort: ORSSerialPort) {
        self.selectedSerialPort = nil
    }
    
    func serialPort(_ serialPort: ORSSerialPort, didEncounterError error: Error) {
        if Logger.shared.SerialDataPrint { Logger.shared.log(content: "SerialPort \(serialPort) encountered an error: \(error)") }
    }

    func listSerialPorts() -> [ORSSerialPort] {
        self.serialPorts = ORSSPM.availablePorts
        return self.serialPorts
    }
    
    func openSerialPort(name: String, baudrate: Int) {
        // 获取当前可用的串行端口
        guard let availablePorts = ORSSerialPortManager.shared().availablePorts as? [ORSSerialPort], !availablePorts.isEmpty else {
            Logger.shared.log(content: "No available serial ports found")
            return
        }

        self.serialPorts = availablePorts // Get the list of available serial ports
        
        // 打印调试信息
        Logger.shared.log(content: "Available Ports: \(self.serialPorts)")
        Logger.shared.log(content: "Looking for port with name: \(name)")
        
        // 使用过滤器查找名称匹配的端口
        guard let selectedPort = self.serialPorts.first(where: { $0.path.contains(name) }) else {
            Logger.shared.log(content: "No matching serial port found with name: \(name)")
            return
        }
        self.selectedSerialPort = selectedPort
        // self.selectedSerialPort = self.serialPorts.filter{ $0.path.contains(name)}.first
        
        self.selectedSerialPort?.baudRate = NSNumber(value: baudrate)
        Logger.shared.log(content: "Try to open serial port: \(self.selectedSerialPort?.name) with baudrate \(baudrate)")
        self.selectedSerialPort?.open()
        
        if self.selectedSerialPort?.isOpen == true {
            // hostConnected
            guard let port = self.selectedSerialPort else {
                if Logger.shared.SerialDataPrint { Logger.shared.log(content: "Serial port not selected") }
                return
            }
            self.serialPort = port
            let path = port.path
            self.serialFile = open(path, O_RDWR | O_NOCTTY | O_NDELAY)
            if self.serialFile == -1 {
                Logger.shared.log(content: "Error: Unable to open port. errno: \(errno) - \(String(cString: strerror(errno)))")
                return
            }
            
            
            var options = termios()
            tcgetattr(self.serialFile, &options)
            cfsetspeed(&options, speed_t(Int32(baudrate)))
            options.c_cflag |= UInt((CLOCAL | CREAD))
            tcsetattr(self.serialFile, TCSANOW, &options)
            
        } else {
            Logger.shared.log(content: "Open serial failure")
        }
    }
    
    func closeSerialPort() {
        if self.serialFile != -1 {
            close(self.serialFile)
            self.serialFile = -1
            self.selectedSerialPort = nil
            self.serialPort = nil
            Logger.shared.log(content: "Serial port closed")
            self.ready = false
        } else {
            Logger.shared.log(content: "Error: Serial port not open")
        }
    }
    
    func writeByte(data: [UInt8]) {
        guard self.selectedSerialPort != nil else {
            Logger.shared.log(content: "Serial port not selected")
            return
        }

        let _ = write(serialFile, data, data.count)
        
        let dataString = data.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
        if Logger.shared.SerialDataPrint { Logger.shared.log(content: "Sent data: \(dataString)") }
    }
    
    func sendCommand(command:[UInt8], force:Bool=false) {
        var mutableCommand = command
        mutableCommand.append(self.calculateChecksum(data: command))
        
        if self.ready || force{
         let _ = self.writeByte(data: mutableCommand)
        }
    }
    
    func calculateChecksum(data: [UInt8]) -> UInt8 {
        return UInt8(data.reduce(0, { (sum, element) in sum + Int(element) }) & 0xFF)
    }

    func getHidParameterCfg(){
        self.sendCommand(command: SerialPortManager.CMD_GET_PARA_CFG, force: true)
    }
    
    func resetHidChip(){
        self.sendCommand(command: SerialPortManager.CMD_RESET, force: true)
    }
    
    func getHidInfo(){
        self.sendCommand(command: SerialPortManager.CMD_GET_HID_INFO)
    }
}
