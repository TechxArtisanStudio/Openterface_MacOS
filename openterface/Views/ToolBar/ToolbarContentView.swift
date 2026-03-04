import SwiftUI

struct ToolbarContentView: ToolbarContent {
    // Bindings and values provided by the parent App
    @Binding var showButtons: Bool
    @Binding var switchToTarget: Bool

    var isAudioEnabled: Bool
    var canTakePicture: Bool
    var isRecording: Bool
    var hasHdmiSignal: Bool?
    var isKeyboardConnected: Bool?
    var isMouseConnected: Bool?
    var isMouseLoopRunning: Bool

    var resolutionWidth: String
    var resolutionHeight: String
    var fps: String
    var pixelClock: String

    var serialPortName: String
    @Binding var serialPortBaudRate: Int


    // observe the shared serial manager directly so we track configuration state
    @ObservedObject private var concreteSerialPortMgr: SerialPortManager = SerialPortManager.shared

    // Action callbacks
    var handleSwitchToggle: (Bool) -> Void
    var toggleAudio: (Bool) -> Void
    var showAspectRatioSelection: () -> Void
    var showUSBDevices: () -> Void

    // popover state for baud menu
    @State private var showBaudPopover = false

    // hover state for each selection button
    @State private var hovering9600 = false
    @State private var hovering115200 = false

    // Resolve dependencies directly when needed
    private var floatingKeyboardManager: FloatingKeyboardManagerProtocol { DependencyContainer.shared.resolve(FloatingKeyboardManagerProtocol.self) }
    private var audioManager: AudioManagerProtocol { DependencyContainer.shared.resolve(AudioManagerProtocol.self) }
    private var cameraManager: CameraManagerProtocol { DependencyContainer.shared.resolve(CameraManagerProtocol.self) }
    private var serialPortManager: SerialPortManagerProtocol { DependencyContainer.shared.resolve(SerialPortManagerProtocol.self) }
    private var mouseManager: MouseManagerProtocol { DependencyContainer.shared.resolve(MouseManagerProtocol.self) }
    private var logger: LoggerProtocol { DependencyContainer.shared.resolve(LoggerProtocol.self) }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button {
                logger.log(content: "🎹 Floating keyboard button pressed")
                floatingKeyboardManager.showFloatingKeysWindow()
            } label: {
                Image(systemName: showButtons ? "keyboard" : "keyboard.chevron.compact.down.fill")
            }

            CapsLockIndicatorView()
                .help("Host Caps Lock state - ON/OFF")

            Button(action: {}) {
                Image(systemName: "poweron") // spacer
            }
            .disabled(true)
            .buttonStyle(PlainButtonStyle())

            Menu {
                Button(action: {
                    toggleAudio(!isAudioEnabled)
                }) {
                    Label(isAudioEnabled ? "Mute Audio" : "Unmute Audio",
                          systemImage: isAudioEnabled ? "speaker.slash" : "speaker.wave.3")
                }

                Divider()

                Menu("Audio Settings") {
                    AudioSourceMenuContent(audioManager: audioManager as! AudioManager)
                }
            } label: {
                Image(systemName: isAudioEnabled ? "speaker.wave.3.fill" : "speaker.slash.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .foregroundColor(isAudioEnabled ? .green : .red)
            }

            Button {
                cameraManager.takePicture()
            } label: {
                Image(systemName: "camera.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .foregroundColor(canTakePicture ? .blue : .gray)
            }
            .help("Take Picture")
            .disabled(!canTakePicture)

            Button {
                if isRecording {
                    cameraManager.stopVideoRecording()
                } else {
                    cameraManager.startVideoRecording()
                }
            } label: {
                Image(systemName: isRecording ? "record.circle.fill" : "record.circle")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .foregroundColor(isRecording ? .red : (canTakePicture ? .blue : .gray))
            }
            .help(isRecording ? "Stop Recording" : "Start Video Recording")
            .disabled(!canTakePicture)

            Button(action: {
                showAspectRatioSelection()
            }) {
                Image(systemName: "display")
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundColor(colorForConnectionStatus(hasHdmiSignal))
            }
            .help("Click to view Target Aspect Ratio...")
        }

        ToolbarItem(placement: .primaryAction) {
            ResolutionView(
                width: resolutionWidth,
                height: resolutionHeight,
                fps: fps,
                helpText: "Input Resolution: \(resolutionWidth)x\(resolutionHeight)\n" +
                    "Capture Resolution: 1920x1080\n" +
                    "Refresh Rate: \(fps) Hz\n" +
                    "Pixel Clock: \(pixelClock) MHz\n" +
                    "HTotal: \(AppStatus.hidInputHTotal)\n" +
                    "VTotal: \(AppStatus.hidInputVTotal)\n" +
                    "Hst: \(AppStatus.hidInputHst)\n" +
                    "Vst: \(AppStatus.hidInputVst)\n" +
                    "Hsync Width: \(AppStatus.hidInputHsyncWidth)\n" +
                    "Vsync Width: \(AppStatus.hidInputVsyncWidth)"
            )
        }

        ToolbarItem(placement: .automatic) {
            Button(action: {
                showUSBDevices()
            }) {
                HStack {
                    Image(systemName: "keyboard.fill")
                        .resizable()
                        .frame(width: 16, height: 12)
                        .foregroundColor(colorForConnectionStatus(isKeyboardConnected))
                    Image(systemName: isMouseLoopRunning ? "cursor.rays" : "computermouse.fill")
                        .resizable()
                        .frame(width: isMouseLoopRunning ? 14 : 10, height: 12)
                        .foregroundColor(colorForConnectionStatus(isMouseConnected))
                }
            }
            .help(
                """
                KeyBoard: \(
                    isKeyboardConnected == true ? "Connected" :
                    isKeyboardConnected == false ? "Not found" : "Unknown"
                )
                Mouse: \(
                    isMouseConnected == true ? "Connected" :
                    isMouseConnected == false ? "Not found" : "Unknown"
                )

                Click to view USB device details
                """
            )
        }

        ToolbarItem(placement: .automatic) {
            // use the shared manager we’re observing
            let serialPortMgr = concreteSerialPortMgr

            // determine display values directly from bindings
            let displayName = serialPortName
            let displayBaud = serialPortBaudRate

            Button {
                showBaudPopover = true
            } label: {
                SerialInfoView(portName: displayName,
                               baudRate: displayBaud,
                               processingHz: UserSettings.shared.mouseEventThrottleHz)
                    .frame(width: 140, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            .buttonStyle(PlainButtonStyle())
            .popover(isPresented: $showBaudPopover) {
                    VStack(spacing: 8) {
                        Button("9600 bps") {
                            logger.log(content: "Serial baudrate popover: user chose 9600")
                            serialPortMgr.resetDeviceToBaudrate(9600)
                            showBaudPopover = false
                        }
                        .onHover { hovering9600 = $0 }
                        .shadow(color: .black.opacity(hovering9600 ? 0.25 : 0), radius: hovering9600 ? 8 : 0, x: 0, y: 2)

                        Button("115200 bps") {
                            logger.log(content: "Serial baudrate popover: user chose 115200")
                            serialPortMgr.resetDeviceToBaudrate(115200)
                            showBaudPopover = false
                        }
                        .onHover { hovering115200 = $0 }
                        .shadow(color: .black.opacity(hovering115200 ? 0.25 : 0), radius: hovering115200 ? 8 : 0, x: 0, y: 2)
                    }
                    .padding(8)
                }
                .disabled(serialPortMgr.isConfiguring)
        }

        ToolbarItem(placement: .automatic) {
            Button(action: {}) {
                Image(systemName: "poweron") // spacer
            }
            .disabled(true)
            .buttonStyle(PlainButtonStyle())
        }

        ToolbarItemGroup(placement: .automatic) {
            Toggle(isOn: $switchToTarget) {
                HStack {
                    Image(switchToTarget ? "Target_icon" : "Host_icon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 15)
                    Text(switchToTarget ? "Target" : "Host")
                }
            }
            .toggleStyle(SwitchToggleStyle(width: 30, height: 16))
            .onChange(of: switchToTarget) { newValue in
                handleSwitchToggle(newValue)
            }
        }
    }

    func colorForConnectionStatus(_ isConnected: Bool?) -> Color {
        switch isConnected {
        case .some(true):
            return Color(red: 124 / 255.0, green: 205 / 255.0, blue: 124 / 255.0)
        case .some(false):
            return .orange
        case .none:
            return .gray
        }
    }
}

struct ToolbarContentView_Previews: PreviewProvider {
    static var previews: some View {
        // Wrap the ToolbarContent in a real View for previews
        EmptyView()
            .toolbar {
                ToolbarContentView(
                    showButtons: .constant(false),
                    switchToTarget: .constant(false),
                    isAudioEnabled: true,
                    canTakePicture: false,
                    isRecording: false,
                    hasHdmiSignal: nil,
                    isKeyboardConnected: nil,
                    isMouseConnected: nil,
                    isMouseLoopRunning: false,
                    resolutionWidth: "-",
                    resolutionHeight: "-",
                    fps: "-",
                    pixelClock: "0.00",
                    serialPortName: "N/A",
                    serialPortBaudRate: .constant(0),
                    handleSwitchToggle: { _ in },
                    toggleAudio: { _ in },
                    showAspectRatioSelection: {},
                    showUSBDevices: {}
                )
            }
    }
}
