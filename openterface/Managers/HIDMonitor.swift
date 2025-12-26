import Foundation
import Combine

final class HIDMonitor: ObservableObject {
    // Minimal published properties used by views/tests; extend as needed
    @Published var targetMouse: String = ""
    @Published var targetMouseButtons: [String] = []
    @Published var targetKeys: [String] = []
    @Published var targetScanCodes: [Int] = []

    init() {
        // placeholder
    }
}
