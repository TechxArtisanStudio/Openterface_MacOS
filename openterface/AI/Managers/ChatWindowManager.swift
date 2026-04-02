import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class ChatWindowManager: NSObject, ChatWindowManagerProtocol, NSWindowDelegate {
    static let shared = ChatWindowManager()

    private var chatWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private let dockGap: CGFloat = 8
    private var isProgrammaticDockUpdate = false
    private var pendingDockCommit: DispatchWorkItem?
    private let logger = DependencyContainer.shared.resolve(LoggerProtocol.self)

    private func scalarSummary(_ value: CGFloat) -> String {
        guard value.isFinite else {
            if value.isNaN {
                return "nan"
            }
            return value.sign == .minus ? "-inf" : "inf"
        }

        return String(Int(value.rounded()))
    }

    private func frameSummary(_ rect: NSRect) -> String {
        let x = scalarSummary(rect.origin.x)
        let y = scalarSummary(rect.origin.y)
        let width = scalarSummary(rect.size.width)
        let height = scalarSummary(rect.size.height)
        return "x=\(x) y=\(y) w=\(width) h=\(height)"
    }

    private override init() {
        super.init()
    }

    func showChatWindow() {
        if let window = chatWindow {
            window.makeKeyAndOrderFront(nil)
            updateDockPosition(animated: false)
            UserSettings.shared.isChatWindowVisible = true
            return
        }

        guard let mainWindow = resolveMainWindow() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showChatWindow()
            }
            return
        }

        let rootView = ChatWindowRootView(chatManager: ChatManager.shared)
        let controller = NSHostingController(rootView: rootView)
        let width = max(320, CGFloat(UserSettings.shared.chatWindowWidth))
        let frame = NSRect(x: mainWindow.frame.maxX + dockGap, y: mainWindow.frame.minY, width: width, height: mainWindow.frame.height)

        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Chat"
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("openterface_chat_companion")
        window.minSize = NSSize(width: 320, height: 420)
        window.delegate = self

        chatWindow = window
        UserSettings.shared.isChatWindowVisible = true
        updateDockPosition(animated: false)
        window.makeKeyAndOrderFront(nil)

        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            Task { @MainActor in
                self.chatWindow = nil
                UserSettings.shared.isChatWindowVisible = false
            }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(handleChatWindowDidResize(_:)), name: NSWindow.didResizeNotification, object: window)
    }

    func hideChatWindow() {
        chatWindow?.orderOut(nil)
        UserSettings.shared.isChatWindowVisible = false
    }

    func toggleChatWindow() {
        if let window = chatWindow, window.isVisible {
            hideChatWindow()
        } else {
            showChatWindow()
        }
    }

    func updateDockPosition(animated: Bool) {
        guard let mainWindow = resolveMainWindow(), let chatWindow = chatWindow else { return }
        if mainWindow.inLiveResize {
            logger.log(content: "[ResizeDebug] chat.updateDockPosition skipped mainFrame={\(frameSummary(mainWindow.frame))} chatFrame={\(frameSummary(chatWindow.frame))}")
            return
        }
        let width = max(320, CGFloat(UserSettings.shared.chatWindowWidth))
        let targetFrame = dockedFrame(for: mainWindow, width: width)
        logger.log(content: "[ResizeDebug] chat.updateDockPosition begin animated=\(animated) mainFrame={\(frameSummary(mainWindow.frame))} chatFrame={\(frameSummary(chatWindow.frame))} target={\(frameSummary(targetFrame))}")
        isProgrammaticDockUpdate = true
        chatWindow.setFrame(targetFrame, display: true, animate: animated)
        isProgrammaticDockUpdate = false
    }

    func closeChatWindow() {
        pendingDockCommit?.cancel()
        pendingDockCommit = nil
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        NotificationCenter.default.removeObserver(self)
        chatWindow?.close()
        chatWindow = nil
        UserSettings.shared.isChatWindowVisible = false
    }

    @objc
    private func handleChatWindowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == chatWindow else { return }
        logger.log(content: "[ResizeDebug] chat.handleChatWindowDidResize frame={\(frameSummary(window.frame))}")
        UserSettings.shared.chatWindowWidth = Double(window.frame.width)
        updateDockPosition(animated: false)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == chatWindow else { return }
        guard !isProgrammaticDockUpdate else { return }

        logger.log(content: "[ResizeDebug] chat.windowDidMove frame={\(frameSummary(window.frame))}")

        pendingDockCommit?.cancel()

        if let mainWindow = resolveMainWindow() {
            let side: ChatDockSide = window.frame.midX < mainWindow.frame.midX ? .left : .right
            if UserSettings.shared.chatDockSide != side {
                UserSettings.shared.chatDockSide = side
            }
        }

        let work = DispatchWorkItem { [weak self] in
            self?.updateDockPosition(animated: true)
        }
        pendingDockCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func resolveMainWindow() -> NSWindow? {
        if let win = NSApplication.shared.windows.first(where: { ($0.identifier?.rawValue ?? "").contains(UserSettings.shared.mainWindownName) }) {
            return win
        }
        return NSApplication.shared.mainWindow
    }

    private func dockedFrame(for mainWindow: NSWindow, width: CGFloat) -> NSRect {
        guard let screen = mainWindow.screen ?? NSScreen.main else {
            return NSRect(x: mainWindow.frame.maxX + dockGap, y: mainWindow.frame.minY, width: width, height: mainWindow.frame.height)
        }

        let mainFrame = mainWindow.frame
        let visible = screen.visibleFrame
        let desiredHeight = min(mainFrame.height, visible.height)
        var y = mainFrame.minY
        y = max(visible.minY, min(y, visible.maxY - desiredHeight))

        let x: CGFloat
        switch UserSettings.shared.chatDockSide {
        case .left:
            x = mainFrame.minX - dockGap - width
        case .right:
            x = mainFrame.maxX + dockGap
        }

        let clampedX = max(visible.minX, min(x, visible.maxX - width))
        return NSRect(x: clampedX, y: y, width: width, height: desiredHeight)
    }
}
