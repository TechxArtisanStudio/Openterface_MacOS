//
//  AudioManger.swift
//  openterface
//
//  Created by Shawn on 2025/3/4.
//

import SwiftUI
import AVFoundation
import CoreAudio
import Combine

// 管理音频功能的类
class AudioManager: ObservableObject {
    // 发布属性，用于在UI中显示状态
    @Published var isAudioDeviceConnected: Bool = false
    @Published var isAudioPlaying: Bool = false
    @Published var statusMessage: String = "正在检查音频设备..."
    @Published var microphonePermissionGranted: Bool = false
    @Published var showingPermissionAlert: Bool = false
    
    // 音频引擎
    private var engine: AVAudioEngine!
    // 音频设备ID
    private var audioDeviceId: AudioDeviceID? = nil
    // 取消订阅存储
    private var cancellables = Set<AnyCancellable>()
    // 音频属性监听器ID
    private var audioPropertyListenerID: AudioObjectPropertyListenerBlock?
    
    init() {
        engine = AVAudioEngine()
        // 先检查麦克风权限
        checkMicrophonePermission()
        
        // 确保应用出现在权限列表中
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }
    
    deinit {
        stopAudioSession()
        cleanupListeners()
    }
    
    // 检查麦克风权限
    func checkMicrophonePermission() {
        // 创建一个临时的AVCaptureDevice会话来触发权限请求
        // _ = AVCaptureSession()
        
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            // 已经有权限，可以继续
            self.microphonePermissionGranted = true
            DispatchQueue.main.async {
                self.statusMessage = "麦克风权限已获取"
            }
            setupAudioDeviceChangeListener()
            prepareAudio()
            
        case .notDetermined:
            // 还没有请求过权限，需要请求
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.microphonePermissionGranted = true
                        self?.statusMessage = "麦克风权限已获取"
                        self?.setupAudioDeviceChangeListener()
                        self?.prepareAudio()
                    } else {
                        self?.microphonePermissionGranted = false
                        self?.statusMessage = "需要麦克风权限才能播放音频"
                        self?.showingPermissionAlert = true
                    }
                }
            }
            
        case .denied, .restricted:
            // 权限被拒绝或受到限制
            self.microphonePermissionGranted = false
            DispatchQueue.main.async {
                self.statusMessage = "需要麦克风权限才能播放音频"
                self.showingPermissionAlert = true
            }
            
        @unknown default:
            break
        }
    }
    
    // 打开系统设置
    func openSystemPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // 准备音频处理
    func prepareAudio() {
        // 如果没有麦克风权限，不继续处理
        if !microphonePermissionGranted {
            DispatchQueue.main.async {
                self.statusMessage = "需要麦克风权限才能播放音频"
                self.showingPermissionAlert = true
            }
            return
        }
        
        DispatchQueue.main.async {
            self.statusMessage = "正在查找音频设备..."
        }
        
        if self.audioDeviceId != nil {
            return
        }
        
        // 查找音频设备并稍作延迟以确保设备初始化
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            
            self.audioDeviceId = self.getAudioDeviceByName(name: "OpenterfaceA")
            if self.audioDeviceId == nil {
                DispatchQueue.main.async {
                    self.statusMessage = "未找到音频设备 'OpenterfaceA'"
                    self.isAudioDeviceConnected = false
                }
                return
            }
            
            DispatchQueue.main.async {
                self.statusMessage = "已找到音频设备 'OpenterfaceA'"
                self.isAudioDeviceConnected = true
            }
            
            // 如果找到设备ID，开始音频会话
            self.startAudioSession()
        }
    }
    
    // 启动音频会话
    func startAudioSession() {
        stopAudioSession()
        
        // 重新创建音频引擎以避免重用潜在的状态问题
        engine = AVAudioEngine()
        
        // 添加延迟以确保设备完全初始化
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            
            do {
                // 获取输入节点（麦克风）
                let inputNode = self.engine.inputNode
                self.audioDeviceId = self.getAudioDeviceByName(name: "OpenterfaceA")
                if self.audioDeviceId == nil {
                    DispatchQueue.main.async {
                        self.statusMessage = "无法访问音频设备"
                        self.isAudioPlaying = false
                    }
                    return
                }
                
                let outputNode = self.engine.outputNode
                let inputFormat = inputNode.outputFormat(forBus: 0)
                let outputFormat = outputNode.inputFormat(forBus: 0)
                
                // 检查并适配采样率
                let format = self.createCompatibleAudioFormat(inputFormat: inputFormat, outputFormat: outputFormat)

                // 将音频设备设置为默认输入设备
                self.setDefaultAudioInputDevice()
                
                // 使用兼容格式连接节点
                try self.engine.connect(inputNode, to: outputNode, format: format)
                
                try self.engine.start()
                DispatchQueue.main.async {
                    self.statusMessage = "音频播放中..."
                    self.isAudioPlaying = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "启动音频时出错: \(error.localizedDescription)"
                    self.isAudioPlaying = false
                }
                self.stopAudioSession()
            }
        }
    }
    
    // 停止音频会话
    func stopAudioSession() {
        // 检查引擎是否运行
        if engine.isRunning {
            // 先停止引擎以避免断开连接时出错
            engine.stop()
            
            // 断开所有连接
            let inputNode = engine.inputNode
            engine.disconnectNodeOutput(inputNode)
            
            // 重置引擎
            engine.reset()
        }
        
        self.audioDeviceId = nil
        DispatchQueue.main.async {
            self.isAudioPlaying = false
        }
    }
    
    // 创建兼容的音频格式
    private func createCompatibleAudioFormat(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) -> AVAudioFormat {
        var format = inputFormat
        
        if inputFormat.sampleRate != outputFormat.sampleRate {
            // 创建匹配采样率的新格式
            format = AVAudioFormat(
                commonFormat: inputFormat.commonFormat,
                sampleRate: outputFormat.sampleRate,
                channels: inputFormat.channelCount,
                interleaved: inputFormat.isInterleaved) ?? outputFormat
        }
        
        return format
    }
    
    // 设置当前音频设备为默认输入设备
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
    
    // 通过名称获取音频设备
    func getAudioDeviceByName(name: String) -> AudioDeviceID? {
        var propSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // 获取属性数据大小
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

        // 计算设备数量并准备数组
        let deviceCount = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array<AudioDeviceID>(repeating: 0, count: deviceCount)

        // 获取设备ID
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

        // 搜索匹配名称的设备
        for deviceID in deviceIDs {
            let deviceName = getAudioDeviceName(for: deviceID)
            
            if deviceName == name {
                return deviceID
            }
        }

        return nil
    }
    
    // 获取音频设备名称
    private func getAudioDeviceName(for deviceID: AudioDeviceID) -> String? {
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // 获取名称属性的大小
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

        // 获取设备名称
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
    
    // 设置音频设备变更监听器
    private func setupAudioDeviceChangeListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // 保存监听器ID以便稍后移除
        self.audioPropertyListenerID = { (numberAddresses, addresses) in
            DispatchQueue.main.async {
                if self.getAudioDeviceByName(name: "OpenterfaceA") == nil {
                    DispatchQueue.main.async {
                        self.statusMessage = "音频设备已断开连接"
                        self.isAudioDeviceConnected = false
                    }
                    self.stopAudioSession()
                } else {
                    DispatchQueue.main.async {
                        self.statusMessage = "音频设备已连接"
                        self.isAudioDeviceConnected = true
                    }
                    // 在准备新的音频会话之前确保完全停止
                    self.stopAudioSession()
                    // 准备音频之前稍作延迟，以确保设备稳定性
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.prepareAudio()
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
    
    // 清理所有监听器
    private func cleanupListeners() {
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
            audioPropertyListenerID = nil
        }
    }
}
