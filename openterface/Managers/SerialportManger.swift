/*
* ========================================================================== *
*                                                                            *
*    This file is part of the Openterface Mini KVM                           *
*                                                                            *
*    Copyright (C) 2024   <info@openterface.com>                             *
*                                                                            *
*    This program is free software: you can redistribute it and/or modify    *
*    it under the terms of the GNU General Public License as published by    *
*    the Free Software Foundation, either version 3 of the License, or       *
*    (at your option) any later version.                                     *
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
    }

    
    func initializeSerialPort(){
        DispatchQueue.global(qos: .background).async {
            while !self.ready {
                // try DEFAULT_BAUDRATE first
                if self.selectedSerialPort != nil {
                    self.closeSerialPort()
                }   
                self.openSerialPort(name: "usbserial", baudrate: SerialPortManager.DEFAULT_BAUDRATE)
                self.sendCommand(command: SerialPortManager.CMD_GET_PARA_CFG, force: true)
                usleep(1000000) // sleep 1s

                if self.ready { break }
                // try ORIGINAL_BAUDRATE
                self.closeSerialPort()
                self.openSerialPort(name: "usbserial", baudrate: SerialPortManager.ORIGINAL_BAUDRATE)
                self.sendCommand(command: SerialPortManager.CMD_GET_PARA_CFG, force: true)
                usleep(1000000) // sleep 1s
                self.closeSerialPort()
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
            case 0x88:
                // get para cfg
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
                } 
                else {
                    Logger.shared.log(content: "Reset to baudrate 115200 and mode 0x82...")
                    // set baudrate to 115200 and mode 1
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
                    self.sendCommand(command: SerialPortManager.CMD_RESET, force: true)
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
             case 0x84, 0x85:
                if Logger.shared.SerialDataPrint {
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
                    let dateString = dateFormatter.string(from: Date())
                    Logger.shared.log(content: "[\(dateString) \(cmd == 0x84 ? "Abslote" : "Relative") mouse event sent, status: \(dataBytes[5])")
                }
                break
            default:
                Logger.shared.log(content: "Unknown command: \(cmd)")
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
        self.serialPorts = ORSSPM.availablePorts // Get the list of available serial ports
        self.selectedSerialPort = self.serialPorts.filter{ $0.path.contains(name)}.first
        
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
        if Logger.shared.SerialDataPrint { Logger.shared.log(content: "[\(Date())] Sent data: \(dataString)") }
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
}
