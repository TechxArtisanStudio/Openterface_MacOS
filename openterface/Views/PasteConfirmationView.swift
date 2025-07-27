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
import AppKit

struct PasteConfirmationView: View {
    let clipboardContent: String
    let onPasteToTarget: () -> Void
    let onPassToHost: () -> Void
    let onCancel: () -> Void
    
    @State private var rememberChoice = false
    @State private var selectedBehavior: PasteBehavior = .askEveryTime
    @ObservedObject private var userSettings = UserSettings.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "clipboard")
                    .font(.title2)
                    .foregroundColor(.blue)
                
                Text("Paste Action Required")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            
            // Content preview
            VStack(alignment: .leading, spacing: 8) {
                Text("Content to paste:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                ScrollView {
                    Text(clipboardContent)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                }
                .frame(maxHeight: 100)
            }
            
            // Choice explanation
            VStack(alignment: .leading, spacing: 4) {
                Text("What would you like to do?")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text("• Paste text to Target: Send text to the connected device")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("• Pass events to Target: Send key events to the connected device ")
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
                
                Button("Pass events to Target") {
                    if rememberChoice {
                        userSettings.pasteBehavior = selectedBehavior == .askEveryTime ? .alwaysPassToTarget : selectedBehavior
                    }
                    onPassToHost()
                }
                .keyboardShortcut("h", modifiers: .command)
                
                Button("Paste text to Target") {
                    if rememberChoice {
                        userSettings.pasteBehavior = selectedBehavior == .askEveryTime ? .alwaysPasteToTarget : selectedBehavior
                    }
                    onPasteToTarget()
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 10)
        .onAppear {
            selectedBehavior = userSettings.pasteBehavior
        }
    }
}

class PasteConfirmationWindowController: NSWindowController {
    private var completion: ((PasteAction) -> Void)?
    
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
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
        
        let confirmationView = PasteConfirmationView(
            clipboardContent: content,
            onPasteToTarget: { [weak self] in
                self?.window?.close()
                completion(.pasteToTarget)
            },
            onPassToHost: { [weak self] in
                self?.window?.close()
                completion(.passToHost)
            },
            onCancel: { [weak self] in
                self?.window?.close()
                completion(.cancel)
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
    case pasteToTarget
    case passToHost
    case cancel
}

#Preview {
    PasteConfirmationView(
        clipboardContent: "Sample clipboard content\nwith multiple lines\nto demonstrate the paste confirmation dialog",
        onPasteToTarget: { print("Paste text to target confirmed") },
        onPassToHost: { print("Pass events to target confirmed") },
        onCancel: { print("Paste cancelled") }
    )
}
