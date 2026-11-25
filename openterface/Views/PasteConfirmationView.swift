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
*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU       *
*    General Public License for more details.                                *
*                                                                            *
*    You should have received a copy of the GNU General Public License       *
*    along with this program. If not, see <http://www.gnu.org/licenses/>.    *
*                                                                            *
* ========================================================================== *
*/

import SwiftUI
import AppKit

struct PasteConfirmationView: View {
    let clipboardContent: String
    let onPasteToTarget: (String) -> Void
    let onPassToHost: () -> Void
    let onCancel: () -> Void
    let onClose: () -> Void

    @State private var rememberChoice = false
    @State private var selectedBehavior: PasteBehavior = .askEveryTime
    @State private var draftText: String = ""
    @ObservedObject private var userSettings = UserSettings.shared
    @ObservedObject private var keyboard = KeyboardManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if keyboard.isPastingText {
                pastingSection
            } else if let result = keyboard.pasteResult {
                resultSection(result)
            } else {
                choiceSection
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 10)
        .onAppear {
            selectedBehavior = userSettings.pasteBehavior
            if draftText.isEmpty {
                draftText = clipboardContent
            }
        }
        .onChange(of: keyboard.pasteResult) { result in
            // When the user stopped the paste, load the unsent remainder for editing.
            if result == .cancelled {
                draftText = keyboard.pasteRemainingText ?? ""
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: headerIcon)
                .font(.title2)
                .foregroundColor(headerColor)

            Text(headerTitle)
                .font(.headline)
                .fontWeight(.semibold)
        }
    }

    private var headerIcon: String {
        if keyboard.isPastingText { return "arrow.down.circle" }
        switch keyboard.pasteResult {
        case .completed: return "checkmark.circle"
        case .cancelled: return "stop.circle"
        case nil: return "clipboard"
        }
    }

    private var headerColor: Color {
        if keyboard.isPastingText { return .orange }
        switch keyboard.pasteResult {
        case .completed: return .green
        case .cancelled: return .orange
        case nil: return .blue
        }
    }

    private var headerTitle: String {
        if keyboard.isPastingText { return "Pasting to Target…" }
        switch keyboard.pasteResult {
        case .completed: return "Paste Complete"
        case .cancelled: return "Paste Stopped"
        case nil: return "Paste Action Required"
        }
    }

    // MARK: - Pasting

    private var pastingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sending \(characterCount) character\(characterCount == 1 ? "" : "s") to the target…")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ProgressView(value: keyboard.pasteProgress)
                .progressViewStyle(.linear)

            HStack {
                Text("\(Int((keyboard.pasteProgress * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)

                Spacer()

                Button("Stop") {
                    keyboard.cancelPaste()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Result

    @ViewBuilder
    private func resultSection(_ result: PasteResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch result {
            case .completed:
                Text("Text was pasted to the target.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    Spacer()
                    Button("Close") {
                        onClose()
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                }

            case .cancelled:
                Text("Paste stopped. Edit the remaining text and continue, or close.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextEditor(text: $draftText)
                    .font(.system(.body, design: .monospaced))
                    .padding(4)
                    .frame(height: 90)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    )

                HStack {
                    Button("Close") {
                        onClose()
                    }

                    Spacer()

                    Button("Continue") {
                        onPasteToTarget(draftText)
                    }
                    .disabled(draftText.isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Choice

    private var choiceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Content editor
            VStack(alignment: .leading, spacing: 8) {
                Text("Content to paste (editable):")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextEditor(text: $draftText)
                    .font(.system(.body, design: .monospaced))
                    .padding(4)
                    .frame(height: 90)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    )
            }

            // Choice explanation
            VStack(alignment: .leading, spacing: 4) {
                Text("What would you like to do?")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("• Host Paste: When you want to paste text from your computer’s clipboard into the target.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("• Local Paste: When you want to paste text already copied inside the target.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Remember choice option
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Remember my choice", isOn: $rememberChoice)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if rememberChoice {
                    Picker("Default behavior:", selection: $selectedBehavior) {
                        ForEach(PasteBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .font(.caption)
                }
            }

            // Action buttons
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Local Paste") {
                    if rememberChoice {
                        userSettings.pasteBehavior = selectedBehavior == .askEveryTime ? .alwaysPassToTarget : selectedBehavior
                    }
                    onPassToHost()
                }
                .keyboardShortcut("h", modifiers: .command)

                Button("Host Paste") {
                    if rememberChoice {
                        userSettings.pasteBehavior = selectedBehavior == .askEveryTime ? .alwaysPasteToTarget : selectedBehavior
                    }
                    onPasteToTarget(draftText)
                }
                .disabled(draftText.isEmpty)
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var characterCount: Int {
        clipboardContent.count
    }
}

class PasteConfirmationWindowController: NSWindowController {
    private var completion: ((PasteAction) -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.title = "Paste Confirmation"
        window.level = .floating
        window.center()
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showConfirmation(for content: String, completion: @escaping (PasteAction) -> Void) {
        self.completion = completion
        KeyboardManager.shared.resetPasteResult()

        let confirmationView = PasteConfirmationView(
            clipboardContent: content,
            onPasteToTarget: { text in
                // Keep the window open: it turns into the paste progress / stop UI.
                completion(.pasteToTarget(text))
            },
            onPassToHost: { [weak self] in
                self?.window?.close()
                completion(.passToHost)
            },
            onCancel: { [weak self] in
                self?.window?.close()
                completion(.cancel)
            },
            onClose: { [weak self] in
                self?.window?.close()
            }
        )

        let hostingView = NSHostingView(rootView: confirmationView)
        window?.contentView = hostingView

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    override func windowDidLoad() {
        super.windowDidLoad()
    }
}

enum PasteAction {
    case pasteToTarget(String)
    case passToHost
    case cancel
}

#Preview {
    PasteConfirmationView(
        clipboardContent: "Sample clipboard content\nwith multiple lines\nto demonstrate the paste confirmation dialog",
        onPasteToTarget: { text in print("Host Paste confirmed: \(text.prefix(20))") },
        onPassToHost: { print("Local Paste confirmed") },
        onCancel: { print("Paste cancelled") },
        onClose: { print("Closed") }
    )
}