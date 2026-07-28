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

// MARK: - .focused() Compatibility (macOS 12+)

extension View {
    @ViewBuilder
    func focusedCompat(_ binding: Binding<Bool>) -> some View {
        if #available(macOS 12.0, *) {
            self.focused(binding)
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

// MARK: - FocusState shim (macOS 12+)

@propertyWrapper
struct FocusStateCompat: DynamicProperty {
    @State private var isFocused: Bool = false

    var wrappedValue: Bool {
        get { isFocused }
        nonmutating set { isFocused = newValue }
    }

    var projectedValue: Binding<Bool> {
        $isFocused
    }

    init() {
        self._isFocused = State(initialValue: false)
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
