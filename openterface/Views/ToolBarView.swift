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
