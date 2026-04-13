import SwiftUI
import AppKit

// MARK: - MacroPanelView

/// Popover panel showing the user's keyboard macros.
/// Macros can be executed with a single click and managed via context menus.
struct MacroPanelView: View {
    private struct FilteredMacro: Identifiable {
        let index: Int
        let macro: Macro

        var id: UUID { macro.id }
    }

    @ObservedObject private var manager = MacroManager.shared
    @ObservedObject private var userSettings: UserSettings = .shared
    @State private var editingMacro: Macro? = nil
    @State private var editingIndex: Int? = nil
    @State private var showEditor = false
    @State private var showVerifiedMacros = true
    @State private var filterByOS = true

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 8)]

    private var currentMacroTargetSystem: MacroTargetSystem? {
        MacroTargetSystem(rawValue: userSettings.chatTargetSystem.rawValue)
    }

    private var filteredMacros: [FilteredMacro] {
        manager.macros.enumerated().compactMap { entry in
            let matchesVerified = showVerifiedMacros ? entry.element.isVerified : !entry.element.isVerified
            guard matchesVerified else { return nil }
            if filterByOS, let osFilter = currentMacroTargetSystem {
                guard entry.element.targetSystem == osFilter else { return nil }
            }
            return FilteredMacro(index: entry.offset, macro: entry.element)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ───────────────────────────────────────────────────────
            HStack {
                Text("Macros")
                    .font(.headline)
                if filterByOS, let os = currentMacroTargetSystem {
                    Text(os.displayName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer()
                Button {
                    filterByOS.toggle()
                } label: {
                    Image(systemName: filterByOS ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.body)
                        .foregroundColor(filterByOS ? .accentColor : .secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(filterByOS ? "Showing macros for current target OS — click to show all" : "Showing all macros — click to filter by target OS")

                Button {
                    showVerifiedMacros.toggle()
                } label: {
                    Image(systemName: showVerifiedMacros ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.body)
                        .foregroundColor(showVerifiedMacros ? .green : .orange)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(showVerifiedMacros ? "Show only unverified macros" : "Show only verified macros")

                Button {
                    editingMacro = Macro(label: "", data: "", icon: "keyboard", intervalMs: 80)
                    editingIndex = nil
                    showEditor = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("Add macro")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // ── Content ──────────────────────────────────────────────────────
            if filteredMacros.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "keyboard.badge.ellipsis")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(showVerifiedMacros ? "No verified macros" : "No unverified macros")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if filterByOS, let os = currentMacroTargetSystem {
                        Text("No \(showVerifiedMacros ? "verified" : "unverified") macros for \(os.displayName). Tap the filter icon to show all OS macros.")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    } else {
                        Text(showVerifiedMacros ? "Mark a macro as verified to show it in this view." : "Create or unverify a macro to show it in this view.")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(filteredMacros) { item in
                            MacroGridButton(macro: item.macro, showVerificationStatus: true) {
                                manager.execute(item.macro)
                            } onEdit: {
                                editingMacro = item.macro
                                editingIndex = item.index
                                showEditor = true
                            } onDelete: {
                                manager.remove(at: item.index)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 280, idealWidth: 320, minHeight: 180)
        .sheet(isPresented: $showEditor) {
            if let macro = editingMacro {
                MacroEditorSheet(macro: macro, isNew: editingIndex == nil) { saved in
                    if let idx = editingIndex {
                        manager.update(saved, at: idx)
                    } else {
                        manager.add(saved)
                    }
                    editingMacro = nil
                    editingIndex = nil
                    showEditor = false
                } onCancel: {
                    editingMacro = nil
                    editingIndex = nil
                    showEditor = false
                }
            }
        }
    }
}

// MARK: - MacroGridButton

struct MacroGridButton: View {
    let macro: Macro
    let showVerificationStatus: Bool
    let onRun: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var helpText: String {
        let trimmedDescription = macro.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDescription.isEmpty ? macro.data : trimmedDescription
    }

    private var verificationLabel: String {
        macro.isVerified ? "Verified" : "Unverified"
    }

    private var verificationColor: Color {
        macro.isVerified ? .green : .orange
    }

    var body: some View {
        Button(action: onRun) {
            VStack(spacing: 4) {
                if showVerificationStatus {
                    Text(verificationLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(verificationColor.opacity(0.14))
                        .foregroundColor(verificationColor)
                        .clipShape(Capsule())
                }
                Image(systemName: macro.icon)
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                Text(macro.label)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.08))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .contextMenu {
            Button { onRun() } label: { Label("Run", systemImage: "play.fill") }
            Button { onEdit() } label: { Label("Edit", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private enum MacroShortcutTab: String, CaseIterable, Identifiable {
    case functionKeys
    case compositeKeys
    case macros

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .functionKeys:
            return "Function Keys"
        case .compositeKeys:
            return "Composite Keys"
        case .macros:
            return "Macro"
        }
    }
}

// MARK: - MacroEditorSheet

struct MacroEditorSheet: View {
    @ObservedObject private var macroManager = MacroManager.shared
    @State private var label: String
    @State private var description: String
    @State private var isVerified: Bool
    @State private var data: String
    @State private var targetSystem: MacroTargetSystem
    @State private var intervalMs: Double
    @State private var selectionRange = NSRange(location: 0, length: 0)
    @State private var selectedShortcutTab: MacroShortcutTab = .functionKeys
    @State private var isGeneratingFromAI = false
    @State private var aiErrorMessage: String?

    let isNew: Bool
    let onSave: (Macro) -> Void
    let onCancel: () -> Void

    private let originalID: UUID
    private let originalIcon: String

    init(macro: Macro, isNew: Bool,
         onSave: @escaping (Macro) -> Void,
         onCancel: @escaping () -> Void) {
        _label = State(initialValue: macro.label)
        _description = State(initialValue: macro.description)
        _isVerified = State(initialValue: macro.isVerified)
        _data  = State(initialValue: macro.data)
        _targetSystem = State(initialValue: macro.targetSystem)
        _intervalMs = State(initialValue: Double(macro.intervalMs))
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        self.originalID = macro.id
        self.originalIcon = macro.icon
    }

    private var functionKeys: [(label: String, token: String)] {
        let ctrlLabel: String
        let altLabel: String
        let cmdLabel: String
        let enterLabel: String
        let backLabel: String

        switch targetSystem {
        case .macOS:
            ctrlLabel = "⌃ Ctrl"
            altLabel = "⌥ Opt"
            cmdLabel = "⌘ Cmd"
            enterLabel = "⏎ Ret"
            backLabel = "⌫ Del"
        case .windows:
            ctrlLabel = "Ctrl"
            altLabel = "Alt"
            cmdLabel = "Win"
            enterLabel = "Enter"
            backLabel = "Back"
        case .linux:
            ctrlLabel = "Ctrl"
            altLabel = "Alt"
            cmdLabel = "Super"
            enterLabel = "Enter"
            backLabel = "Back"
        case .iPhone, .iPad:
            ctrlLabel = "⌃ Ctrl"
            altLabel = "⌥ Opt"
            cmdLabel = "⌘ Cmd"
            enterLabel = "⏎ Ret"
            backLabel = "⌫ Del"
        case .android:
            ctrlLabel = "Ctrl"
            altLabel = "Alt"
            cmdLabel = "Meta"
            enterLabel = "Enter"
            backLabel = "Back"
        }

        return [
            ("⎋ Esc", "<ESC>"),
            (backLabel, "<BACK>"),
            (enterLabel, "<ENTER>"),
            ("Tab", "<TAB>"),
            ("Space", "<SPACE>"),
            ("← Left", "<LEFT>"),
            ("→ Right", "<RIGHT>"),
            ("↑ Up", "<UP>"),
            ("↓ Down", "<DOWN>"),
            ("Home", "<HOME>"),
            ("End", "<END>"),
            ("Del", "<DEL>"),
            ("PgUp", "<PGUP>"),
            ("PgDn", "<PGDN>"),
            (ctrlLabel, "<CTRL>"),
            ("Shift", "<SHIFT>"),
            (altLabel, "<ALT>"),
            (cmdLabel, "<CMD>"),
            ("F1",  "<F1>"),  ("F2",  "<F2>"),  ("F3",  "<F3>"),
            ("F4",  "<F4>"),  ("F5",  "<F5>"),  ("F6",  "<F6>"),
            ("F7",  "<F7>"),  ("F8",  "<F8>"),  ("F9",  "<F9>"),
            ("F10", "<F10>"), ("F11", "<F11>"), ("F12", "<F12>"),
            ("Delay 0.5s", "<DELAY05s>"),
            ("Delay 1s", "<DELAY1S>"),
            ("Delay 2s", "<DELAY2S>"),
            ("Delay 5s", "<DELAY5S>"),
            ("Delay 10s", "<DELAY10S>"),
        ]
    }

    private var compositeKeys: [(label: String, token: String)] {
        switch targetSystem {
        case .macOS:
            return [
                ("Cmd+Space", "<CMD><SPACE></CMD>"),
                ("Cmd+Tab", "<CMD><TAB></CMD>"),
                ("Cmd+Q", "<CMD>q</CMD>"),
                ("Cmd+W", "<CMD>w</CMD>"),
                ("Cmd+H", "<CMD>h</CMD>"),
            ]
        case .windows:
            return [
                ("Ctrl+Alt+Del", "<CTRL><ALT><DEL></ALT></CTRL>"),
                ("Win+R", "<CMD>r</CMD>"),
                ("Alt+Tab", "<ALT><TAB></ALT>"),
                ("Ctrl+Shift+Esc", "<CTRL><SHIFT><ESC></SHIFT></CTRL>"),
                ("Win+L", "<CMD>l</CMD>"),
            ]
        case .linux:
            return [
                ("Ctrl+Alt+T", "<CTRL><ALT>t</ALT></CTRL>"),
                ("Ctrl+Alt+Del", "<CTRL><ALT><DEL></ALT></CTRL>"),
                ("Super+L", "<CMD>l</CMD>"),
                ("Alt+Tab", "<ALT><TAB></ALT>"),
                ("Ctrl+Alt+F1", "<CTRL><ALT><F1></ALT></CTRL>"),
            ]
        case .iPhone, .iPad:
            return [
                ("Cmd+Space", "<CMD><SPACE></CMD>"),
                ("Cmd+Tab", "<CMD><TAB></CMD>"),
                ("Cmd+H", "<CMD>h</CMD>"),
                ("Cmd+Shift+3", "<CMD><SHIFT>3</SHIFT></CMD>"),
                ("Cmd+.", "<CMD>.</CMD>"),
            ]
        case .android:
            return [
                ("Alt+Tab", "<ALT><TAB></ALT>"),
                ("Ctrl+Space", "<CTRL><SPACE></CTRL>"),
                ("Meta+L", "<CMD>l</CMD>"),
                ("Ctrl+A", "<CTRL>a</CTRL>"),
                ("Ctrl+C", "<CTRL>c</CTRL>"),
            ]
        }
    }

    private var macroReferenceKeys: [(label: String, token: String)] {
        macroManager.macros
            .filter { $0.id != originalID }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            .map { (label: $0.label, token: "<MACRO:\($0.id.uuidString)>") }
    }

    private var currentShortcutTooltips: [String: String] {
        switch selectedShortcutTab {
        case .macros:
            return Dictionary(uniqueKeysWithValues: macroManager.macros
                .filter { $0.id != originalID }
                .map { macro in
                    let trimmedDescription = macro.description.trimmingCharacters(in: .whitespacesAndNewlines)
                    let helpText = trimmedDescription.isEmpty ? macro.data : trimmedDescription
                    return ("<MACRO:\(macro.id.uuidString)>", helpText)
                })
        default:
            return [:]
        }
    }

    private var currentShortcutItems: [(label: String, token: String)] {
        switch selectedShortcutTab {
        case .functionKeys:
            return functionKeys
        case .compositeKeys:
            return compositeKeys
        case .macros:
            return macroReferenceKeys
        }
    }

    private var currentShortcutEmptyLabel: String? {
        switch selectedShortcutTab {
        case .macros:
            return "No other macros"
        default:
            return nil
        }
    }

    private var currentShortcutColumnCount: Int {
        switch selectedShortcutTab {
        case .functionKeys:
            return 5
        case .compositeKeys, .macros:
            return 3
        }
    }

    private var isSaveEnabled: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isMagicEnabled: Bool {
        !isGeneratingFromAI && !magicPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var magicPrompt: String {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (trimmedLabel.isEmpty, trimmedDescription.isEmpty) {
        case (false, false):
            return "Macro name hint: \(trimmedLabel)\nDesired behavior: \(trimmedDescription)"
        case (false, true):
            return trimmedLabel
        case (true, false):
            return trimmedDescription
        case (true, true):
            return ""
        }
    }

    private func insertShortcutToken(_ token: String) {
        let resolvedToken = toggledToken(for: token)
        let nsString = data as NSString
        let safeLocation = min(max(selectionRange.location, 0), nsString.length)
        let safeLength = min(max(selectionRange.length, 0), nsString.length - safeLocation)
        let replaceRange = NSRange(location: safeLocation, length: safeLength)
        let updated = nsString.replacingCharacters(in: replaceRange, with: resolvedToken)
        data = updated
        selectionRange = NSRange(location: safeLocation + (resolvedToken as NSString).length, length: 0)
    }

    private func toggledToken(for token: String) -> String {
        guard let modifierName = modifierName(for: token) else { return token }
        return isModifierOpen(modifierName, before: selectionRange.location) ? "</\(modifierName)>" : "<\(modifierName)>"
    }

    private func modifierName(for token: String) -> String? {
        switch token {
        case "<CTRL>", "</CTRL>": return "CTRL"
        case "<SHIFT>", "</SHIFT>": return "SHIFT"
        case "<ALT>", "</ALT>": return "ALT"
        case "<CMD>", "</CMD>": return "CMD"
        default: return nil
        }
    }

    private func isModifierOpen(_ modifierName: String, before location: Int) -> Bool {
        let safeLocation = min(max(location, 0), (data as NSString).length)
        let prefix = (data as NSString).substring(to: safeLocation)
        return modifierBalance(for: modifierName, in: prefix) > 0
    }

    private func modifierBalance(for modifierName: String, in text: String) -> Int {
        let openToken = "<\(modifierName)>"
        let closeToken = "</\(modifierName)>"
        var balance = 0
        var index = text.startIndex

        while index < text.endIndex {
            if text[index...].hasPrefix(openToken) {
                balance += 1
                index = text.index(index, offsetBy: openToken.count)
            } else if text[index...].hasPrefix(closeToken) {
                balance = max(0, balance - 1)
                index = text.index(index, offsetBy: closeToken.count)
            } else {
                index = text.index(after: index)
            }
        }

        return balance
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Title bar ────────────────────────────────────────────────────
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Text(isNew ? "New Macro" : "Edit Macro")
                    .font(.headline)
                Spacer()
                Button("Save") {
                    let trimLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimData  = data.trimmingCharacters(in: .whitespacesAndNewlines)
                    let saved = Macro(
                        id: originalID,
                        label: trimLabel.isEmpty ? String(trimData.prefix(20)) : trimLabel,
                        description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                        isVerified: isVerified,
                        data: trimData,
                        icon: originalIcon,
                        targetSystem: targetSystem,
                        intervalMs: Int(intervalMs)
                    )
                    onSave(saved)
                }
                .disabled(!isSaveEnabled)
                .font(.body.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // ── Label ────────────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Name", systemImage: "tag")
                            .font(.caption.weight(.semibold)).foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            TextField("e.g. Ctrl+Alt+Del", text: $label)
                                .textFieldStyle(.roundedBorder)

                            Button {
                                generateMacroFromCurrentFields()
                            } label: {
                                Group {
                                    if isGeneratingFromAI {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "wand.and.stars")
                                    }
                                }
                                .frame(width: 18, height: 18)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!isMagicEnabled)
                            .help("Generate from the current name and description")
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Label("Description", systemImage: "text.alignleft")
                            .font(.caption.weight(.semibold)).foregroundColor(.secondary)
                        TextField("Describe the macro...", text: $description)
                            .textFieldStyle(.roundedBorder)
                        if let aiErrorMessage {
                            Text(aiErrorMessage)
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                    }

                    Toggle(isOn: $isVerified) {
                        Label("Verified", systemImage: isVerified ? "checkmark.seal.fill" : "exclamationmark.triangle")
                            .font(.caption.weight(.semibold))
                    }
                    .toggleStyle(.switch)

                    VStack(alignment: .leading, spacing: 4) {
                        Label("Target OS", systemImage: "desktopcomputer")
                            .font(.caption.weight(.semibold)).foregroundColor(.secondary)
                        Picker("Target OS", selection: $targetSystem) {
                            ForEach(MacroTargetSystem.allCases) { system in
                                Text(system.displayName).tag(system)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // ── Key Sequence ─────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Key Sequence", systemImage: "keyboard")
                            .font(.caption.weight(.semibold)).foregroundColor(.secondary)
                        Text("Example: \u{003C}CTRL\u{003E}c\u{003C}/CTRL\u{003E} sends Ctrl+C. Modifier buttons auto-open or auto-close based on the caret position.")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        MacroSequenceEditor(text: $data, selectionRange: $selectionRange)
                            .frame(minHeight: 80, maxHeight: 160)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                            )

                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Shortcut Group", selection: $selectedShortcutTab) {
                                ForEach(MacroShortcutTab.allCases) { tab in
                                    Text(tab.displayName).tag(tab)
                                }
                            }
                            .pickerStyle(.segmented)

                            MacroShortcutColumn(
                                title: selectedShortcutTab.displayName,
                                items: currentShortcutItems,
                                columnCount: currentShortcutColumnCount,
                                tooltips: currentShortcutTooltips,
                                emptyLabel: currentShortcutEmptyLabel,
                                onInsert: insertShortcutToken
                            )
                        }
                    }

                    // ── Interval slider ──────────────────────────────────────
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label("Key Interval", systemImage: "timer")
                                .font(.caption.weight(.semibold)).foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(intervalMs)) ms")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Slider(value: $intervalMs, in: 10...500, step: 10)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 420, height: 500)
    }
    private func generateMacroFromCurrentFields() {
        let prompt = magicPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            aiErrorMessage = "Enter a name or description first."
            return
        }

        aiErrorMessage = nil
        isGeneratingFromAI = true

        Task {
            do {
                let draft = try await ChatManager.shared.generateMacroDraft(from: MacroAIDraftRequest(
                    goal: prompt,
                    targetSystem: targetSystem,
                    currentLabel: label,
                    currentDescription: description,
                    currentData: data
                ))

                await MainActor.run {
                    label = draft.label
                    description = draft.description
                    data = draft.data
                    intervalMs = Double(draft.intervalMs)
                    selectionRange = NSRange(location: (draft.data as NSString).length, length: 0)
                    isGeneratingFromAI = false
                }
            } catch {
                await MainActor.run {
                    aiErrorMessage = error.localizedDescription
                    isGeneratingFromAI = false
                }
            }
        }
    }
}

private struct MacroSequenceEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectionRange: NSRange

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
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.identifier = NSUserInterfaceItemIdentifier("macroSequenceEditor")
        textView.string = text
        textView.setSelectedRange(selectionRange)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        if textView.selectedRange() != selectionRange {
            textView.setSelectedRange(selectionRange)
            textView.scrollRangeToVisible(selectionRange)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacroSequenceEditor

        init(_ parent: MacroSequenceEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.selectionRange = textView.selectedRange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.selectionRange = textView.selectedRange()
        }
    }
}

private struct MacroShortcutColumn: View {
    let title: String
    let items: [(label: String, token: String)]
    let columnCount: Int
    let tooltips: [String: String]
    let emptyLabel: String?
    let onInsert: (String) -> Void

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: columnCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            if items.isEmpty {
                if let emptyLabel {
                    Text(emptyLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            } else {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 6) {
                    ForEach(items, id: \.token) { item in
                        Button {
                            onInsert(item.token)
                        } label: {
                            Text(item.label)
                                .font(.caption2)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help(tooltips[item.token] ?? item.label)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
