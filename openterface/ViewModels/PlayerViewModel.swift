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
import AVFoundation
import Combine
import CoreAudio


class PlayerViewModel: NSObject, ObservableObject {

    @Published var isVideoGranted: Bool = false
    @Published var isAudioGranted: Bool = false
    @Published var dimensions = CMVideoDimensions()
    
    var audioDeviceId:AudioDeviceID? = nil
    
    var captureSession: AVCaptureSession!
    private var engine: AVAudioEngine!
    private var cancellables = Set<AnyCancellable>()
    // 添加变量保存监听器ID
    private var audioPropertyListenerID: AudioObjectPropertyListenerBlock?
    
    var hasObserverBeenAdded = false
    
    override init() {
        captureSession = AVCaptureSession()
        engine = AVAudioEngine()
        super.init()
        self.setupBindings()

        setupSession()
        
        if AppStatus.isFristRun == false {
            // Add observe event
            self.observeDeviceNotifications()
            
            AppStatus.isFristRun = true
        }
        
    }

    func startAudioSession(){
        stopAudioSession()
        
        // Get the input node (microphone)
        let inputNode = engine.inputNode
        self.audioDeviceId = getAudioDeviceByName(name: "OpenterfaceA")
        if self.audioDeviceId == nil {
            return
        }
        let outputNode = engine.outputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        var address = AudioObjectPropertyAddress(
          mSelector: kAudioHardwarePropertyDefaultInputDevice,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectSetPropertyData(
          AudioObjectID(kAudioObjectSystemObject),
          &address,
          0,
          nil,
          UInt32(MemoryLayout<AudioDeviceID>.size),
          &audioDeviceId
        )
        
        engine.connect(inputNode, to: outputNode, format: inputFormat)
        
        do {
            try engine.start()
        } catch {
            Logger.shared.log(content: "Error starting AVAudioEngine: \(error)")
        }
    }
    
    func getAudioDeviceByName(name: String) -> AudioDeviceID? {
        var propSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var result = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize)
        guard result == noErr else {
            Logger.shared.log(content: "Error \(result) in AudioObjectGetPropertyDataSize")
            return nil
        }

        let deviceCount = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array<AudioDeviceID>(repeating: 0, count: deviceCount)

        result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &deviceIDs)
        guard result == noErr else {
            Logger.shared.log(content: "Error \(result) in AudioObjectGetPropertyData")
            return nil
        }

        for deviceID in deviceIDs {
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            result = AudioObjectGetPropertyDataSize(deviceID, &nameAddress, 0, nil, &nameSize)
            guard result == noErr else {
                Logger.shared.log(content: "Error \(result) in AudioObjectGetPropertyDataSize")
                continue
            }

            var deviceName: Unmanaged<CFString>?
            result = AudioObjectGetPropertyData(
                deviceID,
                &nameAddress,
                0,
                nil,
                &nameSize,
                &deviceName
            )
            guard result == noErr else {
                Logger.shared.log(content: "Error \(result) in AudioObjectGetPropertyData")
                continue
            }
            
            if let cfString = deviceName?.takeRetainedValue() as String?, cfString == name {
                return deviceID
            }
        }

        return nil
    }

    func setupBindings() {
        $isVideoGranted
            .sink { [weak self] isVideoGranted in
                if isVideoGranted {
                    self?.prepareVideo()
                } else {
                    self?.stopVideoSession()
                }
            }
            .store(in: &cancellables)
        
        $isAudioGranted
            .sink { [weak self] isAudioGranted in
                if isAudioGranted {
                    self?.prepareAudio()
                } else {
                    self?.stopAudioSession()
                }
            }
            .store(in: &cancellables)
    }
    
    func setupSession() {
        let videoDataOutput = AVCaptureVideoDataOutput()
        if captureSession.canAddOutput(videoDataOutput) {
            captureSession.addOutput(videoDataOutput)
        }

        let audioDataOutput = AVCaptureAudioDataOutput()
        if captureSession.canAddOutput(audioDataOutput) {
            captureSession.addOutput(audioDataOutput)
        }
    }

    func checkAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: // The user has previously granted access to the camera.
                self.isVideoGranted = true

            case .notDetermined: // The user has not yet been asked for camera access.
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    if granted {
                        DispatchQueue.main.async {
                            self?.isVideoGranted = granted
                        }
                    }
                }
            case .denied: // The user has previously denied access.
                alertToEncourageCameraAccessInitially()
                self.isVideoGranted = false
                // exit application
                // NSApplication.shared.terminate(self)
                // exit(0)
                return

            case .restricted: // The user can't grant access due to restrictions.
                self.isVideoGranted = false
                return
        @unknown default:
            fatalError()
        }

        // Check audio permission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: // The user has previously granted access to the camera.
            self.isAudioGranted = true
            
        case .notDetermined: // The user has not yet been asked for camera access.
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        self?.isAudioGranted = granted
                    }
                }
            }
        case .denied: // The user has previously denied access.
            alertToEncourageCameraAccessInitially()
            self.isAudioGranted = false
            // exit application
            // NSApplication.shared.terminate(self)
            // exit(0)
            return
            
        case .restricted: // The user can't grant access due to restrictions.
            self.isAudioGranted = false
            return
        @unknown default:
            fatalError()
        }
    }
    
    func alertToEncourageCameraAccessInitially() {
        let alert = NSAlert()
        alert.messageText = "Camera Access Required"
        alert.informativeText = "⚠️This application does not have permission to access your camera.\n\nYou can enable it in \"System Preferences\" -> \"Privacy\" -> \"Camera\"."
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .warning
        alert.runModal()
    }

    func startVideoSession() {
        Logger.shared.log(content: "Start video session...")
        guard !captureSession.isRunning else { return }
        captureSession.startRunning()
    }

    func stopVideoSession() {
        guard captureSession.isRunning else { return }
        captureSession.stopRunning()
        AppStatus.isHDMIConnected = false
    }
    
    func stopAudioSession() {
        // 先检查引擎是否运行
        if engine.isRunning {
            engine.stop()
            
            // 断开所有连接
            let inputNode = engine.inputNode
            let outputNode = engine.outputNode
            engine.disconnectNodeOutput(inputNode)
        }
        
        self.audioDeviceId = nil
    }
    
    func prepareVideo() {
        
        if #available(macOS 12.0, *) {
            USBDeivcesManager.shared.update()
        } else {
            Logger.shared.log(content: "Warning: USB device management requires macOS 12.0 or later. Current device status cannot be updated.")
        }
        
        captureSession.sessionPreset = .high // A preset value that indicates the quality level or bit rate of the output.
        // get devices
        let videioDeviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera,
                                                         .externalUnknown]
        let videoDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: videioDeviceTypes,
                                                                mediaType: .video,
                                                                position: .unspecified)
                                                             
        var videoDevices = [AVCaptureDevice]()
        // Add only specified input device
        for device in videoDiscoverySession.devices {
            // 0x
            if let _v = AppStatus.DefaultVideoDevice {
                if(matchesLocalID(device.uniqueID, _v.locationID)){
                    videoDevices.append(device)
                    AppStatus.isMatchVideoDevice = true
                }
            }
        }

        if videoDevices.count > 0 {
            do {
                let input = try AVCaptureDeviceInput(device:videoDevices[0])
                addInput(input)
            }
            catch {
                Logger.shared.log(content: "Something went wrong - " + error.localizedDescription)
            }
            // Get the Camera video resolution
            let formatDescription = videoDevices[0].activeFormat.formatDescription
            dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            AppStatus.videoDimensions.width = CGFloat(dimensions.width)
            AppStatus.videoDimensions.height = CGFloat(dimensions.height)
            // Logger.shared.log(content: "Resolution: \(dimensions.width) x \(dimensions.height)")
 
            startVideoSession()
            AppStatus.isHDMIConnected = true
        }
    }
    
    func matchesLocalID(_ uniqueID: String, _ locationID: String) -> Bool {
        func hexToInt64(_ hex: String) -> UInt64 {
            return UInt64(hex.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
        }

        let uniqueIDValue = hexToInt64(uniqueID)
        
        let locationIDValue = hexToInt64(locationID)
        
        let maskedUniqueID = uniqueIDValue >> 32
        
        if(maskedUniqueID == locationIDValue) {
            return true
        } else {
            return false
        }
    }

    func prepareAudio() {
        if self.audioDeviceId != nil {
            return
        }
        Logger.shared.log(content: "Prepare audio ...")
        
        let audioDeviceTypes: [AVCaptureDevice.DeviceType] = [.builtInMicrophone,
                                                         .externalUnknown]
        let audioDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: audioDeviceTypes,
                                                                mediaType: .audio,
                                                                position: .unspecified)
        var audioDevices = [AVCaptureDevice]()
        // Add only specified input device
        for device in audioDiscoverySession.devices {
            // 0x
            if device.uniqueID.contains(AppStatus.DefaultVideoDevice?.locationID ?? "nil"), !audioDevices.contains(where: { $0.localizedName == device.localizedName }) {
                audioDevices.append(device)
            }
        }

        self.audioDeviceId = getAudioDeviceByName(name: "OpenterfaceA")
        if self.audioDeviceId == nil {
            return
        }
        
        if audioDevices.count > 0 {
            do {
                let input = try AVCaptureDeviceInput(device:audioDevices[0])
                addInput(input)
            }
            catch {
                Logger.shared.log(content: "Something went wrong - " + error.localizedDescription)
            }
        }
        
        if self.audioDeviceId != nil {
            startAudioSession()
        }
    }

    func addInput(_ input: AVCaptureInput) {
        guard captureSession.canAddInput(input) == true else {
            return
        }
        captureSession.addInput(input)
    }
    
    func observeDeviceNotifications() {
        let playViewNtf = NotificationCenter.default
        
        guard !hasObserverBeenAdded else { return }
        
        // get video source event
        playViewNtf.addObserver(self, selector: #selector(videoWasConnected), name: .AVCaptureDeviceWasConnected, object: nil)
        playViewNtf.addObserver(self, selector: #selector(videoWasDisconnected), name: .AVCaptureDeviceWasDisconnected, object: nil)
        
        // focus windows event
        playViewNtf.addObserver(self, selector: #selector(windowDidBecomeMain(_:)), name: NSWindow.didBecomeMainNotification, object: nil)
        playViewNtf.addObserver(self, selector: #selector(windowdidResignMain(_:)), name: NSWindow.didResignMainNotification, object: nil)
        
        // observer full Screen Nootification
        // playViewNtf.addObserver(self, selector: #selector(handleDidEnterFullScreenNotification(_:)), name: NSWindow.didEnterFullScreenNotification, object: nil)
        
        self.hasObserverBeenAdded = true
        // Handle audio device disconnected
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
       let result = AudioObjectAddPropertyListenerBlock(
           AudioObjectID(kAudioObjectSystemObject),
           &propertyAddress,
           nil,
           { (numberAddresses, addresses) in

               if self.getAudioDeviceByName(name: "OpenterfaceA") == nil {
                   Logger.shared.log(content: "Audio device disconnected.")
                   self.stopAudioSession()
               } else {
                   Logger.shared.log(content: "Audio device connected.")
                   self.prepareAudio()
               }
           }
       )

       if result != kAudioHardwareNoError {
           Logger.shared.log(content: "Error adding property listener: \(result)")
       }
    }
    
    deinit {
        let playViewNtf = NotificationCenter.default
        playViewNtf.removeObserver(self, name: .AVCaptureDeviceWasConnected, object: nil)
        
        // 停止音频引擎
        stopAudioSession()
        
        // 移除音频属性监听器
        if let listenerID = audioPropertyListenerID {
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                nil,
                listenerID
            )
        }
    }

    @objc func handleDidEnterFullScreenNotification(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window.styleMask.contains(.fullScreen) {
                Logger.shared.log(content: "The window just entered full screen mode.")
            } else {
                Logger.shared.log(content: "The window just exited full screen mode.")
            }
        }
    }
    
    @objc func windowDidBecomeMain(_ notification: Notification) {
        if UserSettings.shared.MouseControl == MouseControlMode.relative && AppStatus.isExit == false {
            NSCursor.hide()
            AppStatus.isCursorHidden = true
        }
        AppStatus.isFouceWindow = true
    }
    
    @objc func windowdidResignMain(_ notification: Notification) {
        AppStatus.isFouceWindow = false
        AppStatus.isMouseInView = false
        if let handler = AppStatus.eventHandler {
            Logger.shared.log(content: "removeMonitor handler")
            NSEvent.removeMonitor(handler)
            AppStatus.eventHandler = nil
        }
        // NSCursor.unhide()
    }

    @objc func videoWasConnected(notification: NSNotification) {
        if #available(macOS 12.0, *) {
           USBDeivcesManager.shared.update()
        }

        
        if let _v = AppStatus.DefaultVideoDevice, let device = notification.object as? AVCaptureDevice, matchesLocalID(device.uniqueID, _v.locationID) {
            let hid = HIDManager.shared
            self.prepareVideo()
            hid.startHID()
        }
    }
    
    @objc func videoWasDisconnected(notification: NSNotification) {
        if let _v = AppStatus.DefaultVideoDevice, let device = notification.object as? AVCaptureDevice, matchesLocalID(device.uniqueID, _v.locationID) {
            self.stopVideoSession()
            
            // Remove all existing video input
            let videoInputs = self.captureSession.inputs.filter { $0 is AVCaptureDeviceInput }
            videoInputs.forEach { self.captureSession.removeInput($0) }
            self.captureSession.commitConfiguration()
            
            let hid = HIDManager.shared
            hid.closeHID()
        }
            
        if #available(macOS 12.0, *) {
           USBDeivcesManager.shared.update()
        }
    }
}
