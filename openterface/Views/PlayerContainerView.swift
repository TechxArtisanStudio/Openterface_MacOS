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

struct PlayerContainerView: NSViewRepresentable {
    let captureSession: AVCaptureSession
    @ObservedObject private var userSettings = UserSettings.shared
    
    init(captureSession: AVCaptureSession) {
        self.captureSession = captureSession
    }

    func makeNSView(context: Context) -> PlayerView {
        Logger.shared.log(content: "🏗️ 创建PlayerView")
        return PlayerView(captureSession: captureSession)
    }

    func updateNSView(_ nsView: PlayerView, context: Context) {
        // 当全屏状态变化时，更新视图布局
        if context.transaction.animation != nil {
            Logger.shared.log(content: "🔄 PlayerContainerView更新 - 全屏状态: \(userSettings.isFullScreen)")
            
            // 使用私有方法更新视图布局
            if let updateMethod = nsView.value(forKey: "updateViewLayout") as? () -> Void {
                updateMethod()
            }
        }
    }
}

