//
//  ToolBarView.swift
//  openterface
//
//  Created by Shawn Ling on 2024/9/6.
//

import SwiftUI

struct ResolutionView: View {
    let width: String
    let height: String
    let fps: String
    
    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: -2) {
                Text("\(width)")
                    .font(.system(size: 8, weight: .medium))
                Text("\(fps)")
                    .font(.system(size: 8, weight: .medium))
            }
            Text("\(height)")
                .font(.system(size: 16, weight: .medium))
        }
        .frame(width: 66, alignment: .leading)
    }
}

// Add serial information view
struct SerialInfoView: View {
    let portName: String
    let baudRate: Int
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cable.connector")
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: -2) {
                Text("\(portName)")
                    .font(.system(size: 9, weight: .medium))
                Text("\(baudRate) ")
                    .font(.system(size: 9, weight: .medium))
            }
        }
        .frame(width: 120, alignment: .leading)
    }
}
