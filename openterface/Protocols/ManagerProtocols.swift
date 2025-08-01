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
import AVFoundation
import SwiftUI
import ORSSerial

// MARK: - Audio Device Structure

/// Audio device structure for dropdown selection
struct AudioDevice: Identifiable, Equatable {
    var id: AudioDeviceID { deviceID } // Use deviceID as the id for consistency
    let deviceID: AudioDeviceID
    let name: String
    let isInput: Bool
    
    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        return lhs.deviceID == rhs.deviceID
    }
}

// MARK: - Core Manager Protocols

/// Protocol for video capture and management functionality
protocol VideoManagerProtocol: AnyObject {
    var isVideoGranted: Bool { get }
    var captureSession: AVCaptureSession! { get }
    var dimensions: CMVideoDimensions { get }
    var isVideoConnected: Bool { get }
    var outputDelegate: VideoOutputDelegate? { get }
    
    func checkAuthorization()
    func prepareVideo()
    func startVideoSession()
    func stopVideoSession()
    func setupSession()
    func addInput(_ input: AVCaptureInput)
    func matchesLocalID(_ uniqueID: String, _ locationID: String) -> Bool
}

/// Protocol for HID device communication and hardware control
protocol HIDManagerProtocol: AnyObject {
    var device: IOHIDDevice? { get }
    var isOpen: Bool? { get }
    
    func startHID()
    func closeHID()
    func startCommunication()
    func stopAllHIDOperations()
    func restartHIDOperations()
    
    func getResolution() -> (width: Int, height: Int)?
    func getFps() -> Float?
    func getSwitchStatus() -> Bool
    func getHDMIStatus() -> Bool
    func getHardwareConnetionStatus() -> Bool
    func getVersion() -> String?
    
    func setUSBtoHost()
    func setUSBtoTarget()
    
    func writeEeprom(address: UInt16, data: Data) -> Bool
    func writeEeprom(address: UInt16, data: Data, progressCallback: ((Double) -> Void)?) -> Bool
    func readEeprom(address: UInt16, length: UInt8) -> Data?
    
    // MARK: - HAL Integration Methods (Optional - with default implementations)
    func getHALVideoSignalStatus() -> VideoSignalStatus?
    func getHALVideoTimingInfo() -> VideoTimingInfo?
    func halSupportsHIDFeature(_ feature: String) -> Bool
    func getHALHIDCapabilities() -> [String]
    func initializeHALAwareHID() -> Bool
    func getHALSystemInfo() -> String
}

/// Protocol for serial port communication
protocol SerialPortManagerProtocol: AnyObject {
    var isDeviceReady: Bool { get set }
    var baudrate: Int { get }
    var serialPort: ORSSerialPort? { get }
    
    func tryOpenSerialPort(priorityBaudrate: Int)
    func tryOpenSerialPortForCH32V208()
    func closeSerialPort()
    func sendCommand(command: [UInt8], force: Bool)
    
    func getChipParameterCfg()
    func resetHidChip()
    func getHidInfo()
    
    // DTR/RTS control methods
    func setDTR(_ enabled: Bool)
    func lowerDTR()
    func raiseDTR()
    func setRTS(_ enabled: Bool)
    func lowerRTS()
    func raiseRTS()
}

/// Protocol for audio streaming and management
protocol AudioManagerProtocol: AnyObject {
    var isAudioDeviceConnected: Bool { get }
    var isAudioPlaying: Bool { get }
    var statusMessage: String { get }
    var microphonePermissionGranted: Bool { get }
    var showingPermissionAlert: Bool { get }
    
    // Separate input and output device management
    var availableInputDevices: [AudioDevice] { get }
    var availableOutputDevices: [AudioDevice] { get }
    var selectedInputDevice: AudioDevice? { get }
    var selectedOutputDevice: AudioDevice? { get }
    var isAudioEnabled: Bool { get }
    
    
    func initializeAudio()
    func checkMicrophonePermission()
    func prepareAudio()
    func startAudioSession()
    func stopAudioSession()
    func setAudioEnabled(_ enabled: Bool)
    func openSystemPreferences()
    func updateAvailableAudioDevices()
    
    // New device selection methods
    func selectInputDevice(_ device: AudioDevice)
    func selectOutputDevice(_ device: AudioDevice)
}

/// Protocol for USB device enumeration and management
protocol USBDevicesManagerProtocol: AnyObject {
    func update()
    func isOpenterfaceConnected() -> Bool
    func isCH9329Connected() -> Bool
    func isCH32V208Connected() -> Bool
    func getExpectedSerialDevicePath() -> String?
    func getDeviceGroupsInfo() -> [String]
}

/// Protocol for firmware update operations
protocol FirmwareManagerProtocol: AnyObject {
    var isUpdating: Bool { get }
    var updateProgress: Double { get }
    var statusMessage: String { get }
    
    func updateFirmware(from url: URL) async throws
    func validateFirmware(_ data: Data) throws -> Bool
    func writeFirmwareToDevice(_ data: Data) async throws -> Bool
    func stopAllOperations()
    func restartOperations()
}

/// Protocol for status bar integration
protocol StatusBarManagerProtocol: AnyObject {
    func setupStatusBar()
    func updateStatusBar()
    func removeStatusBar()
}

/// Protocol for logging functionality
protocol LoggerProtocol: AnyObject {
    var SerialDataPrint: Bool { get set }
    var MouseEventPrint: Bool { get set }
    var logToFile: Bool { get set }
    
    func log(content: String)
    func setLogLevel(_ level: LogLevel)
    func clearLogs()
    
    // File logging methods
    func writeLogFile(string: String)
    func closeLogFile()
    func openLogFile()
    func checkLogFileExist() -> Bool
    func createLogFile()
}

/// Protocol for keyboard management
protocol KeyboardManagerProtocol: AnyObject {
    func sendKeyboardInput(_ input: KeyboardInput)
    func sendSpecialKey(_ key: SpecialKey)
    func executeKeyboardMacro(_ macro: KeyboardMacro)
    func sendTextToKeyboard(text: String)
    func releaseAllModifierKeysForPaste()
}

/// Protocol for mouse management
protocol MouseManagerProtocol: AnyObject {
    func sendMouseInput(_ input: MouseInput)
    func setMouseMode(_ mode: MouseMode)
    func forceStopAllMouseLoops()
    func testMouseMonitor()
    func getMouseLoopRunning() -> Bool
    func stopMouseLoop()
    func runMouseLoop()
}

/// Protocol for host system integration
protocol HostManagerProtocol: AnyObject {
    func setupHostIntegration()
    func handleHostEvents()
    func cleanupHostIntegration()
    func handleKeyboardEvent(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, isKeyDown: Bool)
    func handleRelativeMouseAction(dx: Int, dy: Int, mouseEvent: UInt8, wheelMovement: Int, dragged: Bool)
    func handleAbsoluteMouseAction(x: Int, y: Int, mouseEvent: UInt8, wheelMovement: Int)
    func moveToAppCenter()
}

/// Protocol for tip layer management and on-screen notifications
protocol TipLayerManagerProtocol: AnyObject {
    func showTip(text: String, yOffset: CGFloat, window: NSWindow?)
}

/// Protocol for floating keyboard window management
protocol FloatingKeyboardManagerProtocol: AnyObject {
    func showFloatingKeysWindow()
    func closeFloatingKeysWindow()
}

/// Protocol for OCR (Optical Character Recognition) functionality
protocol OCRManagerProtocol: AnyObject {
    func performOCR(on image: CGImage, completion: @escaping (OCRResult) -> Void)
    func performOCR(on rect: NSRect?, completion: @escaping (OCRResult) -> Void)
    func captureScreenArea(_ rect: NSRect?) -> NSImage?
    func performOCROnSelectedArea(completion: @escaping (OCRResult) -> Void)
    func handleAreaSelectionComplete()
    func startAreaSelection()
    func cancelAreaSelection()
    var isAreaSelectionActive: Bool { get }
}

/// Protocol for clipboard content management and history tracking
protocol ClipboardManagerProtocol: AnyObject {
    var currentClipboardContent: String? { get }
    var clipboardHistory: [ClipboardItem] { get }
    
    func startMonitoring()
    func stopMonitoring()
    func addToHistory(_ content: String)
    func clearHistory()
    func copyToClipboard(_ content: String)
    func handlePasteRequest()
    func handlePasteRequest(with content: String)
}

/// Protocol for camera and video recording functionality
protocol CameraManagerProtocol: AnyObject {
    var isRecording: Bool { get }
    var canTakePicture: Bool { get }
    var statusMessage: String { get }
    
    func takePicture()
    func startVideoRecording()
    func stopVideoRecording()
    func getRecordingDuration() -> TimeInterval
    func getSavedFilesDirectory() -> URL?
    func updateStatus()
}

// MARK: - Supporting Types

enum LogLevel {
    case debug, info, warning, error
}

enum MouseMode {
    case absolute, relative
}

struct KeyboardInput {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
}

struct MouseInput {
    let x: CGFloat
    let y: CGFloat
    let buttons: MouseButtons
}

struct MouseButtons {
    let left: Bool
    let right: Bool
    let middle: Bool
}

struct SpecialKey {
    let keyCode: UInt16
    let name: String
}

struct KeyboardMacro {
    let name: String
    let sequence: [KeyboardInput]
}

// MARK: - OCR Supporting Types

enum OCRResult {
    case success(String)
    case noTextFound
    case failed(Error)
}
