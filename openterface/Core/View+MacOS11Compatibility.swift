//
//  View+MacOS11Compatibility.swift
//  Openterface
//
//  macOS 11 compatibility shims for APIs introduced in later macOS versions.
//  These allow the app to target macOS 11 while conditionally using newer APIs.
//

import SwiftUI
import IOKit

// MARK: - .onChange(of:) Compatibility (macOS 12+)

extension View {
    @ViewBuilder
    func onChangeCompat<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value) -> Void
    ) -> some View {
        if #available(macOS 14.0, *) {
            self.onChange(of: value) { _, newValue in action(newValue) }
        } else if #available(macOS 12.0, *) {
            self.onChange(of: value) { newValue in action(newValue) }
        } else {
            self
        }
    }
}

// MARK: - .textSelection() Compatibility (macOS 12+)

extension View {
    @ViewBuilder
    func textSelectionCompat(enabled: Bool) -> some View {
        if #available(macOS 12.0, *) {
            if enabled {
                self.textSelection(.enabled)
            } else {
                self.textSelection(.disabled)
            }
        } else {
            self
        }
    }
}

// MARK: - .tint() Compatibility (macOS 12+)

extension View {
    @ViewBuilder
    func tintCompat(_ tint: Color?) -> some View {
        if #available(macOS 12.0, *) {
            self.tint(tint)
        } else {
            self.accentColor(tint)
        }
    }
}

// MARK: - .borderedProminent() Compatibility (macOS 12+)

/// Replacement for `.buttonStyle(.borderedProminent)` that falls back to `.bordered` on macOS 11.
struct BorderedProminentCompatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if #available(macOS 12.0, *) {
                configuration.label.buttonStyle(.borderedProminent)
            } else {
                configuration.label.buttonStyle(.bordered)
            }
        }
    }
}

extension ButtonStyle where Self == BorderedProminentCompatButtonStyle {
    static var borderedProminentCompat: BorderedProminentCompatButtonStyle {
        BorderedProminentCompatButtonStyle()
    }
}

// MARK: - IOKit: kIOMainPortDefault compatibility (macOS 12+)

/// Returns the main port for IOKit, compatible with macOS 11.
/// On macOS 12+, uses `kIOMainPortDefault`. On macOS 11, uses the deprecated `kIOMasterPortDefault`.
@inline(__always)
func ioMainPortDefault() -> mach_port_t {
    if #available(macOS 12.0, *) {
        return kIOMainPortDefault
    } else {
        return kIOMasterPortDefault  // deprecated but functional on macOS 11
    }
}

// MARK: - GroupBoxCompat (macOS 12+)

/// A macOS 11-compatible `GroupBox` with a string title.
/// On macOS 12+, uses native `GroupBox(_ title:content:)`.
/// On macOS 11, wraps content in a VStack with a title Text.
@ViewBuilder
func GroupBoxCompat<S: StringProtocol>(
    _ title: S,
    @ViewBuilder content: () -> some View
) -> some View {
    if #available(macOS 12.0, *) {
        GroupBox(title, content: content)
    } else {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
    }
}

// MARK: - .overlay(alignment:) Compatibility (macOS 12+)

extension View {
    /// A macOS 11-compatible `.overlay(alignment:content:)` (macOS 12+).
    /// On macOS 11, falls back to the older `.overlay()` without alignment support.
    @ViewBuilder
    func overlayCompat<V: View>(
        alignment: Alignment = .center,
        @ViewBuilder content: () -> V
    ) -> some View {
        if #available(macOS 12.0, *) {
            self.overlay(alignment: alignment, content: content)
        } else {
            self.overlay(content())
        }
    }
}

// MARK: - Color(nsColor:) Compatibility (macOS 12+)

extension Color {
    /// A macOS 11-compatible Color from NSColor.
    /// On macOS 12+, uses native `Color(nsColor:)`.
    /// On macOS 11, converts manually via CGColor.
    static func compat(nsColor: NSColor) -> Color {
        if #available(macOS 12.0, *) {
            return Color(nsColor: nsColor)
        } else {
            return Color(nsColor.cgColor)
        }
    }
}

// MARK: - CVBufferCopyAttachment Compatibility (macOS 12+)

import CoreVideo
import CoreMedia

/// A macOS 11-compatible wrapper for `CVBufferGetAttachment`.
/// `CVBufferCopyAttachment` is macOS 12+; on macOS 11 we use the older `CVBufferGetAttachment`.
func cvBufferCopyAttachmentCompat<T>(
    _ buffer: CVBuffer,
    key: CFString,
    type: T.Type
) -> T? {
    if #available(macOS 12.0, *) {
        return CVBufferCopyAttachment(buffer, key, nil) as? T
    } else {
        return CVBufferGetAttachment(buffer, key, nil)?.takeUnretainedValue() as? T
    }
}

// MARK: - .alert() Compatibility (macOS 12+)

extension View {
    /// A macOS 11-compatible `.alert` with actions and message (macOS 12+).
    /// On macOS 11, this is a no-op (alert doesn't show).
    @ViewBuilder
    func alertCompat<A: View, M: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: () -> A,
        @ViewBuilder message: () -> M
    ) -> some View {
        if #available(macOS 12.0, *) {
            self.alert(title, isPresented: isPresented, actions: actions, message: message)
        } else {
            self
        }
    }
    
    /// A macOS 11-compatible `.alert` with actions only (no message).
    @ViewBuilder
    func alertCompat<A: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: () -> A
    ) -> some View {
        if #available(macOS 12.0, *) {
            self.alert(title, isPresented: isPresented, actions: actions)
        } else {
            self
        }
    }
}
