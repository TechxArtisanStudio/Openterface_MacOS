//
//  ToolBarView.swift
//  openterface
//
//  Created by Shawn Ling on 2024/9/6.
//

import SwiftUI

struct ResolutionView: View {
    let width: Int
    let height: Int
    let fps: Int
    let version: String
    
    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: -2) {
                Text("\(width)")
                    .font(.system(size: 8, weight: .medium))
                Text("\(height)")
                    .font(.system(size: 8, weight: .medium))
            }
            Text("\(fps)")
                .font(.system(size: 16, weight: .medium))
            VStack(alignment: .leading, spacing: -2) {
                Text(" ")
                    .font(.system(size: 8, weight: .medium))
                Text("\(version)")
                    .font(.system(size: 8, weight: .medium))
            }
        }
        .frame(width: 120, alignment: .leading)  // 调整宽度以适应toolbar
    }
}
