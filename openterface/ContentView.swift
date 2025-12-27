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
    @State private var overlayActive = AppStatus.showParallelOverlay
    
    @Environment(\.controlActiveState) var controlActiveState
    
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    
    init() {
    }

    var body: some View {
        ZStack {
            // Parallel overlay indicator: show orange dot at top-center when active
            if overlayActive {
                GeometryReader { geo in
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 12, height: 12)
                        .position(x: geo.size.width / 2, y: 12)
                        // Allow hit testing so we can detect double-clicks to exit parallel mode
                        .onTapGesture(count: 2) {
                            DispatchQueue.main.async {
                                let pm = DependencyContainer.shared.resolve(ParallelManagerProtocol.self)
                                pm.exitParallelMode()
                            }
                        }
                        .contentShape(Circle())
                }
                .ignoresSafeArea()
            }else{
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
        }
        .onAppear {
            viewModel.checkAuthorization() // Perform authorization check when the view appears
        }
        .onReceive(timer) { _ in
            if showInputOverlay != AppStatus.showInputOverlay {
                showInputOverlay = AppStatus.showInputOverlay
            }
            if overlayActive != AppStatus.showParallelOverlay {
                overlayActive = AppStatus.showParallelOverlay
            }
        }
    }
}

