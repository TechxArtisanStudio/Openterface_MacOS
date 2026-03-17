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

struct ResolutionView: View {
    @ObservedObject var userSettings = UserSettings.shared
    
    let width: String
    let height: String
    let fps: String
    let helpText: String
    
    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: -2) {
                Text("\(width)x\(height)").font(.system(size: 10, weight: .medium))
                HStack(spacing: 2) {
                    Text("\(fps)Hz").font(.system(size: 8, weight: .medium))
                    Text(userSettings.customAspectRatio.toString)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(
                            isAspectRatioMismatch ? .red : .primary // Conditional color
                        )
                }
            }
        }
        .frame(width: 66, alignment: .leading)
        .help(helpText)
    }
    
    private var isAspectRatioMismatch: Bool {
        guard let widthValue = Double(width),
              let heightValue = Double(height) else {
            return false
        }
        var calculatedAspectRatio = widthValue / heightValue
        // Special case for 4096x2160 aspect ratio, it should be 9:5 (1.8)
        if widthValue == 4096 && heightValue == 2160 {
            calculatedAspectRatio = 1.8
        }
        return abs(calculatedAspectRatio - userSettings.customAspectRatio.widthToHeightRatio) > 0.01
    }
}

// Add serial information view
struct SerialInfoView: View {
    let portName: String
    let baudRate: Int
    let processingHz: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cable.connector")
                .font(.system(size: 16))
                .foregroundColor(.primary)
            // always display port name and baud/Hz; ignore configuration state
            Text("\(portName)\n\(baudRate) bps, \(processingHz)Hz")
                .font(.system(size: 9, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .frame(minWidth: 140, minHeight: 30, alignment: .leading)
    }
}

// Caps Lock indicator view - shows a small icon and label with color indicating Caps state
struct CapsLockIndicatorView: View {
    @ObservedObject var serialPortStatus = SerialPortStatus.shared
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: serialPortStatus.isCapLockOn ? "lock.fill" : "lock.open")
                .foregroundColor(serialPortStatus.isCapLockOn ? .blue : .secondary)
                .font(.system(size: 12))
            Text("CAPS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(serialPortStatus.isCapLockOn ? .blue : .secondary)
        }
        .frame(width: 54, alignment: .center)
        .help(serialPortStatus.isCapLockOn ? "Target Caps Lock is ON" : "Target Caps Lock is OFF")
    }
}

// Num Lock indicator view - shows label with color indicating Num Lock state
struct NumLockIndicatorView: View {
    @ObservedObject var serialPortStatus = SerialPortStatus.shared
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: serialPortStatus.isNumLockOn ? "lock.fill" : "lock.open")
                .foregroundColor(serialPortStatus.isNumLockOn ? .blue : .secondary)
                .font(.system(size: 12))
            Text("NUM")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(serialPortStatus.isNumLockOn ? .blue : .secondary)
        }
        .frame(width: 54, alignment: .center)
        .help(serialPortStatus.isNumLockOn ? "Target Num Lock is ON" : "Target Num Lock is OFF")
    }
}

// Scroll Lock indicator view - shows label with color indicating Scroll Lock state
struct ScrollLockIndicatorView: View {
    @ObservedObject var serialPortStatus = SerialPortStatus.shared
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: serialPortStatus.isScrollOn ? "lock.fill" : "lock.open")
                .foregroundColor(serialPortStatus.isScrollOn ? .blue : .secondary)
                .font(.system(size: 12))
            Text("SCR")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(serialPortStatus.isScrollOn ? .blue : .secondary)
        }
        .frame(width: 54, alignment: .center)
        .help(serialPortStatus.isScrollOn ? "Target Scroll Lock is ON" : "Target Scroll Lock is OFF")
    }
}

