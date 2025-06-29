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
import CoreAudio
import Combine

// Audio management class
class AudioManager: ObservableObject {
    // Published properties for UI status display
    @Published var isAudioDeviceConnected: Bool = false
    @Published var isAudioPlaying: Bool = false
    @Published var statusMessage: String = "Checking audio devices..."
    @Published var microphonePermissionGranted: Bool = false
    @Published var showingPermissionAlert: Bool = false
    
    // Singleton instance
    static let shared = AudioManager()
    
    // Audio engine
    private var engine: AVAudioEngine!
    // Audio device ID
    private var audioDeviceId: AudioDeviceID? = nil
    // Cancellable storage
    private var cancellables = Set<AnyCancellable>()
    // Audio property listener ID
    private var audioPropertyListenerID: AudioObjectPropertyListenerBlock?
    // Flag to control auto-start behavior
    private var autoStartEnabled: Bool = false
    
    init() {
        engine = AVAudioEngine()
        
        // Ensure not to automatically check microphone permission and start audio at initialization, wait for external explicit call
        // Ensure the app appears in the permission list
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }
    
    deinit {
        stopAudioSession()
        cleanupListeners()
    }
    
    // Explicitly separate initialization and audio check, requiring external call
    func initializeAudio() {
        // Check microphone permission first
        checkMicrophonePermission()
    }
    
    // Check microphone permission
    func checkMicrophonePermission() {
        // Create a temporary AVCaptureDevice session to trigger permission request
        // _ = AVCaptureSession()
        
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            // Already have permission, can proceed
            self.microphonePermissionGranted = true
            DispatchQueue.main.async {
                self.statusMessage = "Microphone permission granted"
            }
            setupAudioDeviceChangeListener()
            if autoStartEnabled {
                prepareAudio()
            }
            
        case .notDetermined:
            // Haven't requested permission yet, need to request
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.microphonePermissionGranted = true
                        self?.statusMessage = "Microphone permission granted"
                        self?.setupAudioDeviceChangeListener()
                        if self?.autoStartEnabled == true {
                            self?.prepareAudio()
                        }
                    } else {
                        self?.microphonePermissionGranted = false
                        self?.statusMessage = "Microphone permission needed to play audio"
                        self?.showingPermissionAlert = true
                    }
                }
            }
            
        case .denied, .restricted:
            // Permission denied or restricted
            self.microphonePermissionGranted = false
            DispatchQueue.main.async {
                self.statusMessage = "Microphone permission needed to play audio"
                self.showingPermissionAlert = true
            }
            
        @unknown default:
            break
        }
    }
    
    // Open system preferences
    func openSystemPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // Prepare audio processing
    func prepareAudio() {
        // Don't proceed without microphone permission
        if !microphonePermissionGranted {
            DispatchQueue.main.async {
                self.statusMessage = "Microphone permission needed to play audio"
                self.showingPermissionAlert = true
            }
            return
        }
        
        DispatchQueue.main.async {
            self.statusMessage = "Searching for audio devices..."
        }
        
        if self.audioDeviceId != nil {
            return
        }
        
        // Search for audio devices with a slight delay to ensure device initialization
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            
            self.audioDeviceId = self.getAudioDeviceByName(name: "OpenterfaceA")
            if self.audioDeviceId == nil {
                DispatchQueue.main.async {
                    self.statusMessage = "Audio device 'OpenterfaceA' not found"
                    self.isAudioDeviceConnected = false
                }
                return
            }
            
            DispatchQueue.main.async {
                self.statusMessage = "Audio device 'OpenterfaceA' found"
                self.isAudioDeviceConnected = true
            }
            
            // Only start audio session if auto-start is enabled
            if self.autoStartEnabled {
                // If device ID is found, start audio session
                self.startAudioSession()
            }
        }
    }
    
    // Start audio session
    func startAudioSession() {
        stopAudioSession()
        
        // Recreate audio engine to avoid potential state reuse issues
        engine = AVAudioEngine()
        
        // Add delay to ensure device is fully initialized
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            
            do {
                // Get input node (microphone)
                let inputNode = self.engine.inputNode
                self.audioDeviceId = self.getAudioDeviceByName(name: "OpenterfaceA")
                if self.audioDeviceId == nil {
                    DispatchQueue.main.async {
                        self.statusMessage = "Cannot access audio device"
                        self.isAudioPlaying = false
                    }
                    return
                }
                
                let outputNode = self.engine.outputNode
                let inputFormat = inputNode.outputFormat(forBus: 0)
                let outputFormat = outputNode.inputFormat(forBus: 0)
                
                // Check and adapt sample rate
                let format = self.createCompatibleAudioFormat(inputFormat: inputFormat, outputFormat: outputFormat)

                // Set audio device as default input device
                self.setDefaultAudioInputDevice()
                
                // Connect nodes using compatible format
                try self.engine.connect(inputNode, to: outputNode, format: format)
                
                try self.engine.start()
                DispatchQueue.main.async {
                    self.statusMessage = "Audio playing..."
                    self.isAudioPlaying = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Error starting audio: \(error.localizedDescription)"
                    self.isAudioPlaying = false
                }
                self.stopAudioSession()
            }
        }
    }
    
    // Stop audio session
    func stopAudioSession() {

        // Check if engine is running
        if engine.isRunning {
            // Log the operation
            Logger.shared.log(content: "Engine is running, stopping...")
            
            // Stop engine first to avoid errors when disconnecting
            engine.stop()
            
            // Disconnect all connections
            let inputNode = engine.inputNode
            engine.disconnectNodeOutput(inputNode)
            
            // Reset engine
            engine.reset()
            
            Logger.shared.log(content: "Audio engine stopped and reset")
        } else {
            Logger.shared.log(content: "Audio engine not running, no need to stop")
        }
        
        // Reset audio device ID
        self.audioDeviceId = nil
        
        // Update UI status
        DispatchQueue.main.async {
            self.statusMessage = "Audio stopped"
            self.isAudioPlaying = false
        }
    }
    
    // Create compatible audio format
    private func createCompatibleAudioFormat(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) -> AVAudioFormat {
        var format = inputFormat
        
        if inputFormat.sampleRate != outputFormat.sampleRate {
            // Create new format with matching sample rate
            format = AVAudioFormat(
                commonFormat: inputFormat.commonFormat,
                sampleRate: outputFormat.sampleRate,
                channels: inputFormat.channelCount,
                interleaved: inputFormat.isInterleaved) ?? outputFormat
        }
        
        return format
    }
    
    // Set current audio device as default input device
    private func setDefaultAudioInputDevice() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        _ = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &self.audioDeviceId
        )
    }
    
    // Get audio device by name
    func getAudioDeviceByName(name: String) -> AudioDeviceID? {
        var propSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Get property data size
        var result = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propSize
        )
        
        guard result == noErr else {
            return nil
        }

        // Calculate device count and prepare array
        let deviceCount = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array<AudioDeviceID>(repeating: 0, count: deviceCount)

        // Get device IDs
        result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propSize,
            &deviceIDs
        )
        
        guard result == noErr else {
            return nil
        }

        // Search for device with matching name
        for deviceID in deviceIDs {
            let deviceName = getAudioDeviceName(for: deviceID)
            
            if deviceName == name {
                return deviceID
            }
        }

        return nil
    }
    
    // Get audio device name
    private func getAudioDeviceName(for deviceID: AudioDeviceID) -> String? {
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Get size of name property
        let result = AudioObjectGetPropertyDataSize(
            deviceID,
            &nameAddress,
            0,
            nil,
            &nameSize
        )
        
        guard result == noErr else {
            return nil
        }

        // Get device name
        var deviceName: Unmanaged<CFString>?
        let nameResult = AudioObjectGetPropertyData(
            deviceID,
            &nameAddress,
            0,
            nil,
            &nameSize,
            &deviceName
        )
        
        guard nameResult == noErr else {
            return nil
        }
        
        return deviceName?.takeRetainedValue() as String?
    }
    
    // Set up audio device change listener
    private func setupAudioDeviceChangeListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // Save listener ID for later removal
        self.audioPropertyListenerID = { (numberAddresses, addresses) in
            DispatchQueue.main.async {
                if self.getAudioDeviceByName(name: "OpenterfaceA") == nil {
                    DispatchQueue.main.async {
                        self.statusMessage = "Audio device disconnected"
                        self.isAudioDeviceConnected = false
                    }
                    self.stopAudioSession()
                } else {
                    DispatchQueue.main.async {
                        self.statusMessage = "Audio device connected"
                        self.isAudioDeviceConnected = true
                    }
                    // Ensure complete stop before preparing new audio session
                    self.stopAudioSession()
                    // Only auto-start if feature is enabled
                    if self.autoStartEnabled {
                        // Slight delay before preparing audio to ensure device stability
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.prepareAudio()
                        }
                    }
                }
            }
        }
        
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            nil,
            self.audioPropertyListenerID!
        )
    }
    
    // Clean up all listeners
    private func cleanupListeners() {
        // Remove audio property listener
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
            audioPropertyListenerID = nil
        }
    }
    
    // Set audio enabled
    func setAudioEnabled(_ enabled: Bool) {
        // Update auto-start flag
        self.autoStartEnabled = enabled
        Logger.shared.log(content: "Audio auto-start set to: \(enabled)")
        
        if enabled {
            // If we're enabling audio, start it
            Logger.shared.log(content: "Starting audio session explicitly")
            // First ensure the device is discovered
            let deviceID = getAudioDeviceByName(name: "OpenterfaceA")
            if deviceID != nil {
                self.audioDeviceId = deviceID
                // If the device exists, start the session directly
                startAudioSession()
            } else {
                // If the device does not exist, attempt to initialize the audio process
                Logger.shared.log(content: "Audio device not found, attempting to initialize")
                prepareAudio()
            }
        } else {
            // If we're disabling audio, stop it
            Logger.shared.log(content: "Stopping audio session explicitly")
            stopAudioSession()
        }
    }
}
