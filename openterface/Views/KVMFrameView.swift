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
import AVFoundation

struct KVMFrameView: View {
    let captureSession: AVCaptureSession
    let showActiveVideoRect: Bool
    let showGuideOverlay: Bool

    var body: some View {
        ZStack {
            PlayerContainerView(captureSession: captureSession)
                .onTapGesture {
                    if AppStatus.isExit {
                        AppStatus.isExit = false
                    }
                }

            if showActiveVideoRect {
                GeometryReader { _ in
                    let rect = AppStatus.activeVideoRect

                    if rect.width > 0 && rect.height > 0 {
                        Rectangle()
                            .stroke(Color.yellow, lineWidth: 2)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.origin.x + rect.width / 2, y: rect.origin.y + rect.height / 2)
                    }
                }
                .allowsHitTesting(false)
            }

            if showGuideOverlay {
                GeometryReader { geo in
                    let rect = AppStatus.guideHighlightRectNormalized
                    let clampedX = max(0.0, min(1.0, rect.origin.x))
                    let clampedY = max(0.0, min(1.0, rect.origin.y))
                    let clampedW = max(0.0, min(1.0, rect.width))
                    let clampedH = max(0.0, min(1.0, rect.height))

                    if clampedW > 0.001 && clampedH > 0.001 {
                        let overlayRect = CGRect(
                            x: clampedX * geo.size.width,
                            y: clampedY * geo.size.height,
                            width: clampedW * geo.size.width,
                            height: clampedH * geo.size.height
                        )

                        Rectangle()
                            .stroke(Color.red, lineWidth: 3)
                            .frame(width: overlayRect.width, height: overlayRect.height)
                            .position(x: overlayRect.midX, y: overlayRect.midY)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }
}
