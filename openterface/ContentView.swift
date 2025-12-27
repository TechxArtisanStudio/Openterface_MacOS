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
    @State private var showMiniIndicator: Bool = false
    @State private var miniMousePos: CGPoint = CGPoint(x: 0.5, y: 0.5) // normalized (0..1), origin: top-left
    @State private var isMouseInTarget: Bool = false
    
    @Environment(\.controlActiveState) var controlActiveState
    
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    
    init() {
    }

    var body: some View {
        ZStack {
            // Parallel overlay indicator: show orange dot at top-center when active
            if overlayActive {
                GeometryReader { geo in
                    // Show either the small orange dot (indicator) or a mini black rectangle
                    if showMiniIndicator {
                        // Determine video aspect ratio
                        let videoDims = DependencyContainer.shared.resolve(VideoManagerProtocol.self).dimensions
                        let videoW = CGFloat(videoDims.width)
                        let videoH = CGFloat(videoDims.height)
                        let aspect = (videoH > 0 && videoW > 0) ? (videoW / videoH) : (16.0 / 9.0)

                        let baseWidth: CGFloat = 160.0
                        let rectWidth = min(baseWidth, geo.size.width - 20)
                        let rectHeight = rectWidth / aspect

                        ZStack(alignment: .topLeading) {
                            PlayerContainerView(captureSession: viewModel.captureSession)
                                .frame(width: rectWidth, height: rectHeight)
                                .cornerRadius(4)
                                .clipped()

                            // Red/gray dot showing normalized mouse position inside the mini rectangle
                            let dotSize: CGFloat = 6.0
                                Circle()
                                    .fill(isMouseInTarget ? Color.red : Color.gray)
                                .frame(width: dotSize, height: dotSize)
                                .offset(x: max(0, min(rectWidth - dotSize, rectWidth * miniMousePos.x - dotSize / 2)),
                                        y: max(0, min(rectHeight - dotSize, rectHeight * miniMousePos.y - dotSize / 2)))
                        }
                        .position(x: geo.size.width / 2, y: rectHeight / 2 + 12)
                        .onTapGesture {
                            // single tap toggles back to orange dot
                            showMiniIndicator = false
                        }
                    } else {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 12, height: 12)
                            .position(x: geo.size.width / 2, y: 12)
                            // Single click: show mini indicator
                            .onTapGesture {
                                showMiniIndicator = true
                            }
                            // Double-click to exit parallel mode
                            .onTapGesture(count: 2) {
                                DispatchQueue.main.async {
                                    let pm = DependencyContainer.shared.resolve(ParallelManagerProtocol.self)
                                    pm.exitParallelMode()
                                }
                            }
                            .contentShape(Circle())
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .remoteMouseMoved)) { notif in
                    guard let info = notif.userInfo,
                          let x = info["x"] as? Double,
                          let y = info["y"] as? Double else { return }
                    DispatchQueue.main.async {
                        // Update normalized mouse position (origin: top-left)
                        miniMousePos = CGPoint(x: CGFloat(x), y: CGFloat(y))
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .mouseEnteredTarget)) { _ in
                    DispatchQueue.main.async {
                        isMouseInTarget = true
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .mouseExitedTarget)) { _ in
                    DispatchQueue.main.async {
                        isMouseInTarget = false
                    }
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

