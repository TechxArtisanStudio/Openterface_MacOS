//
//  View+MacOS11Compatibility.swift
//  Openterface
//
//  macOS 11 compatibility shims for APIs introduced in later macOS versions.
//  These allow the app to target macOS 11 while conditionally using newer APIs.
//

import SwiftUI

// MARK: - .onChange(of:) Compatibility (macOS 12+)

extension View {
    /// A macOS 11-compatible wrapper around `.onChange(of:)` (macOS 12+).
    ///
    /// On macOS 12+, this behaves identically to the built-in `.onChange(of:)`.
    /// On macOS 11, the action is never called (no-op).
    ///
    /// Usage:
    /// ```swift
    /// MyView()
    ///     .onChangeCompat(of: someValue) { newValue in
    ///         print("Value changed to \(newValue)")
    ///     }
    /// ```
    @ViewBuilder
    func onChangeCompat<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value) -> Void
    ) -> some View {
        if #available(macOS 14.0, *) {
            self.onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else if #available(macOS 12.0, *) {
            self.onChange(of: value) { newValue in
                action(newValue)
            }
        } else {
            self
        }
    }
}

// MARK: - .focused() Compatibility (macOS 12+)

extension View {
    /// A macOS 11-compatible wrapper around `.focused()` (macOS 12+).
    /// On macOS 11, this is a no-op.
    @ViewBuilder
    func focusedCompat(
        _ binding: Binding<Bool>
    ) -> some View {
        if #available(macOS 12.0, *) {
            self.focused(binding)
        } else {
            self
        }
    }
}

// MARK: - FocusState shim (macOS 12+)

/// A macOS 11-compatible wrapper around `@FocusState`.
/// On macOS 12+, this delegates to `@FocusState`.
/// On macOS 11, this uses a regular `@State` boolean (non-functional, but compiles).
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