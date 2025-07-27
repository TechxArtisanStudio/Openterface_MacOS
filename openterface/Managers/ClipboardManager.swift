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

import Foundation
import AppKit
import Combine

struct ClipboardItem: Hashable {
    let id: UUID
    let content: String
    let timestamp: Date
    let source: ClipboardSource
    
    init(content: String, source: ClipboardSource = .external) {
        self.id = UUID()
        self.content = content
        self.timestamp = Date()
        self.source = source
    }
    
    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        return lhs.id == rhs.id
    }
}

enum ClipboardSource: Hashable {
    case ocr
    case external
    case manual
}

extension ClipboardSource: RawRepresentable {
    var rawValue: String {
        switch self {
        case .ocr: return "ocr"
        case .external: return "external"
        case .manual: return "manual"
        }
    }
    
    init?(rawValue: String) {
        switch rawValue {
        case "ocr": self = .ocr
        case "external": self = .external
        case "manual": self = .manual
        default: return nil
        }
    }
}

class ClipboardManager: ClipboardManagerProtocol, ObservableObject {
    private var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    
    static let shared = ClipboardManager()
    
    @Published var currentClipboardContent: String?
    @Published var clipboardHistory: [ClipboardItem] = []
    
    private var monitoringTimer: Timer?
    private var lastChangeCount: Int = 0
    private let maxHistoryItems = 50
    private var userSettings = UserSettings.shared
    private var confirmationWindowController: PasteConfirmationWindowController?

    private init() {
        currentClipboardContent = NSPasteboard.general.string(forType: .string)
        lastChangeCount = NSPasteboard.general.changeCount
        loadHistoryFromUserDefaults()
        setupConfirmationWindow()
    }
    
    private func setupConfirmationWindow() {
        confirmationWindowController = PasteConfirmationWindowController()
    }

    func startMonitoring() {
        logger.log(content: "📋 Starting clipboard monitoring")
        
        // Monitor clipboard changes every 0.5 seconds
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboardChanges()
        }
    }
    
    func stopMonitoring() {
        logger.log(content: "📋 Stopping clipboard monitoring")
        monitoringTimer?.invalidate()
        monitoringTimer = nil
    }
    
    func addToHistory(_ content: String) {
        guard !content.isEmpty else { return }
        
        // Don't add if it's the same as the most recent item
        if let lastItem = clipboardHistory.first, lastItem.content == content {
            return
        }
        
        let newItem = ClipboardItem(content: content, source: .ocr)
        clipboardHistory.insert(newItem, at: 0)
        
        // Trim history to max items
        if clipboardHistory.count > maxHistoryItems {
            clipboardHistory = Array(clipboardHistory.prefix(maxHistoryItems))
        }
        
        saveHistoryToUserDefaults()
        logger.log(content: "📋 Added item to clipboard history: \(content.prefix(50))...")
    }
    
    func clearHistory() {
        clipboardHistory.removeAll()
        saveHistoryToUserDefaults()
        logger.log(content: "📋 Clipboard history cleared")
    }
    
    func copyToClipboard(_ content: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        
        currentClipboardContent = content
        addToHistory(content)
        
        logger.log(content: "📋 Content copied to clipboard: \(content.prefix(50))...")
    }
    
    private func checkClipboardChanges() {
        let currentChangeCount = NSPasteboard.general.changeCount
        
        if currentChangeCount != lastChangeCount {
            lastChangeCount = currentChangeCount
            
            if let newContent = NSPasteboard.general.string(forType: .string) {
                currentClipboardContent = newContent
                
                // Add to history if it's from external source
                if let lastItem = clipboardHistory.first, lastItem.content != newContent {
                    let newItem = ClipboardItem(content: newContent, source: .external)
                    clipboardHistory.insert(newItem, at: 0)
                    
                    if clipboardHistory.count > maxHistoryItems {
                        clipboardHistory = Array(clipboardHistory.prefix(maxHistoryItems))
                    }
                    
                    saveHistoryToUserDefaults()
                }
            }
        }
    }
    
    private func loadHistoryFromUserDefaults() {
        if let data = UserDefaults.standard.data(forKey: "ClipboardHistory"),
           let decoded = try? JSONDecoder().decode([ClipboardItemData].self, from: data) {
            clipboardHistory = decoded.map { itemData in
                ClipboardItem(
                    content: itemData.content,
                    source: ClipboardSource(rawValue: itemData.source) ?? .external
                )
            }
        }
    }
    
    private func saveHistoryToUserDefaults() {
        let itemsData = clipboardHistory.map { item in
            ClipboardItemData(
                content: item.content,
                source: item.source.rawValue,
                timestamp: item.timestamp
            )
        }
        
        if let encoded = try? JSONEncoder().encode(itemsData) {
            UserDefaults.standard.set(encoded, forKey: "ClipboardHistory")
        }
    }
    
    // MARK: - Paste Detection and Confirmation
    
    func handlePasteRequest() {
        let pasteboard = NSPasteboard.general
        guard let content = pasteboard.string(forType: .string), !content.isEmpty else {
            logger.log(content: "📋 No content to paste from clipboard")
            return
        }
        
        handlePasteRequest(with: content)
    }
    
    func handlePasteRequest(with content: String) {
        logger.log(content: "📋 Paste request detected with content: \(content.prefix(50))...")
        
        // Check user's paste behavior preference
        switch userSettings.pasteBehavior {
        case .alwaysPasteToTarget:
            performPaste(content: content)
        case .alwaysPassToTarget:
            passThroughToHost()
        case .askEveryTime:
            showPasteConfirmation(for: content)
        }
    }
    
    private func showPasteConfirmation(for content: String) {
        guard let windowController = confirmationWindowController else {
            logger.log(content: "⚠️ Paste confirmation window controller not available")
            performPaste(content: content) // Fallback to direct paste
            return
        }
        
        windowController.showConfirmation(for: content) { [weak self] action in
            switch action {
            case .pasteToTarget:
                self?.performPaste(content: content)
            case .passToHost:
                self?.passThroughToHost()
            case .cancel:
                self?.logger.log(content: "📋 Paste cancelled by user")
            }
        }
    }
    
    private func passThroughToHost() {
        logger.log(content: "📋 Passing paste event to host system")
        // Let the system handle the paste normally
        // This essentially does nothing, allowing the natural paste to occur
        DispatchQueue.main.async {
            // We could potentially trigger a normal paste here if needed
            // For now, just log that we're passing through
        }
    }
    
    private func performPaste(content: String) {
        logger.log(content: "📋 Performing paste text to target: \(content.prefix(50))...")
        let keyboardManager = DependencyContainer.shared.resolve(KeyboardManagerProtocol.self)
        keyboardManager.sendTextToKeyboard(text: content)
        
        // Show brief confirmation in UI
        showPasteSuccessNotification()
    }
    
    private func showPasteSuccessNotification() {
        // This could be enhanced to show a temporary notification
        // For now, just log the success
        logger.log(content: "✅ Text successfully pasted to target")
    }
}

// Helper struct for UserDefaults persistence
private struct ClipboardItemData: Codable {
    let content: String
    let source: String
    let timestamp: Date
}
