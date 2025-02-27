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
import Foundation
import ORSSerial

struct ResetFactoryView: View {
    
    let smp = SerialPortManager.shared
    
    @Environment(\.colorScheme) var colorScheme
    @State private var isResetting = false
    @State private var isCompleted = false
    @State private var currentStep = 0
    @State private var isHovering = false
    @State private var serialPortStatus: String = ""
    @State private var hasError: Bool = false
    @State private var stepMessages = [
        "Preparing to reset serial to factory settings...",
        "1. Checking serial port connection",
        "2. Starting serial to factory reset",
        "3. Enabling RTS signal",
        "4. Disabling RTS signal",
        "5. Closing serial port",
        "6. Reopening serial port",
        "7, ReBoot serial port",
        "Factory reset completed!"
    ]
    
    // ID for auto-scrolling
    @Namespace private var bottomID
    
    var body: some View {
        ZStack {
            // Background
            colorScheme == .dark ? Color.black : Color.white
            
            VStack(alignment: .center, spacing: 30) {
                Spacer()
                    .frame(height: 20)
                
                // Icon
                Image(systemName: isCompleted ? "checkmark.circle" : (hasError ? "exclamationmark.circle" : "arrow.triangle.2.circlepath"))
                    .font(.system(size: 50))
                    .foregroundColor(isCompleted ? .green : (hasError ? .red : .blue))
                    .opacity(0.9)
                    .padding(.bottom, 10)
                
                // Title
                Text(isCompleted ? "Factory Reset Complete" : (hasError ? "Factory Reset Failed" : "Factory Reset"))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(hasError ? .red : .primary)
                    .padding(.bottom, 5)
                
                // Description
                if !isCompleted && !isResetting {
                    Text("When your mouse or keyboard stops working, you can try...")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 20)
                    Text("This operation will restore the serial to factory settings")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 20)
                }
                
                // Current step display
                if isResetting || isCompleted {
                    // Progress bar
                    ProgressView(value: Double(currentStep), total: Double(stepMessages.count - 1))
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(width: 280)
                        .padding(.bottom, 15)
                    
                    // Error message box
                    if hasError {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text("Connection Error")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.red)
                            }
                            
                            Text("Cannot connect to device serial port. Please check:")
                                .font(.system(size: 14))
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("• Device is properly connected")
                                Text("• USB cable is working")
                                Text("• Device is powered on")
                                Text("• Drivers are installed")
                            }
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            
                            Text("Click Retry to attempt connection again")
                                .font(.system(size: 13, weight: .medium))
                                .padding(.top, 5)
                        }
                        .padding(15)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.red.opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.red.opacity(0.3), lineWidth: 1)
                                )
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 15)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: hasError)
                    }
                    
                    // Steps list
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(0..<min(currentStep + 1, stepMessages.count), id: \.self) { index in
                                    HStack(spacing: 12) {
                                        // Step status icon
                                        ZStack {
                                            Circle()
                                                .fill(index == currentStep && !isCompleted ? 
                                                    (hasError && index == 1 ? Color.red.opacity(0.15) : Color.blue.opacity(0.15)) 
                                                    : Color.green.opacity(0.15))
                                                .frame(width: 26, height: 26)
                                            
                                            if index == currentStep && !isCompleted {
                                                if hasError && index == 1 {
                                                    // Error icon
                                                    Image(systemName: "exclamationmark.triangle")
                                                        .font(.system(size: 12))
                                                        .foregroundColor(.red)
                                                } else if isResetting {
                                                    Image(systemName: "arrow.triangle.2.circlepath")
                                                        .font(.system(size: 12))
                                                        .foregroundColor(.blue)
                                                        .rotationEffect(.degrees(isResetting ? 360 : 0))
                                                        .animation(Animation.linear(duration: 2).repeatForever(autoreverses: false), value: isResetting)
                                                } else {
                                                    ProgressView()
                                                        .scaleEffect(0.6)
                                                }
                                            } else {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundColor(.green)
                                            }
                                        }
                                        
                                        // Step text
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(stepMessages[index])
                                                .font(.system(size: 14))
                                                .foregroundColor(index == currentStep && !isCompleted ? .primary : .secondary)
                                            
                                            // Display serial port status (only at step 1 when status is available)
                                            if index == 1 && !serialPortStatus.isEmpty {
                                                Text(serialPortStatus)
                                                    .font(.system(size: 12))
                                                    .foregroundColor(serialPortStatus.contains("not connected") || serialPortStatus.contains("not open") || hasError ? .red : .green)
                                                    .padding(.top, 2)
                                                    .padding(.bottom, 4)
                                                    .padding(.horizontal, 8)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 4)
                                                            .fill(Color.gray.opacity(0.1))
                                                    )
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(index == currentStep && !isCompleted ? Color.blue.opacity(0.08) : Color.clear)
                                    )
                                    .id(index) // Set ID for each step
                                    
                                    // Add bottom ID marker for the last step
                                    if index == currentStep {
                                        Color.clear
                                            .frame(height: 1)
                                            .id(bottomID)
                                    }
                                }
                            }
                            .padding(.horizontal, 10)
                        }
                        .frame(width: 320, height: 180)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                        .onChange(of: currentStep) { _ in
                            // Auto-scroll to bottom when step changes
                            withAnimation {
                                scrollProxy.scrollTo(bottomID, anchor: .bottom)
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
                
                // Post-completion guidance
                if isCompleted {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("If the issue persists, try physically disconnecting it by following these steps:")
                            .font(.system(size: 16, weight: .medium))
                            .padding(.bottom, 5)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(nil)
                        
                        
                        ForEach(["1. Close the software", "2. Disconnect hardware", "3. Wait 3 seconds", "4. Reconnect hardware", "5. Restart software"], id: \.self) { step in
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 14))
                                Text(step)
                                    .font(.system(size: 15))
                            }
                        }
                    }
                    .padding(.vertical, 15)
                    .padding(.horizontal, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.green.opacity(0.1))
                    )
                    .padding(.bottom, 20)
                }
                
                // Buttons
                HStack(spacing: 15) {
                    // Main button
                    ColorButton(
                        color: isCompleted ? .green : (isResetting ? (hasError ? .orange : .gray) : .blue),
                        title: isCompleted ? "Back" : (isResetting ? (hasError ? "Retry Connection" : "Resetting...") : "Start Factory Reset"),
                        textColor: .white,
                        action: {
                        if isCompleted {
                            // Reset state
                            isCompleted = false
                            isResetting = false
                            currentStep = 0
                            hasError = false
                        } else {
                            resetFactory()
                        }
                        
                    })
                    .frame(width: 200)
                    .disabled(isResetting && !isCompleted && !hasError)

                    ColorButton(
                        color: .purple,
                        title: "Reboot Serial",
                        textColor: .white,
                        action: {
                        softRebootSerial()
                        
                    })
                    .frame(width: 120)
                    
                    // Cancel button (only shown in error state)
                    // if hasError {
                    //     Button(action: {
                    //         // Cancel operation, reset state
                    //         isResetting = false
                    //         hasError = false
                    //         currentStep = 0
                    //         serialPortStatus = ""
                    //     }) {
                    //         Text("Cancel")
                    //             .font(.system(size: 16, weight: .medium))
                    //             .frame(width: 100, height: 46)
                    //             .background(Color.gray.opacity(0.3))
                    //             .foregroundColor(.white)
                    //             .cornerRadius(23)
                    //     }
                    // }
                }
                .padding(.bottom, isCompleted ? 30 : 10)
                
                // Spacer to maintain consistent window size
                Spacer(minLength: isCompleted ? 120 : 80)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, isCompleted ? 20 : 0)
        }
        .frame(width: 500, height: 760) // Increased height for new buttons
    }
    
    func softRebootSerial() {
        smp.resetHidChip()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            smp.closeSerialPort()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                smp.tryOpenSerialPort()
            }
        }
    }

    func resetFactory() {
        isResetting = true
        currentStep = 0
        serialPortStatus = ""
        hasError = false  // Reset error state
        
        // Use actual SerialPortManager for factory reset
        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Check serial port connection
            DispatchQueue.main.async {
                currentStep = 1
                
                
                // Add delay to simulate checking process
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let port = smp.serialPort, port.isOpen else {
                        // Update serial port status
                        serialPortStatus = "Serial port not connected or not open"
                        // Set error state
                        hasError = true
                        // Don't reset isResetting state, stay at current step
                        // Just update UI to show error
                        return
                    }
                    
                    // Clear error state
                    hasError = false
                    
                    // Update serial port status
                    serialPortStatus = "Serial port connected, status normal\n (Port: \(port.path))"
                    
                    // Add more serial port info
                    if let baudRate = port.baudRate as? NSNumber {
                        serialPortStatus += "\nBaud rate: \(baudRate) bps"
                    }
                    
                    // Check data bits, stop bits and parity
                    serialPortStatus += "\nData bits: \(port.numberOfDataBits)"
                    serialPortStatus += " | Stop bits: \(port.numberOfStopBits == 1 ? "1" : "2")"
                    
                    // Parity info
                    let parityString: String
                    switch port.parity {
                    case .none: parityString = "None"
                    case .odd: parityString = "Odd"
                    case .even: parityString = "Even"
                    default: parityString = "Unknown"
                    }
                    serialPortStatus += " | Parity: \(parityString)"
                    
                    // Only continue with subsequent steps if no errors
                    continueResetProcess()
                }
            }
        }
    }
    
    // Extract subsequent steps to a separate method, only called when serial port connection is normal
    private func continueResetProcess() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            currentStep = 2
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                currentStep = 3
                
                smp.isRight = false
                smp.raiseRTS()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    currentStep = 4
                    smp.lowerRTS()
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        currentStep = 5
                        smp.closeSerialPort()
                        
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            currentStep = 6
                            smp.tryOpenSerialPort(priorityBaudrate: SerialPortManager.ORIGINAL_BAUDRATE)
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                                currentStep = 7
                                softRebootSerial()
                                
                                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                                    currentStep = 8
                                    
                                    isResetting = false
                                    isCompleted = true
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// Color button component
struct ColorButton: View {
    var color: Color
    var title: String
    var textColor: Color = .white
    var action: (() -> Void)? = nil
    @State private var isHovering = false
    
    var body: some View {
        Button(action: {
            // Execute the passed click action
            action?()
        }) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(textColor)
                .padding(.vertical, 10)
                .padding(.horizontal, 15)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [color, color.opacity(0.8)]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .cornerRadius(8)
                .shadow(color: color.opacity(0.4), radius: 3, x: 0, y: 2)
                .scaleEffect(isHovering ? 1.05 : 1.0)
                .animation(.spring(response: 0.2), value: isHovering)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
