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

class OrderIDTextFieldDelegate: NSObject, NSTextFieldDelegate {
    var onTextChanged: (() -> Void)?
    
    func controlTextDidChange(_ obj: Notification) {
        onTextChanged?()
    }
}

class DefectReportDialog {
    typealias DialogResult = (action: DialogAction, orderID: String)
    
    enum DialogAction {
        case copyToClipboard
        case openLogFolder
        case done
    }
    
    static func show(
        emailSubject: String,
        emailBody: String,
        reportDir: URL,
        statusLogPath: URL,
        diagnosticsLogPath: URL,
        onStatusMessage: @escaping (String) -> Void
    ) -> DialogResult {
        onStatusMessage("📧 Showing email template dialog...")
        
        let alert = NSAlert()
        alert.messageText = "📧 Defect Report - Ready to Send"
        alert.informativeText = "Please fill in your Order ID (mandatory) and review the email template below."
        alert.alertStyle = .informational
        
        // Create OrderID input field
        let orderIDLabel = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        orderIDLabel.stringValue = "Order ID: *"
        orderIDLabel.isBezeled = false
        orderIDLabel.drawsBackground = false
        orderIDLabel.isEditable = false
        orderIDLabel.font = NSFont.systemFont(ofSize: 11)
        
        let orderIDField = NSTextField(frame: NSRect(x: 100, y: 0, width: 400, height: 24))
        orderIDField.isBezeled = true
        orderIDField.drawsBackground = true
        orderIDField.backgroundColor = .textBackgroundColor
        orderIDField.placeholderString = "Enter your Order ID (e.g., 123456)"
        
        let orderIDContainer = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
        orderIDContainer.addSubview(orderIDLabel)
        orderIDContainer.addSubview(orderIDField)
        
        // Create Your Name input field
        let nameLabel = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        nameLabel.stringValue = "Your Name:"
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        nameLabel.isEditable = false
        nameLabel.font = NSFont.systemFont(ofSize: 11)
        
        let nameField = NSTextField(frame: NSRect(x: 100, y: 0, width: 400, height: 24))
        nameField.isBezeled = true
        nameField.drawsBackground = true
        nameField.backgroundColor = .textBackgroundColor
        nameField.placeholderString = "Enter your name"
        
        let nameContainer = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
        nameContainer.addSubview(nameLabel)
        nameContainer.addSubview(nameField)
        
        // Create support email section
        let supportEmailLabel = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        supportEmailLabel.stringValue = "Send To:"
        supportEmailLabel.isBezeled = false
        supportEmailLabel.drawsBackground = false
        supportEmailLabel.isEditable = false
        supportEmailLabel.font = NSFont.systemFont(ofSize: 11)
        
        let supportEmailField = NSTextField(frame: NSRect(x: 100, y: 0, width: 300, height: 24))
        supportEmailField.stringValue = "support@openterface.com"
        supportEmailField.isBezeled = true
        supportEmailField.drawsBackground = true
        supportEmailField.backgroundColor = .textBackgroundColor
        supportEmailField.isEditable = false
        supportEmailField.isSelectable = true
        supportEmailField.font = NSFont.systemFont(ofSize: 11)
        
        let copyEmailButton = NSButton(frame: NSRect(x: 410, y: 2, width: 70, height: 20))
        copyEmailButton.title = "Copy"
        copyEmailButton.bezelStyle = .rounded
        copyEmailButton.font = NSFont.systemFont(ofSize: 10)
        copyEmailButton.target = nil
        copyEmailButton.action = #selector(NSApplication.orderFrontCharacterPalette(_:))
        
        let supportEmailContainer = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
        supportEmailContainer.addSubview(supportEmailLabel)
        supportEmailContainer.addSubview(supportEmailField)
        supportEmailContainer.addSubview(copyEmailButton)
        
        // Set up copy button action
        copyEmailButton.target = nil
        copyEmailButton.action = nil
        // We'll handle this in the alert loop
        
        // Create a text view with the email content (will be updated with Order ID)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 250))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // `borderType` was deprecated in macOS 10.15; use a layer-based border instead
        scrollView.wantsLayer = true
        if let layer = scrollView.layer {
            layer.borderWidth = 1.0
            layer.borderColor = NSColor.separatorColor.cgColor
            layer.cornerRadius = 4.0
        }
        
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 250))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 10)
        textView.textColor = .labelColor
        textView.backgroundColor = .controlBackgroundColor
        
        scrollView.documentView = textView
        
        // Create a box for the path information
        let infoBox = NSBox(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        infoBox.title = "📁 Log Files to Attach"
        infoBox.boxType = .primary
        // `borderType` is deprecated; use a layer-based border for similar appearance
        infoBox.wantsLayer = true
        if let layer = infoBox.layer {
            layer.borderWidth = 1.0
            layer.borderColor = NSColor.separatorColor.cgColor
            layer.cornerRadius = 4.0
        }
        
        // Path label
        let pathLabel = NSTextField(frame: NSRect(x: 12, y: 70, width: 576, height: 16))
        pathLabel.stringValue = "Location: \(reportDir.path)"
        pathLabel.isBezeled = false
        pathLabel.drawsBackground = false
        pathLabel.isEditable = false
        pathLabel.isSelectable = true
        pathLabel.font = NSFont.systemFont(ofSize: 10)
        
        // Files to attach
        let filesLabel = NSTextField(frame: NSRect(x: 12, y: 46, width: 576, height: 16))
        filesLabel.stringValue = "📎 Files to attach to your email:"
        filesLabel.isBezeled = false
        filesLabel.drawsBackground = false
        filesLabel.isEditable = false
        filesLabel.font = NSFont.boldSystemFont(ofSize: 10)
        
        let file1Label = NSTextField(frame: NSRect(x: 24, y: 28, width: 564, height: 14))
        file1Label.stringValue = "• Openterface_Status_Results.log"
        file1Label.isBezeled = false
        file1Label.drawsBackground = false
        file1Label.isEditable = false
        file1Label.font = NSFont.systemFont(ofSize: 9)
        
        let file2Label = NSTextField(frame: NSRect(x: 24, y: 12, width: 564, height: 14))
        file2Label.stringValue = "• Openterface_App.log"
        file2Label.isBezeled = false
        file2Label.drawsBackground = false
        file2Label.isEditable = false
        file2Label.font = NSFont.systemFont(ofSize: 9)
        
        infoBox.addSubview(pathLabel)
        infoBox.addSubview(filesLabel)
        infoBox.addSubview(file1Label)
        infoBox.addSubview(file2Label)
        
        // Create container view (increased height for new fields)
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 510))
        containerView.addSubview(orderIDContainer)
        containerView.addSubview(nameContainer)
        containerView.addSubview(supportEmailContainer)
        containerView.addSubview(scrollView)
        containerView.addSubview(infoBox)
        
        // Position OrderID container at top
        orderIDContainer.frame = NSRect(x: 0, y: 480, width: 600, height: 30)
        
        // Position name container below order ID
        nameContainer.frame = NSRect(x: 0, y: 450, width: 600, height: 30)
        
        // Position support email container below name
        supportEmailContainer.frame = NSRect(x: 0, y: 420, width: 600, height: 30)
        
        // Position scrollView in middle
        scrollView.frame = NSRect(x: 0, y: 150, width: 600, height: 250)
        
        // Position infoBox at bottom
        infoBox.frame = NSRect(x: 0, y: 30, width: 600, height: 120)
        
        // Create "Copy to Clipboard" button as a normal button
        let copyToClipboardButton = NSButton(frame: NSRect(x: 310, y: 5, width: 130, height: 20))
        copyToClipboardButton.title = "Copy to Clipboard"
        copyToClipboardButton.bezelStyle = .rounded
        copyToClipboardButton.font = NSFont.systemFont(ofSize: 10)
        copyToClipboardButton.isEnabled = false
        containerView.addSubview(copyToClipboardButton)
        
        // Create "Open Log Folder" button as a normal button
        let openLogFolderButton = NSButton(frame: NSRect(x: 450, y: 5, width: 130, height: 20))
        openLogFolderButton.title = "Open Log Folder"
        openLogFolderButton.bezelStyle = .rounded
        openLogFolderButton.font = NSFont.systemFont(ofSize: 10)
        containerView.addSubview(openLogFolderButton)
        
        // Add to container (increase height for button)
        containerView.frame = NSRect(x: 0, y: 0, width: 600, height: 485)
        
        alert.accessoryView = containerView
        
        // Add main dialog buttons
        alert.addButton(withTitle: "Done")
        
        // Set up copy email button with action
        class CopyEmailAction: NSObject {
            let button: NSButton
            
            init(_ button: NSButton) {
                self.button = button
            }
            
            @objc func doCopyEmail() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("support@openterface.com", forType: .string)
                self.button.title = "Copied!"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.button.title = "Copy"
                }
            }
        }
        
        let copyEmailAction = CopyEmailAction(copyEmailButton)
        copyEmailButton.target = copyEmailAction
        copyEmailButton.action = #selector(CopyEmailAction.doCopyEmail)
        
        // Set up copy to clipboard button action
        class CopyToClipboardAction: NSObject {
            let emailSubject: String
            let emailBody: String
            let orderIDField: NSTextField
            let button: NSButton
            let window: NSWindow
            
            init(subject: String, body: String, orderIDField: NSTextField, button: NSButton, window: NSWindow) {
                self.emailSubject = subject
                self.emailBody = body
                self.orderIDField = orderIDField
                self.button = button
                self.window = window
            }
            
            @objc func doCopyToClipboard() {
                let orderID = orderIDField.stringValue.trimmingCharacters(in: .whitespaces)
                if !orderID.isEmpty {
                    let subjectWithOrderID = "\(emailSubject) - Order ID: \(orderID)"
                    let fullContent = "Subject: \(subjectWithOrderID)\n\n\(emailBody)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fullContent, forType: .string)
                    
                    self.button.title = "Copied!"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        self?.button.title = "Copy to Clipboard"
                    }
                }
                // Keep dialog open
            }
        }
        
        let copyAction = CopyToClipboardAction(subject: emailSubject, body: emailBody, orderIDField: orderIDField, button: copyToClipboardButton, window: alert.window)
        copyToClipboardButton.target = copyAction
        copyToClipboardButton.action = #selector(CopyToClipboardAction.doCopyToClipboard)
        
        // Set up open log folder button action
        class OpenLogFolderAction: NSObject {
            let reportDir: URL
            
            init(_ reportDir: URL) {
                self.reportDir = reportDir
            }
            
            @objc func doOpenLogFolder() {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: reportDir.path)
            }
        }
        
        let openLogAction = OpenLogFolderAction(reportDir)
        openLogFolderButton.target = openLogAction
        openLogFolderButton.action = #selector(OpenLogFolderAction.doOpenLogFolder)
        
        // Update text view and enable/disable button based on Order ID and Name input
        let updateEmailContent = {
            let orderID = orderIDField.stringValue.trimmingCharacters(in: .whitespaces)
            let userName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            copyToClipboardButton.isEnabled = !orderID.isEmpty
            
            let emailSubject = emailSubject
            let emailBody = emailBody
            
            // Build signature with user name
            let signature = !userName.isEmpty ? userName : "Openterface User"
            let bodyWithSignature = emailBody.replacingOccurrences(
                of: "Thank you,\nOpenterface User",
                with: "Thank you,\n\(signature)"
            )
            
            if !orderID.isEmpty {
                let subjectWithOrderID = "\(emailSubject) - Order ID: \(orderID)"
                textView.string = "Subject: \(subjectWithOrderID)\n\n\(bodyWithSignature)"
            } else {
                let subjectWithOrderID = "\(emailSubject) - Order ID: [Please enter above]"
                textView.string = "Subject: \(subjectWithOrderID)\n\n\(bodyWithSignature)"
            }
        }
        
        // Initial update
        updateEmailContent()
        
        // Set up delegate for real-time text field changes
        let delegate = OrderIDTextFieldDelegate()
        delegate.onTextChanged = updateEmailContent
        orderIDField.delegate = delegate
        
        // Set up delegate for name field changes
        let nameDelegate = OrderIDTextFieldDelegate()
        nameDelegate.onTextChanged = updateEmailContent
        nameField.delegate = nameDelegate
        
        let response = alert.runModal()
        
        let orderID = orderIDField.stringValue.trimmingCharacters(in: .whitespaces)
        
        var action: DialogAction = .done
        
        switch response {
        default:
            action = .done
            onStatusMessage("ℹ️ Send the email to: support@openterface.com")
            if !orderID.isEmpty {
                onStatusMessage("📋 Order ID: \(orderID)")
            } else {
                onStatusMessage("⚠️ Warning: Please include your Order ID in the email")
            }
            onStatusMessage("📎 Attach the log files from the folder above")
        }
        
        return (action, orderID)
    }
}
