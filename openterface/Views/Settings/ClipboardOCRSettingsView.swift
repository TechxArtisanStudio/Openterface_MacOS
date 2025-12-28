import SwiftUI

struct ClipboardOCRSettingsView: View {
    @ObservedObject private var userSettings = UserSettings.shared
    @State private var lastOCRText = ""
    @State private var ocrAccuracy = "Unknown"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Clipboard & OCR Management")
                .font(.title2)
                .bold()

            GroupBox("Clipboard Behavior") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Configure how Cmd+V paste events are handled")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("When Cmd+V is pressed:", selection: $userSettings.pasteBehavior) {
                        ForEach(PasteBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .pickerStyle(RadioGroupPickerStyle())

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Behavior explanations:")
                            .font(.headline)

                        Text("• Ask Every Time: Shows a dialog to choose the action")
                            .font(.caption)
                        Text("• Always Host Paste: Automatically sends clipboard text as keystrokes")
                            .font(.caption)
                        Text("• Always Local Paste: Forwards the Cmd+V combination directly")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ocrComplete)) { notification in
            if let result = notification.object as? String {
                lastOCRText = result
                ocrAccuracy = "Success"
            }
        }
    }
}
