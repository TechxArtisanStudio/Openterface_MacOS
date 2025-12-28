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

struct DiagnosticsView: View {
    @ObservedObject var viewModel: DiagnosticsViewModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @State private var showLoggingAlert = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device Diagnostics")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Step-by-step hardware and connection testing")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                        .opacity(0.6)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Close diagnostics")
            }
            .padding(16)
            .background(colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color(.sRGB, red: 0.7, green: 0.7, blue: 0.7))
            .borderBottom()
            
            HStack(spacing: 0) {
                // Left sidebar - Test steps
                VStack(alignment: .leading, spacing: 0) {
                    Text("Tests")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(12)
                    
                    testListView()
                    
                    Spacer()
                    
                    // Progress indicator
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Progress")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("\(viewModel.completedTestCount)/\(viewModel.visibleTestSteps.count)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        
                        ProgressView(value: Double(viewModel.completedTestCount), total: Double(viewModel.visibleTestSteps.count))
                            .progressViewStyle(LinearProgressViewStyle(tint: viewModel.allTestsCompleted ? .green : .blue))
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor))
                }
                .frame(width: 200)
                .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(.sRGB, red: 0.98, green: 0.98, blue: 0.99))
                .borderRight()
                
                // Right content area
                VStack(spacing: 0) {
                    // Current test info
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(viewModel.currentStep.title)
                                    .font(.system(size: 16, weight: .semibold))
                                Text(viewModel.currentStep.description)
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(viewModel.connectionStateImageName)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 120)
                                .padding(12)
                                .background(Color(.sRGB, red: 0.65, green: 0.65, blue: 0.65))
                                .cornerRadius(8)

                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)
                    }
                    .padding(16)
                    
                    // Logging section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundColor(.secondary)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Diagnostic Logging")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(viewModel.logFilePath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            
                            Spacer()
                            
                            Button(action: {
                                if viewModel.isLoggingEnabled {
                                    viewModel.disableLogging()
                                } else {
                                    viewModel.enableLogging()
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: viewModel.isLoggingEnabled ? "checkmark.circle.fill" : "circle")
                                    Text(viewModel.isLoggingEnabled ? "Logging On" : "Enable")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundColor(viewModel.isLoggingEnabled ? .green : .secondary)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                    }
                    .padding(16)
                    .padding(.top, -8)
                    
                    // Status messages area
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Status & Results")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Button(action: {
                                let allMessages = viewModel.statusMessages.joined(separator: "\n")
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(allMessages, forType: .string)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 11))
                                    Text("Copy All")
                                        .font(.system(size: 11))
                                }
                                .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)
                            .help("Copy all status messages to clipboard")
                        }
                        .padding(12)
                        .borderBottom()
                        
                        ScrollViewReader { scrollProxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    if viewModel.statusMessages.isEmpty {
                                        VStack {
                                            Image(systemName: "info.circle")
                                                .font(.system(size: 32))
                                                .foregroundColor(.secondary)
                                                .opacity(0.5)
                                            
                                            Text("No tests run yet")
                                                .font(.system(size: 13))
                                                .foregroundColor(.secondary)
                                            
                                            Text("Select a test and click 'Run Test' to begin")
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                                .opacity(0.7)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(32)
                                    } else {
                                        ForEach(viewModel.statusMessages.indices, id: \.self) { index in
                                            Text(viewModel.statusMessages[index])
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundColor(colorScheme == .dark ? .white : .black)
                                                .lineLimit(nil)
                                                .textSelection(.enabled)
                                                .id(index)
                                        }
                                    }
                                }
                                .padding(12)
                            }
                            .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(.sRGB, red: 0.98, green: 0.98, blue: 0.99))
                            .onChange(of: viewModel.statusMessages.count) { _ in
                                // Scroll to the last message
                                if !viewModel.statusMessages.isEmpty {
                                    let lastIndex = viewModel.statusMessages.count - 1
                                    scrollProxy.scrollTo(lastIndex, anchor: .bottom)
                                }
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // Defect report button - shows when device is detected as defective
                    // Triggered by either Target Black Cable test failure or after Stress test failure + Target Port Checking completion
                    let stressTestFailed = viewModel.stepResults[.stressTest] == false
                    let targetPortCheckingCompleted = viewModel.stepResults[.targetPortChecking] != nil
                    let targetBlackCableFailed = viewModel.stepResults[.targetBlackCableTest] == false
                    
                    if viewModel.isDefectiveUnitDetected && (targetBlackCableFailed || (stressTestFailed && targetPortCheckingCompleted)) {
                        VStack(spacing: 0) {
                            Divider()
                            
                            Button(action: {
                                viewModel.sendDefectReportEmail()
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.white)
                                        .font(.system(size: 16))
                                    Text("Send Defect Report to Support")
                                        .fontWeight(.semibold)
                                        .foregroundColor(.white)
                                    Spacer()
                                    Image(systemName: "envelope.fill")
                                        .foregroundColor(.white)
                                        .font(.system(size: 16))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(14)
                                .background(Color.red)
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            
                            Divider()
                        }
                    }
                    
                    // Special status for stress test
                    if viewModel.currentStep == .stressTest && viewModel.stressTestProgress > 0 {
                        VStack(spacing: 8) {
                            HStack {
                                Text(viewModel.stressTestStatus)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(String(format: "%.0f%%", viewModel.stressTestProgress * 100))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            
                            ProgressView(value: viewModel.stressTestProgress)
                                .progressViewStyle(LinearProgressViewStyle())
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                        .padding(16)
                    }
                    
                    // Action buttons
                    HStack(spacing: 12) {
                        Button(action: {
                            viewModel.restartDiagnostics()
                        }) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Restart")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(viewModel.isTestRunning)
                        
                        Spacer()
                        
                        Button(action: {
                            viewModel.moveToPreviousStep()
                        }) {
                            HStack {
                                Image(systemName: "chevron.left")
                                Text("Previous")
                            }
                        }
                        .disabled(viewModel.currentStep.rawValue == 0 || viewModel.isTestRunning)
                        
                        Button(action: {
                            viewModel.moveToNextStep()
                        }) {
                            HStack {
                                Text("Next")
                                Image(systemName: "chevron.right")
                            }
                        }
                        .disabled(viewModel.currentStep.rawValue >= DiagnosticsViewModel.DiagnosticTestStep.allCases.count - 1 || viewModel.isTestRunning)
                        
                        Spacer()
                        
                        // Run test button - changes based on current step
                        runTestButton()
                            .frame(maxWidth: 150)
                        
                        Button(action: {
                            if viewModel.isAutoChecking {
                                viewModel.stopAutoCheck()
                            } else {
                                viewModel.startAutoCheck()
                            }
                        }) {
                            HStack {
                                if viewModel.isAutoChecking {
                                    Image(systemName: "stop.circle.fill")
                                } else {
                                    Image(systemName: "play.circle.fill")
                                }
                                Text(viewModel.isAutoChecking ? "Stop Auto" : "Auto Check")
                            }
                            .frame(maxWidth: 130)
                        }
                        .disabled(viewModel.isTestRunning)
                    }
                    .padding(16)
                    .background(colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color(.sRGB, red: 0.7, green: 0.7, blue: 0.7))
                    .borderTop()
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
        .alert("Enable Diagnostic Logging", isPresented: $showLoggingAlert) {
            Button("Enable Both") {
                viewModel.enableLogging()
                viewModel.enableSerialLogging()
            }
            Button("Enable Logging Only") {
                viewModel.enableLogging()
            }
            Button("Later", role: .cancel) { }
        } message: {
            Text("Enable logging to save detailed diagnostics for troubleshooting.\n\nLog file: \(viewModel.logFilePath)\n\nWould you like to enable serial data logging as well?")
        }
    }
    
    @ViewBuilder
    func testStepButton(_ step: DiagnosticsViewModel.DiagnosticTestStep) -> some View {
        // Only show Target Port Checking (step 8) if Stress Test (step 7) failed
        if step == .targetPortChecking && viewModel.stepResults[.stressTest] != false {
            EmptyView()
        } else {
            Button(action: {
                viewModel.currentStep = step
            }) {
                HStack(spacing: 8) {
                    // Status icon
                    if let result = viewModel.stepResults[step] {
                        if result {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 14, weight: .semibold))
                        } else {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 14, weight: .semibold))
                        }
                    } else {
                        Image(systemName: "circle")
                            .foregroundColor(.secondary)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text("Step \(step.rawValue + 1)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(viewModel.currentStep == step ? Color.blue.opacity(0.15) : Color.clear)
                .cornerRadius(6)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    @ViewBuilder
    func testListView() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(DiagnosticsViewModel.DiagnosticTestStep.allCases, id: \.self) { step in
                    testStepButton(step)
                }
            }
            .padding(8)
        }
    }
    
    @ViewBuilder
    private func runTestButton() -> some View {
        switch viewModel.currentStep {
        case .overallConnection:
            Button(action: {
                viewModel.checkConnectedDevices()
            }) {
                HStack {
                    if viewModel.isTestRunning {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "checkmark")
                    }
                    Text(viewModel.isTestRunning ? "Checking..." : "Check Now")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(viewModel.isTestRunning)
            
        case .serialConnection:
            Button(action: {
                viewModel.testSerialConnection()
            }) {
                HStack {
                    if viewModel.isTestRunning {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "cable.connector")
                    }
                    Text(viewModel.isTestRunning ? "Testing..." : "Test Connection")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(viewModel.isTestRunning)
            
        case .hostPlugAndPlayTest:
            Button(action: {
                viewModel.testHostPlugAndPlay()
            }) {
                HStack {
                    if viewModel.isTestRunning {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.triangle.swap")
                    }
                    Text(viewModel.isTestRunning ? "Testing..." : "Start Test")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(viewModel.isTestRunning)
            
        case .targetBlackCableTest:
            Button(action: {
                viewModel.testTargetBlackCable()
            }) {
                HStack {
                    if viewModel.isTestRunning {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.triangle.swap")
                    }
                    Text(viewModel.isTestRunning ? "Testing..." : "Start Test")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(viewModel.isTestRunning)
            
        case .resetFactoryBaudrate:
            Button(action: {
                viewModel.resetToFactoryBaudrate()
            }) {
                HStack {
                    if viewModel.isTestRunning {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.uturn.left")
                    }
                    Text(viewModel.isTestRunning ? "Resetting..." : "Reset Now")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(viewModel.isTestRunning)
            
        case .changeTo115200:
            Button(action: {
                viewModel.changeBaudrateTo115200()
            }) {
                HStack {
                    if viewModel.isTestRunning {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.up.right")
                    }
                    Text(viewModel.isTestRunning ? "Changing..." : "Change Now")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(viewModel.isTestRunning)
            
        case .stressTest:
            Button(action: {
                viewModel.runStressTest()
            }) {
                HStack {
                    if viewModel.isTestRunning {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "speedometer")
                    }
                    Text(viewModel.isTestRunning ? "Running..." : "Start Test")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(viewModel.isTestRunning)
            
        case .targetPortChecking:
            Button(action: {
                viewModel.testtargetPortChecking()
            }) {
                HStack {
                    if viewModel.isTestRunning {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "cable.connector")
                    }
                    Text(viewModel.isTestRunning ? "Detecting..." : "Detect Devices")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(viewModel.isTestRunning)
        }
    }
}

// Helper extensions for borders
extension View {
    func borderTop() -> some View {
        overlay(alignment: .top) {
            Divider()
                .offset(y: 0)
        }
    }
    
    func borderBottom() -> some View {
        overlay(alignment: .bottom) {
            Divider()
                .offset(y: 0)
        }
    }
    
    func borderRight() -> some View {
        overlay(alignment: .trailing) {
            Divider()
                .offset(x: 0)
                .rotationEffect(.degrees(90))
        }
    }
    
}

#Preview {
    DiagnosticsView(viewModel: DiagnosticsViewModel())
        .frame(width: 900, height: 600)
}
