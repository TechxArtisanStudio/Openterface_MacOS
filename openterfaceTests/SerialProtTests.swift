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

import XCTest
@testable import openterface

final class SerialProtTests: XCTestCase {
    
    var spm:SerialPortManager!
    
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        spm = SerialPortManager()
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // Any test you write for XCTest can be annotated as throws and async.
        // Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
        // Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
        
//        print("=====test go=====")
//        print("list serial ports")
//        let p  = spm.listSerialPorts()
//        print(p)
//        
//        print("open serial")
//        // spm.OpenSerialPort(name: "usbserial-14120", baudrate: 115200)
//        
//        // TODO: -
//        print("send message")
//        
//        var command: [UInt8] = [0x57, 0xAB, 0x00, 0x05, 0x05, 0x01]
//        
//        command.append(0x00)
//        command.append(0x11)
//        command.append(0x71)
//        command.append(0x00) // scroll up 0x01-0x7F; scroll down: 0x81-0xFF
//        command.append(spm.calculateChecksum(data: command))
//        print(command)
//        let _ = spm.writeByte(data: command)
//        Thread.sleep(forTimeInterval: 1)
//        let _ = spm.writeByte(data: command)
//        // TODO: -
//        print("receive message")
    }

//    func testPerformanceExample() throws {
//        // This is an example of a performance test case.
//        self.measure {
//            // Put the code you want to measure the time of here.
//        }
//    }
}
