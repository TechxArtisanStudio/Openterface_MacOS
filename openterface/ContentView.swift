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

struct ContentView: View {
    @StateObject var viewModel = PlayerViewModel() // Ensures the view model is initialized once
    @State private var showInputOverlay = AppStatus.showInputOverlay
    
    @Environment(\.controlActiveState) var controlActiveState
    
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    
    init() {
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PlayerContainerView(captureSession: viewModel.captureSession)
                .onTapGesture {
                    // click in windows
                    if AppStatus.isExit {
                        AppStatus.isExit = false
                    }
                }
            
            if showInputOverlay {
                InputOverlayView()
                    .padding()
            }
        }
        .onAppear {
            viewModel.checkAuthorization() // Perform authorization check when the view appears
        }
        .onReceive(timer) { _ in
            if showInputOverlay != AppStatus.showInputOverlay {
                showInputOverlay = AppStatus.showInputOverlay
            }
        }
    }
}

// MARK: - Input Overlay

struct InputOverlayView: View {
    @StateObject private var inputMonitor = InputMonitorManager()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Host input section
            VStack(alignment: .leading, spacing: 2) {
                Text("Host Input:")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                Text("  Position: \(Int(inputMonitor.mouseLocation.x)), \(Int(inputMonitor.mouseLocation.y))")
                    .font(.system(.caption, design: .monospaced))
                Text("  Keys: \(inputMonitor.hostKeys)")
                    .font(.system(.caption, design: .monospaced))
            }
            
            Divider()
                .background(Color.white.opacity(0.3))
            
            // Target output section
            VStack(alignment: .leading, spacing: 2) {
                Text("Target Output:")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                Text("  Position: \(inputMonitor.targetMouse)")
                    .font(.system(.caption, design: .monospaced))
                Text("  Keys: \(inputMonitor.targetKeys)")
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .fixedSize()
        .padding(8)
        .background(Color.black.opacity(0.6))
        .foregroundColor(.white)
        .cornerRadius(8)
        .allowsHitTesting(false) // Pass clicks through to the underlying view
    }
}

