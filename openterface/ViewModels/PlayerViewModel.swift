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

    override init() {
        captureSession = AVCaptureSession()
        engine = AVAudioEngine()
        super.init()
        self.setupBindings()

        setupSession()
        // Add observe event
        self.observeDeviceNotifications()
    }

    func startAudioSession(){
        // 获取输入节点（麦克风）
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
            var nameSize: UInt32 = 0
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

            var deviceName: CFString = "" as CFString
            result = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &deviceName)
            guard result == noErr else {
                Logger.shared.log(content: "Error \(result) in AudioObjectGetPropertyData")
                continue
            }

            if deviceName as String == name {
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
                    self?.stopAuidoSession()
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
        alert.messageText = "需要摄像头访问权限"
        alert.informativeText = "⚠️此应用没有权限访问您的摄像头，\n\n您可以在\"系统偏好设置\"->\"隐私\"->\"摄像头\"中打开。"
        alert.addButton(withTitle: "确定")
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
    
    func stopAuidoSession() {
        self.audioDeviceId = nil
        self.engine.stop()
    }
    
    func prepareVideo() {

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
            if(device.localizedName == "Openterface" ){
                videoDevices.append(device)
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
            if device.localizedName == "OpenterfaceA", !audioDevices.contains(where: { $0.localizedName == device.localizedName }) {
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
        
        // get video source event
        playViewNtf.addObserver(self, selector: #selector(videoWasConnected), name: .AVCaptureDeviceWasConnected, object: nil)
        playViewNtf.addObserver(self, selector: #selector(videoWasDisconnected), name: .AVCaptureDeviceWasDisconnected, object: nil)
        
        // focus windows event
        playViewNtf.addObserver(self, selector: #selector(windowDidBecomeMain(_:)), name: NSWindow.didBecomeMainNotification, object: nil)
        playViewNtf.addObserver(self, selector: #selector(windowdidResignMain(_:)), name: NSWindow.didResignMainNotification, object: nil)
        
        // observer full Screen Nootification
        // playViewNtf.addObserver(self, selector: #selector(handleDidEnterFullScreenNotification(_:)), name: NSWindow.didEnterFullScreenNotification, object: nil)
        
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
                   self.stopAuidoSession()
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
    
    // 通知处理方法
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
        if let handler = AppStatus.evnHandler {
            Logger.shared.log(content: "removeMonitor handler")
            NSEvent.removeMonitor(handler)
            AppStatus.evnHandler = nil
        }
        // NSCursor.unhide()
    }

    @objc func videoWasConnected(notification: NSNotification) {
        if let device = notification.object as? AVCaptureDevice, device.localizedName == "Openterface" {
            prepareVideo()
            captureSession.commitConfiguration()
        }
    }
    
    @objc func videoWasDisconnected(notification: NSNotification) {
        if let device = notification.object as? AVCaptureDevice, device.localizedName == "Openterface" {
            stopVideoSession()
            
            // Remove all existing video input
            let videoInputs = captureSession.inputs.filter { $0 is AVCaptureDeviceInput }
            videoInputs.forEach { captureSession.removeInput($0) }
            captureSession.commitConfiguration()
        }
    }
}
