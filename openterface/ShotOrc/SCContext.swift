//
//  SCContext.swift
//  openterface
//
//  Created by Shawn Ling on 2024/5/23.
//


import SwiftUI
import ScreenCaptureKit
import AVFAudio
import AVFoundation

class SCContext {
    static var audioSettings: [String : Any]! // 用于存储音频录制设置的字典，比如采样率和通道数。
    static var isPaused = false // 一个布尔变量，表示录制是否被暂停。
    static var isResume = false // 一个布尔变量，表示录制是否处于继续(从暂停状态恢复)状态。
    static var lastPTS: CMTime?
    static var timeOffset = CMTimeMake(value: 0, timescale: 0) // 表示录制时的时间偏移，类型为 CMTime。
    static var screenArea: NSRect? // 表示要捕获的屏幕区域的矩形，为可选 NSRect 类型。
    static let audioEngine = AVAudioEngine() // 一个 AVAudioEngine 实例，用于管理和处理音频。
    static var backgroundColor: CGColor = CGColor.black // 录制过程中使用的背景颜色，默认为黑色。
    static var recordMic = false // 一个布尔变量，指示是否应该记录麦克风的音频。
    static var filePath: String!  // - 录制文件的存储路径。
    static var audioFile: AVAudioFile? // 存储音频录制数据的文件。
    static var vW: AVAssetWriter! // 用于写入视频数据到文件的 AVAssetWriter 实例。
    static var vwInput, awInput, micInput: AVAssetWriterInput!  // - 分别用于视频、音频、以及麦克风输入的 AVAssetWriterInput 实例。
    static var startTime: Date? // 表示录制开始的时间。
    static var timePassed: TimeInterval = 0 //  记录从录制开始到现在的经过时间。
    static var stream: SCStream! // - 表示一个屏幕捕获流实例。
    static var screen: SCDisplay?  //  - 可能用于表示要捕获的特定屏幕。
    static var window: [SCWindow]? // - 表示要捕获的特定窗口数组。
    static var application: [SCRunningApplication]?  // - 表示要捕获的特定应用程序数组。
    static var availableContent: SCShareableContent? // 表示可以捕获的内容，如屏幕、窗口等。
    
    //  一个数组，包含了在录制时应该被排除的应用程序的包名。这用于过滤那些不希望被录制的应用程序。
    static let excludedApps = ["", "com.apple.dock", "com.apple.screencaptureui", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.WindowManager", "dev.mnpn.Azayaka", "com.gaosun.eul", "com.pointum.hazeover", "net.matthewpalmer.Vanilla", "com.dwarvesv.minimalbar", "com.bjango.istatmenus.status"]
    
    static func getScreenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        let screenWithMouse = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
        return screenWithMouse
    }
    
    static func updateAvailableContent(completion: @escaping () -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            if let error = error {
                switch error {
                case SCStreamError.userDeclined: requestPermissions()
                default: print("Error: failed to fetch available content: ".local, error.localizedDescription)
                }
                return
            }
            availableContent = content
            assert(availableContent?.displays.isEmpty != nil, "There needs to be at least one display connected!".local)
            completion()
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
