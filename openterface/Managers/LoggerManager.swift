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

class Logger {
    static let shared = Logger()
    
    var isPrintEnabled = false
    var KeyboardPrint = true
    var MouseEventPrint = false
    var ScrollPrint = false
    var SerialDataPrint = true
    
    var logToFile = false
    
    var isLogFileOpen: Bool = false
    var fileHandle: FileHandle?
    let fileManager = FileManager.default
    private let _logFileName = AppStatus.logFileName

    init() {
        
    }
    
    
    //Create log file
    func createLogFile() {
        if let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let infoFilePath = documentsDirectory.appendingPathComponent(_logFileName)
            
            // Create Info Log File if it doesn't exist
            if !fileManager.fileExists(atPath: infoFilePath.path) {
                fileManager.createFile(atPath: infoFilePath.path, contents: nil, attributes: nil)
            }
        }
    }
    
    func checkLogFileExist() -> Bool {
        if let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let infoFilePath = documentsDirectory.appendingPathComponent(_logFileName)
            
            // Create Info Log File if it doesn't exist
            if !fileManager.fileExists(atPath: infoFilePath.path) {
                return false
            } else {
                return true
            }
        } else {
            return false
        }
    }
    
    //open log file
    func openLogFile(){
        if isLogFileOpen == false, let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let infoFilePath = documentsDirectory.appendingPathComponent(_logFileName)
            
            // must be make sure file is exist
            if let _fileHandle = try? FileHandle(forWritingTo: infoFilePath) {
                fileHandle = _fileHandle
                isLogFileOpen = true
            }
        }
    }
    
    //close log file
    func closeLogFile() {
        fileHandle?.closeFile()
        isLogFileOpen = false
    }
    
    func log(content: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let dateString = dateFormatter.string(from: Date())
                            
        print("[\(dateString)] " + content);
        if(logToFile){
            writeLogFile(string: content)
        }
    }
    
    // write append log
    func writeLogFile(string: String) {
        if isLogFileOpen {
            if fileHandle != nil {
                // set the end position
                fileHandle?.seekToEndOfFile()
                // Convert the string to NSData and append it to the file
                let logMessage = formattedMessage(message: string)
                if let data = logMessage.data(using: .utf8) {
                    fileHandle?.write(data)
                }
            }
        }
    }
    
    private func formattedMessage(message: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = dateFormatter.string(from: Date())
        return "\(timestamp): \(message)\n"
    }
}
