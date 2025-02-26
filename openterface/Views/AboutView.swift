import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image("Target_icon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 100, height: 100)
            
            Text("Openterface Mini-KVM")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Version 1.0.0")
                .font(.headline)
            
            Text("© 2024 Openterface. All rights reserved.")
                .font(.subheadline)
            
            Text("Openterface Mini-KVM is a software for controlling multiple computers, allowing you to seamlessly switch between multiple devices using a single keyboard and mouse.")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Spacer()
            
            Button("Visit Website") {
                if let url = URL(string: "https://www.openterface.com") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(BorderedButtonStyle())
            .padding(.bottom)
        }
        .padding()
        .frame(width: 400, height: 400)
    }
}
