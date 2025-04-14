
import SwiftUI

// 窗口工具类，提供窗口相关的通用功能
final class WindowUtils {
    // 单例模式
    static let shared = WindowUtils()
    
    private init() {}
    
    /// 显示屏幕比例选择器窗口
    /// - Parameter completion: 选择完成后的回调，传入是否需要更新窗口
    func showAspectRatioSelector(completion: @escaping (Bool) -> Void) {
        guard let window = NSApplication.shared.mainWindow else {
            completion(false)
            return
        }
        
        let alert = NSAlert()
        alert.messageText = "选择屏幕比例"
        alert.informativeText = "请选择您希望使用的屏幕比例："
        
        let aspectRatioPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 25))
        
        // 添加所有预设比例选项
        for option in AspectRatioOption.allCases {
            aspectRatioPopup.addItem(withTitle: option.rawValue)
        }
        
        // 设置当前选中的比例
        if let index = AspectRatioOption.allCases.firstIndex(of: UserSettings.shared.customAspectRatio) {
            aspectRatioPopup.selectItem(at: index)
        }
        
        alert.accessoryView = aspectRatioPopup
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let selectedIndex = aspectRatioPopup.indexOfSelectedItem
            if selectedIndex >= 0 && selectedIndex < AspectRatioOption.allCases.count {
                // 保存用户选择
                UserSettings.shared.customAspectRatio = AspectRatioOption.allCases[selectedIndex]
                UserSettings.shared.useCustomAspectRatio = true
                
                // 通知调用方更新窗口尺寸
                completion(true)
            } else {
                completion(false)
            }
        } else {
            completion(false)
        }
    }
    
    /// 直接调用系统通知更新窗口大小
    func updateWindowSizeThroughNotification() {
        NotificationCenter.default.post(name: Notification.Name.updateWindowSize, object: nil)
    }
}

// 扩展通知名称，便于全局访问
extension Notification.Name {
    static let updateWindowSize = Notification.Name("UpdateWindowSizeNotification")
} 
