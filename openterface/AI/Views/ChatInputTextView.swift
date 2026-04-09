import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    let onSend: () -> Void

    final class SendAwareTextView: NSTextView {
        var onSend: (() -> Void)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if modifiers == [.command], event.keyCode == 0 {
                selectAll(nil)
                return true
            }

            return super.performKeyEquivalent(with: event)
        }

        override func keyDown(with event: NSEvent) {
            let isReturnKey = event.keyCode == 36 || event.keyCode == 76
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if isReturnKey,
               !hasMarkedText(),
               !modifiers.contains(.shift),
               !modifiers.contains(.command),
               !modifiers.contains(.option),
               !modifiers.contains(.control) {
                onSend?()
                return
            }

            super.keyDown(with: event)
        }
    }

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
        let sendAwareTextView: SendAwareTextView
        if let existing = textView as? SendAwareTextView {
            sendAwareTextView = existing
        } else {
            let replacement = SendAwareTextView(frame: textView.frame, textContainer: textView.textContainer)
            replacement.minSize = textView.minSize
            replacement.maxSize = textView.maxSize
            replacement.isVerticallyResizable = textView.isVerticallyResizable
            replacement.isHorizontallyResizable = textView.isHorizontallyResizable
            replacement.autoresizingMask = textView.autoresizingMask
            replacement.textContainerInset = textView.textContainerInset
            replacement.textContainer?.widthTracksTextView = textView.textContainer?.widthTracksTextView ?? true
            replacement.string = textView.string
            scrollView.documentView = replacement
            sendAwareTextView = replacement
        }
        sendAwareTextView.delegate = context.coordinator
        sendAwareTextView.isRichText = false
        sendAwareTextView.isAutomaticQuoteSubstitutionEnabled = false
        sendAwareTextView.isAutomaticDashSubstitutionEnabled = false
        sendAwareTextView.isAutomaticDataDetectionEnabled = false
        sendAwareTextView.isAutomaticTextReplacementEnabled = false
        sendAwareTextView.allowsUndo = true
        sendAwareTextView.font = NSFont.preferredFont(forTextStyle: .body)
        sendAwareTextView.textColor = NSColor.textColor
        sendAwareTextView.backgroundColor = NSColor.textBackgroundColor
        sendAwareTextView.textContainerInset = NSSize(width: 4, height: 6)
        sendAwareTextView.onSend = onSend

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? SendAwareTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.onSend = onSend
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputTextView

        init(_ parent: ChatInputTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
