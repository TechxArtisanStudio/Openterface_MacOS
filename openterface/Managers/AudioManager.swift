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
class AudioManager: ObservableObject, AudioManagerProtocol {
    private lazy var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    
    // Published properties for UI status display
    @Published var isAudioDeviceConnected: Bool = false
    @Published var isAudioPlaying: Bool = false
    @Published var statusMessage: String = "Checking audio devices..."
    @Published var microphonePermissionGranted: Bool = false
    @Published var showingPermissionAlert: Bool = false
    
    // Separate input and output device management
    @Published var availableInputDevices: [AudioDevice] = []
    @Published var availableOutputDevices: [AudioDevice] = []
    @Published var selectedInputDevice: AudioDevice?
    @Published var selectedOutputDevice: AudioDevice?
    
    
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
    // Debounce timer for device change listener to prevent rapid re-triggers
    private var deviceChangeDebounceTimer: Timer?
    // Flag to track if listener has been set up to prevent duplicate registrations
    private var isAudioListenerSetup: Bool = false
    // Flag to track if audio has been initialized to prevent duplicate initialization
    private var isAudioInitialized: Bool = false
    
    // Computed property to check if audio is currently enabled
    var isAudioEnabled: Bool {
        return autoStartEnabled
    }
    
    init() {
        engine = AVAudioEngine()
        
        // Ensure not to automatically check microphone permission and start audio at initialization, wait for external explicit call
        // Ensure the app appears in the permission list
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        
        // Load the saved audio enabled state from UserSettings
        self.autoStartEnabled = UserSettings.shared.isAudioEnabled
        
        // Initialize available audio devices and automatically select OpenterfaceA
        updateAvailableAudioDevices()
    }
    
    deinit {
        stopAudioSession()
        deviceChangeDebounceTimer?.invalidate()
        cleanupListeners()
    }
    
    // Explicitly separate initialization and audio check, requiring external call
    func initializeAudio() {
        // Prevent multiple initialization calls
        guard !isAudioInitialized else {
            logger.log(content: "AudioManager: Already initialized, skipping duplicate initialization")
            return
        }
        
        isAudioInitialized = true
        logger.log(content: "AudioManager: Initializing audio system")
        
        // Check microphone permission first
        checkMicrophonePermission()
        
        // If audio was enabled in the previous session, automatically start it
        if autoStartEnabled {
            logger.log(content: "Audio was previously enabled, attempting to start automatically")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.prepareAudio()
            }
        }
    }
    
    // Get all available audio input and output devices
    func updateAvailableAudioDevices() {        
        // Test: Try to get default input device first
        var defaultInputDeviceID: AudioDeviceID = 0
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let defaultResult = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &inputAddress,
            0,
            nil,
            &propertySize,
            &defaultInputDeviceID
        )
        
        if defaultResult == noErr && defaultInputDeviceID != kAudioObjectUnknown {
            if let defaultDeviceName = getAudioDeviceName(for: defaultInputDeviceID) {
                logger.log(content: "AudioManager: Default input device: \(defaultDeviceName) (ID: \(defaultInputDeviceID))")
            }
        } else {
            logger.log(content: "AudioManager: No default input device found or error: \(defaultResult)")
        }
        
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
            logger.log(content: "AudioManager: Failed to get property data size, error: \(result)")
            return
        }

        // Calculate device count and prepare array
        let deviceCount = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array<AudioDeviceID>(repeating: 0, count: deviceCount)
        logger.log(content: "AudioManager: Found \(deviceCount) total audio devices")

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
            logger.log(content: "AudioManager: Failed to get device IDs, error: \(result)")
            return
        }

        var inputDevices: [AudioDevice] = []
        var outputDevices: [AudioDevice] = []
        var openterfaceDevice: AudioDevice? = nil
        
        // Search for input and output devices
        for deviceID in deviceIDs {
            if let deviceName = getAudioDeviceName(for: deviceID) {
                let isInput = isInputDevice(deviceID: deviceID)
                let isOutput = isOutputDevice(deviceID: deviceID)

                if isInput {
                    let audioDevice = AudioDevice(deviceID: deviceID, name: deviceName, isInput: true)
                    if isAggregateDevice(deviceID: deviceID) {
                        continue
                    }
                    inputDevices.append(audioDevice)
                    logger.log(content: "Found input device: \(deviceName)")
                    
                    // Mark OpenterfaceA device for selection
                    if deviceName == "OpenterfaceA" {
                        openterfaceDevice = audioDevice
                        logger.log(content: "AudioManager: OpenterfaceA device found!")
                    }else if deviceName == "USB2 Digital Audio" {
                        openterfaceDevice = audioDevice
                        logger.log(content: "AudioManager: Opeterface KVM Go auddio device found!")
                    }
                }
                
                if isOutput {
                    let audioDevice = AudioDevice(deviceID: deviceID, name: deviceName, isInput: false)
                    if isAggregateDevice(deviceID: deviceID) {
                        continue
                    }
                    outputDevices.append(audioDevice)
                    logger.log(content: "Found output device: \(deviceName)")
                }
            }
        }
        
        logger.log(content: "Total input devices found: \(inputDevices.count)")
        logger.log(content: "Total output devices found: \(outputDevices.count)")

        // Update UI on main queue - both devices list and selection together
        DispatchQueue.main.async {
            self.availableInputDevices = inputDevices
            self.availableOutputDevices = outputDevices
            
            self.logger.log(content: "AudioManager: Updated device arrays")
            
            // Only auto-select OpenterfaceA if no input device is currently selected
            if let openterfaceDevice = openterfaceDevice, self.selectedInputDevice == nil {
                self.selectedInputDevice = openterfaceDevice
                self.logger.log(content: "AudioManager: Auto-selected OpenterfaceA as default audio input")
            }
            
            // Auto-select first available output device if none selected
            if self.selectedOutputDevice == nil && !outputDevices.isEmpty {
                self.selectedOutputDevice = outputDevices.first!
                self.logger.log(content: "AudioManager: Auto-selected first output device: \(outputDevices.first!.name)")
            }
        }
    }
    
    // Check if device is an input device
    private func isInputDevice(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var propSize: UInt32 = 0
        let result = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propSize)
        
        guard result == noErr && propSize > 0 else {
            return false
        }
        
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferList.deallocate() }
        
        let getResult = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propSize, bufferList)
        
        guard getResult == noErr else {
            return false
        }
        
        return bufferList.pointee.mNumberBuffers > 0
    }
    
    // Check if device is an output device
    private func isOutputDevice(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var propSize: UInt32 = 0
        let result = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propSize)
        
        guard result == noErr && propSize > 0 else {
            return false
        }
        
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferList.deallocate() }
        
        let getResult = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propSize, bufferList)
        
        guard getResult == noErr else {
            return false
        }
        
        return bufferList.pointee.mNumberBuffers > 0
    }
    
    // Check if device is an aggregate device
    private func isAggregateDevice(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propSize: UInt32 = 0
        let result = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propSize)
        guard result == noErr && propSize > 0 else {
            return false
        }

        let count = max(1, Int(propSize) / MemoryLayout<AudioClassID>.size)
        let classIDPtr = UnsafeMutablePointer<AudioClassID>.allocate(capacity: count)
        defer { classIDPtr.deallocate() }

        var writablePropSize = propSize
        let getResult = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &writablePropSize, classIDPtr)
        guard getResult == noErr else { return false }

        return classIDPtr.pointee == kAudioAggregateDeviceClassID
    }
    
    // Select an audio device for input
    func selectInputDevice(_ device: AudioDevice) {
        // Find the device in our available devices list to ensure object identity consistency
        guard let existingDevice = availableInputDevices.first(where: { $0.deviceID == device.deviceID }) else {
            logger.log(content: "Device not found in available devices list: \(device.name)")
            return
        }
        
        DispatchQueue.main.async {
            self.selectedInputDevice = existingDevice
        }
        
        // Stop current session if running
        if engine.isRunning {
            stopAudioSession()
        }
        
        // Update the internal device ID
        self.audioDeviceId = device.deviceID
        
        // Restart session if auto-start is enabled
        if autoStartEnabled {
            // Small delay to ensure proper device switching
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.startAudioSession()
            }
        }
        
        logger.log(content: "Audio device selected: \(device.name)")
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
                // Setup listener after permission is confirmed
                self.setupAudioDeviceChangeListener()
                if self.autoStartEnabled {
                    self.prepareAudio()
                }
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
        
        // Update available devices first
        updateAvailableAudioDevices()
        
        if self.audioDeviceId != nil {
            return
        }
        
        // Search for audio devices with a slight delay to ensure device initialization
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            
            // Use selected device if available, otherwise try to find OpenterfaceA
            if let selectedDevice = self.selectedInputDevice {
                self.audioDeviceId = selectedDevice.deviceID
            } else {
                self.audioDeviceId = self.getAudioDeviceByNames(names: ["OpenterfaceA", "USB2 Digital Audio"])
            }
            
            if self.audioDeviceId == nil {
                DispatchQueue.main.async {
                    self.statusMessage = "No suitable audio device found"
                    self.isAudioDeviceConnected = false
                }
                return
            }
            
            let deviceName = self.selectedInputDevice?.name ?? "OpenterfaceA"
            DispatchQueue.main.async {
                self.statusMessage = "Audio device '\(deviceName)' found"
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
                let outputNode = self.engine.outputNode
                
                // Use the currently selected device or fall back to OpenterfaceA
                if self.audioDeviceId == nil {
                    if let selectedDevice = self.selectedInputDevice {
                        self.audioDeviceId = selectedDevice.deviceID
                    } else {
                        self.audioDeviceId = self.getAudioDeviceByNames(names: ["OpenterfaceA", "USB2 Digital Audio"])
                    }
                }
                
                if self.audioDeviceId == nil {
                    DispatchQueue.main.async {
                        self.statusMessage = "Cannot access audio device"
                        self.isAudioPlaying = false
                    }
                    return
                }
                
                // Set audio device as default input device before getting formats
                self.setDefaultAudioInputDevice()
                
                // Get formats after setting device
                let inputFormat = inputNode.outputFormat(forBus: 0)
                let outputFormat = outputNode.inputFormat(forBus: 0)
                
                // Validate formats
                guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
                    DispatchQueue.main.async {
                        self.statusMessage = "Invalid input format: sample rate \(inputFormat.sampleRate), channels \(inputFormat.channelCount)"
                        self.isAudioPlaying = false
                    }
                    return
                }
                
                guard outputFormat.sampleRate > 0 && outputFormat.channelCount > 0 else {
                    DispatchQueue.main.async {
                        self.statusMessage = "Invalid output format: sample rate \(outputFormat.sampleRate), channels \(outputFormat.channelCount)"
                        self.isAudioPlaying = false
                    }
                    return
                }
                
                // Check and adapt sample rate
                let format = self.createCompatibleAudioFormat(inputFormat: inputFormat, outputFormat: outputFormat)
                
                // Validate the created format
                guard let validFormat = format, 
                      validFormat.sampleRate > 0 && validFormat.channelCount > 0 else {
                    DispatchQueue.main.async {
                        self.statusMessage = "Cannot create compatible audio format"
                        self.isAudioPlaying = false
                    }
                    return
                }
                
                // Connect nodes using compatible format
                self.engine.connect(inputNode, to: outputNode, format: validFormat)
                self.logger.log(content: "Connected audio nodes successfully")

                try self.engine.start()
                self.logger.log(content: "Audio engine started successfully")
                
                DispatchQueue.main.async {
                    self.statusMessage = "Audio playing..."
                    self.isAudioPlaying = true
                }
            } catch {
                self.logger.log(content: "Error starting audio session: \(error)")
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
        // Check if engine exists and is running
        guard engine != nil else {
            logger.log(content: "Audio engine is nil, nothing to stop")
            return
        }
        
        if engine.isRunning {
            // Log the operation
            logger.log(content: "Engine is running, stopping...")
            
            // Stop engine first to avoid errors when disconnecting
            engine.stop()
            logger.log(content: "Engine stopped")
        } else {
            logger.log(content: "Audio engine not running, no need to stop")
        }
        
        // Safely disconnect and reset (non-throwing operations)
        // Disconnect all connections
        let inputNode = engine.inputNode
        engine.disconnectNodeOutput(inputNode)
        logger.log(content: "Disconnected input node")

        // Reset engine
        engine.reset()
        logger.log(content: "Audio engine reset")
        
        // Reset audio device ID
        self.audioDeviceId = nil
        
        // Update UI status
        DispatchQueue.main.async {
            self.statusMessage = "Audio stopped"
            self.isAudioPlaying = false
        }
    }
    
    // Create compatible audio format
    private func createCompatibleAudioFormat(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) -> AVAudioFormat? {
        // Validate input formats
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            logger.log(content: "Invalid input format: sample rate \(inputFormat.sampleRate), channels \(inputFormat.channelCount)")
            return nil
        }
        
        guard outputFormat.sampleRate > 0 && outputFormat.channelCount > 0 else {
            logger.log(content: "Invalid output format: sample rate \(outputFormat.sampleRate), channels \(outputFormat.channelCount)")
            return nil
        }
        
        // If sample rates match, return input format
        if inputFormat.sampleRate == outputFormat.sampleRate {
            logger.log(content: "Sample rates match (\(inputFormat.sampleRate) Hz), using input format")
            return inputFormat
        }
        
        // Try to create new format with matching sample rate
        logger.log(content: "Sample rates differ (input: \(inputFormat.sampleRate) Hz, output: \(outputFormat.sampleRate) Hz), creating compatible format")
        
        let compatibleFormat = AVAudioFormat(
            commonFormat: inputFormat.commonFormat,
            sampleRate: outputFormat.sampleRate,
            channels: min(inputFormat.channelCount, outputFormat.channelCount), // Use minimum channel count
            interleaved: inputFormat.isInterleaved
        )
        
        if let format = compatibleFormat {
            logger.log(content: "Created compatible format: \(format.sampleRate) Hz, \(format.channelCount) channels")
            return format
        } else {
            logger.log(content: "Failed to create compatible format, falling back to output format")
            return outputFormat
        }
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
    
        // Get audio device by names (supports multiple names, returns first match)
    func getAudioDeviceByNames(names: [String]) -> AudioDeviceID? {
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

        // Search for device with matching name from the list
        for deviceID in deviceIDs {
            let deviceName = getAudioDeviceName(for: deviceID)
            
            if let deviceName = deviceName, names.contains(deviceName) {
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
        // Prevent multiple listener registrations
        guard !isAudioListenerSetup else {
            logger.log(content: "⏭️ Audio device change listener already set up, skipping duplicate registration")
            return
        }
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // Save listener ID for later removal
        self.audioPropertyListenerID = { (numberAddresses, addresses) in
            // Debounce: Cancel previous timer and schedule a new one
            self.deviceChangeDebounceTimer?.invalidate()
            
            self.deviceChangeDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                DispatchQueue.main.async {
                    // Update available devices list
                    self.updateAvailableAudioDevices()
                    
                    // Check if the currently selected device is still available
                    if let selectedDevice = self.selectedInputDevice {
                        let deviceStillExists = self.getAudioDeviceByNames(names: [selectedDevice.name]) != nil
                        
                        if !deviceStillExists {
                            DispatchQueue.main.async {
                                self.statusMessage = "Selected audio device '\(selectedDevice.name)' disconnected"
                                self.isAudioDeviceConnected = false
                                self.audioDeviceId = nil
                            }
                            self.stopAudioSession()
                        } else {
                            DispatchQueue.main.async {
                                self.statusMessage = "Audio device '\(selectedDevice.name)' connected"
                                self.isAudioDeviceConnected = true
                            }
                            // Restart session if it was running and auto-start is enabled
                            if self.autoStartEnabled && self.isAudioPlaying {
                                self.stopAudioSession()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    self.startAudioSession()
                                }
                            }
                        }
                    } else {
                        // No device selected, check if OpenterfaceA is available for initial auto-selection
                        if self.getAudioDeviceByNames(names: ["OpenterfaceA", "USB2 Digital Audio"]) != nil {
                            if let openterfaceDevice = self.availableInputDevices.first(where: { $0.name == "OpenterfaceA" }) {
                                DispatchQueue.main.async {
                                    self.selectedInputDevice = openterfaceDevice
                                    self.audioDeviceId = openterfaceDevice.deviceID
                                    self.statusMessage = "OpenterfaceA device auto-selected"
                                    self.isAudioDeviceConnected = true
                                    self.logger.log(content: "Auto-selected OpenterfaceA as no device was previously selected")
                                }
                            }
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
        
        // Mark listener as set up
        isAudioListenerSetup = true
        logger.log(content: "✅ Audio device change listener registered successfully")
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
            isAudioListenerSetup = false
            isAudioInitialized = false
        }
    }
    
    // Set audio enabled
    func setAudioEnabled(_ enabled: Bool) {
        // Update auto-start flag
        self.autoStartEnabled = enabled
        
        // Save the preference to UserSettings for persistence
        UserSettings.shared.isAudioEnabled = enabled
        
        logger.log(content: "Audio auto-start set to: \(enabled) and saved to user preferences")
        
        if enabled {
            // If we're enabling audio, start it with the currently selected device
            logger.log(content: "Starting audio session explicitly")
            
            // Use the currently selected device or fall back to OpenterfaceA
            var deviceToUse: AudioDeviceID? = nil
            
            if let selectedDevice = selectedInputDevice {
                deviceToUse = selectedDevice.deviceID
                logger.log(content: "Using selected device: \(selectedDevice.name)")
            } else {
                deviceToUse = self.getAudioDeviceByNames(names: ["OpenterfaceA", "USB2 Digital Audio"])
                if deviceToUse != nil {
                    logger.log(content: "No device selected, falling back to OpenterfaceA")
                }
            }
            
            if let deviceID = deviceToUse {
                self.audioDeviceId = deviceID
                startAudioSession()
            } else {
                logger.log(content: "No suitable audio device found")
                prepareAudio()
            }
        } else {
            // If we're disabling audio, stop it
            logger.log(content: "Stopping audio session explicitly")
            stopAudioSession()
        }
    }
    
    // MARK: - Protocol Methods for Input/Output Device Management
    
    /// Select an output audio device (speakers)
    func selectOutputDevice(_ device: AudioDevice) {
        selectedOutputDevice = device
        logger.log(content: "Selected output device: \(device.name)")
        
        // If audio is currently running, restart with the new output device
        if isAudioPlaying {
            stopAudioSession()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.startAudioSession()
            }
        }
    }
}
