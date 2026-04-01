import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.backgroundColor = NSColor.textBackgroundColor
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 6)

        context.coordinator.setupMonitor(for: textView, onSend: onSend)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputTextView
        var monitor: Any?

        init(_ parent: ChatInputTextView) {
            self.parent = parent
        }

        deinit {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func setupMonitor(for textView: NSTextView, onSend: @escaping () -> Void) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak textView] event in
                guard let textView = textView else { return event }
                let isReturnKey = event.keyCode == 36 || event.keyCode == 76
                if isReturnKey, textView.window?.firstResponder == textView {
                    if textView.hasMarkedText() {
                        return event // Allow IME (like Chinese Pinyin) completion
                    }
                    if !event.modifierFlags.contains(.shift) {
                        onSend()
                        return nil // Consume event to prevent newline
                    }
                }
                return event
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
