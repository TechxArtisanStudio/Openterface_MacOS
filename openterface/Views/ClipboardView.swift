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

struct ClipboardView: View {
    @StateObject private var clipboardManager = ClipboardManager.shared
    @State private var selectedHistoryItem: ClipboardItem?
    @State private var showPasteConfirmationOverlay = false
    
    // Add keyboard manager for sending text to target
    private var keyboardManager: KeyboardManagerProtocol { 
        DependencyContainer.shared.resolve(KeyboardManagerProtocol.self) 
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Panel - Current Clipboard Content
            currentClipboardPanel
            
            Divider()
            
            // Bottom Panel - Clipboard History
            clipboardHistoryPanel
        }
        .frame(width: 400, height: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            // Show paste confirmation overlay
            Group {
                if showPasteConfirmationOverlay {
                    VStack {
                        Image(systemName: "arrow.down.to.line")
                            .font(.largeTitle)
                            .foregroundColor(.green)
                        Text("Sent to Target")
                            .font(.headline)
                            .foregroundColor(.green)
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                    .shadow(radius: 8)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        )
        .onAppear {
            clipboardManager.startMonitoring()
        }
        .onDisappear {
            clipboardManager.stopMonitoring()
        }
    }
    
    private var currentClipboardPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Current Clipboard")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                if clipboardManager.currentClipboardContent != nil {
                    Button(action: {
                        if let content = clipboardManager.currentClipboardContent {
                            keyboardManager.sendTextToKeyboard(text: content)
                            showPasteConfirmation(content: content)
                        }
                    }) {
                        Image(systemName: "arrow.down.to.line")
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Host Paste")
                }
            }
            
            ScrollView {
                if let content = clipboardManager.currentClipboardContent {
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                } else {
                    Text("No content in clipboard")
                        .foregroundColor(.secondary)
                        .italic()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 120)
        }
        .padding()
    }
    
    private var clipboardHistoryPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.orange)
                Text("Clipboard History")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button(action: {
                    clipboardManager.clearHistory()
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Clear history")
            }
            
            if clipboardManager.clipboardHistory.isEmpty {
                Text("No clipboard history")
                    .foregroundColor(.secondary)
                    .italic()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(clipboardManager.clipboardHistory, id: \.id, selection: $selectedHistoryItem) { item in
                    ClipboardHistoryRow(item: item) {
                        clipboardManager.copyToClipboard(item.content)
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
        .padding()
    }
    
    // Function to show visual confirmation when text is sent to target
    private func showPasteConfirmation(content: String) {
        withAnimation(.easeInOut(duration: 0.3)) {
            showPasteConfirmationOverlay = true
        }
        
        // Hide the confirmation after 1.5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.3)) {
                showPasteConfirmationOverlay = false
            }
        }
    }
}

struct ClipboardHistoryRow: View {
    let item: ClipboardItem
    let onCopy: () -> Void
    
    // Add keyboard manager for sending text to target
    private var keyboardManager: KeyboardManagerProtocol { 
        DependencyContainer.shared.resolve(KeyboardManagerProtocol.self) 
    }
    
    @State private var showPasteConfirmation = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.content)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(3)
                    .foregroundColor(.primary)
                
                HStack {
                    sourceIcon
                    Text(timeAgoString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                }
            }
            
            Spacer()
            
            HStack(spacing: 4) {
                // Host Paste button
                Button(action: {
                    keyboardManager.sendTextToKeyboard(text: item.content)
                    showPasteConfirmationFeedback()
                }) {
                    Image(systemName: "arrow.down.to.line")
                        .foregroundColor(.orange)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Host Paste")
                
                // Copy to clipboard button
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.blue)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Copy to clipboard")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .overlay(
            // Show paste confirmation
            Group {
                if showPasteConfirmation {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Sent")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    .padding(4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                    .shadow(radius: 2)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        )
    }
    
    private func showPasteConfirmationFeedback() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showPasteConfirmation = true
        }
        
        // Hide the confirmation after 1 second
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showPasteConfirmation = false
            }
        }
    }
    
    private var sourceIcon: some View {
        Group {
            switch item.source {
            case .ocr:
                Image(systemName: "text.viewfinder")
                    .foregroundColor(.green)
            case .external:
                Image(systemName: "square.and.arrow.down")
                    .foregroundColor(.blue)
            case .manual:
                Image(systemName: "hand.point.up.left")
                    .foregroundColor(.orange)
            }
        }
        .font(.caption)
    }
    
    private var timeAgoString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: item.timestamp, relativeTo: Date())
    }
}

#Preview {
    ClipboardView()
}
