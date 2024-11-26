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
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif
import AVFAudio
import AVFoundation

@available(macOS 12.3, *)
class SCContext {
    static var audioSettings: [String : Any]!
    static var isPaused = false // A boolean variable indicating whether the recording is paused.
    static var isResume = false // A boolean variable indicating whether the recording is resumed (from a paused state).
    static var lastPTS: CMTime?
    static var timeOffset = CMTimeMake(value: 0, timescale: 0) // The time offset during recording, of type CMTime.
    static var screenArea: NSRect? // The rectangle representing the screen area to be captured, optional NSRect type.
    static let audioEngine = AVAudioEngine() // An AVAudioEngine instance for managing and processing audio.
    static var backgroundColor: CGColor = CGColor.black // The background color used during recording, default is black.
    static var recordMic = false // A boolean variable indicating whether the microphone audio should be recorded.
    static var filePath: String! // The storage path of the recording file.
    static var audioFile: AVAudioFile? // The file storing audio recording data.
    static var vW: AVAssetWriter! // An AVAssetWriter instance for writing video data to a file.
    static var vwInput, awInput, micInput: AVAssetWriterInput! // AVAssetWriterInput instances for video, audio, and microphone input respectively.
    static var startTime: Date? // The start time of the recording.
    static var timePassed: TimeInterval = 0 // The elapsed time from the start of the recording to now.
    static var stream: SCStream! // Represents a screen capture stream instance.
    static var screen: SCDisplay? // May represent a specific screen to be captured.
    static var window: [SCWindow]? // Represents an array of specific windows to be captured.
    static var application: [SCRunningApplication]? // Represents an array of specific applications to be captured.
    static var availableContent: SCShareableContent? // Represents the content available for capture, such as screens, windows, etc.
    
    //  An array containing the bundle identifiers of applications that should be excluded during recording. This is used to filter out applications that should not be recorded.
    static let excludedApps = ["", "com.apple.dock", "com.apple.screencaptureui", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.WindowManager", "dev.mnpn.Azayaka", "com.gaosun.eul", "com.pointum.hazeover", "net.matthewpalmer.Vanilla", "com.dwarvesv.minimalbar", "com.bjango.istatmenus.status"]
    
    static func getScreenWithMouse() -> NSScreen? {
        if #available(macOS 12.3, *) {
            let mouseLocation = NSEvent.mouseLocation
            let screenWithMouse = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            return screenWithMouse
        } else {
            // Handle older macOS versions
            // Provide fallback mechanism or user instructions here.
            Logger.shared.log(content: "ScreenCaptureKit requires macOS 12.3 or later. Current functionality is limited.")
            return nil
        }
    }
    
    static func updateAvailableContent(completion: @escaping () -> Void) {
        if #available(macOS 12.3, *) {
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
                if let error = error {
                    switch error {
                    case SCStreamError.userDeclined: requestPermissions()
                    default: Logger.shared.log(content: "Failed to fetch available screen content for capture. Error: \(error.localizedDescription)")
                    }
                    return
                }
                availableContent = content
                assert(availableContent?.displays.isEmpty != nil, "There needs to be at least one display connected!".local)
                completion()
            }
        }
    }
    
    private static func requestPermissions() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Permission Required".local
            alert.informativeText = "QuickRecorder needs screen recording permissions, even if you only intend on recording audio.".local
            alert.addButton(withTitle: "Open Settings".local)
            alert.addButton(withTitle: "Quit".local)
            alert.alertStyle = .critical
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            NSApp.terminate(self)
        }
    }
}

extension String {
    var local: String { return NSLocalizedString(self, comment: "") }
}
