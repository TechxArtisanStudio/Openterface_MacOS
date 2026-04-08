import SwiftUI

struct RemoteControlSettingsView: View {
    @ObservedObject private var userSettings = UserSettings.shared
    @StateObject private var credentialsStore = RemoteCredentialsStore.shared
    @State private var vncPortText: String = ""
    @State private var showCredentialsManager: Bool = false
    @State private var credentialsManagerProtocol: RemoteCredentialProtocolType = .vnc

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Remote Control")
                .font(.title2)
                .bold()

            GroupBox("Remote Connection") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Configure network-based remote access protocols.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    remoteProtocolBox
                    protocolSelectorSection

                    if userSettings.connectionProtocolMode == .vnc {
                        Divider()
                        vncConnectionSection
                    } else if userSettings.connectionProtocolMode == .rdp {
                        Divider()
                        rdpConnectionSection
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .onAppear {
            vncPortText = "\(userSettings.vncPort)"
            applySelectedCredentialToUserSettings(.vnc)
            applySelectedCredentialToUserSettings(.rdp)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenRemoteCredentialsManager"))) { notif in
            if let raw = notif.userInfo?["protocol"] as? String,
               let requested = RemoteCredentialProtocolType(rawValue: raw) {
                openCredentialsManager(for: requested)
            } else {
                openCredentialsManager(for: userSettings.connectionProtocolMode)
            }
        }
        .sheet(isPresented: $showCredentialsManager) {
            CredentialsManagerDialog(store: credentialsStore, initialProtocol: credentialsManagerProtocol) {
                applySelectedCredentialToUserSettings(.vnc)
                applySelectedCredentialToUserSettings(.rdp)
            }
        }
    }

    @ViewBuilder
    private var remoteProtocolBox: some View {
        GroupBox("Remote Protocol") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("VNC (RFB 3.8)", systemImage: "network")
                    Spacer()
                    Text(credentialsStore.protocolSubtitle(for: .vnc))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Available")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                HStack {
                    Label("RDP", systemImage: "network.badge.shield.half.filled")
                    Spacer()
                    Text(credentialsStore.protocolSubtitle(for: .rdp))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Available")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                HStack {
                    Spacer()
                    Button("Manage Credentials") {
                        openCredentialsManager(for: userSettings.connectionProtocolMode)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var protocolSelectorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ConnectionProtocolMode.allCases, id: \.self) { mode in
                Button(action: {
                    userSettings.connectionProtocolMode = mode
                    AppStatus.activeConnectionProtocol = mode
                    NotificationCenter.default.post(name: Notification.Name("ConnectionProtocolModeChanged"), object: nil)
                }) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName)
                                .font(.body)
                                .fontWeight(.medium)
                            Text(mode.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if mode == .vnc {
                                let subtitle = credentialsStore.protocolSubtitle(for: .vnc)
                                if subtitle != "Not configured" {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }
                            } else if mode == .rdp {
                                let subtitle = credentialsStore.protocolSubtitle(for: .rdp)
                                if subtitle != "Not configured" {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        Spacer()
                        if userSettings.connectionProtocolMode == mode {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.blue)
                                .font(.title3)
                        } else {
                            Image(systemName: "circle")
                                .foregroundColor(.secondary)
                                .font(.title3)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(userSettings.connectionProtocolMode == mode ? Color.blue.opacity(0.1) : Color.gray.opacity(0.05))
                    .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
            }

            HStack {
                Spacer()
                Button("Manage Credentials") {
                    openCredentialsManager(for: userSettings.connectionProtocolMode)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var vncConnectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VNC Connection")
                .font(.subheadline)
                .fontWeight(.semibold)

            HStack {
                Text("Credential")
                    .frame(width: 80, alignment: .leading)
                Picker("Credential", selection: Binding<UUID?>(
                    get: { credentialsStore.selectedCredentialID(for: .vnc) },
                    set: { newValue in
                        credentialsStore.selectCredential(id: newValue, for: .vnc)
                        applySelectedCredentialToUserSettings(.vnc)
                    }
                )) {
                    Text("None").tag(nil as UUID?)
                    ForEach(credentialsStore.entries(for: .vnc)) { entry in
                        Text(entry.displayName).tag(Optional(entry.id))
                    }
                }
            }

            HStack {
                Text("Host")
                    .frame(width: 80, alignment: .leading)
                TextField("127.0.0.1", text: $userSettings.vncHost)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            HStack {
                Text("Port")
                    .frame(width: 80, alignment: .leading)
                TextField("5900", text: $vncPortText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: vncPortText) { value in
                        let filtered = value.filter { $0.isNumber }
                        if filtered != value { vncPortText = filtered; return }
                        if let port = Int(filtered) { userSettings.vncPort = port }
                    }
            }

            HStack {
                Text("Username")
                    .frame(width: 80, alignment: .leading)
                TextField("Optional", text: $userSettings.vncUsername)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            HStack {
                Text("Password")
                    .frame(width: 80, alignment: .leading)
                SecureField("Optional", text: $userSettings.vncPassword)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            vncActionRow
            vncErrorRow
            Divider()
            vncCompressionToggles
        }
    }

    @ViewBuilder
    private var vncActionRow: some View {
        HStack {
            Button("Connect") {
                applySelectedCredentialToUserSettings(.vnc)
                NotificationCenter.default.post(name: Notification.Name("VNCConnectRequested"), object: nil)
            }
            .disabled(userSettings.vncHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Disconnect") {
                NotificationCenter.default.post(name: Notification.Name("VNCDisconnectRequested"), object: nil)
            }

            Button("Manage Credentials...") {
                openCredentialsManager(for: RemoteCredentialProtocolType.vnc)
            }

            Spacer()

            Text(connectionStatusText)
                .font(.caption)
                .foregroundColor(connectionStatusColor)
        }
    }

    @ViewBuilder
    private var vncErrorRow: some View {
        if !AppStatus.protocolLastErrorMessage.isEmpty {
            Text(AppStatus.protocolLastErrorMessage)
                .font(.caption)
                .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private var vncCompressionToggles: some View {
        Toggle(isOn: $userSettings.vncEnableZLIBCompression) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Enable ZLIB Compression")
                Text("Reduces bandwidth usage at the cost of CPU")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }

        Toggle(isOn: $userSettings.vncEnableTightCompression) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Enable Tight Compression")
                Text("Prefers Tight encoding for better interactive bandwidth savings")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var rdpConnectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RDP Connection")
                .font(.subheadline)
                .fontWeight(.semibold)

            HStack {
                Text("Credential")
                    .frame(width: 80, alignment: .leading)
                Picker("Credential", selection: Binding<UUID?>(
                    get: { credentialsStore.selectedCredentialID(for: .rdp) },
                    set: { newValue in
                        credentialsStore.selectCredential(id: newValue, for: .rdp)
                        applySelectedCredentialToUserSettings(.rdp)
                    }
                )) {
                    Text("None").tag(nil as UUID?)
                    ForEach(credentialsStore.entries(for: .rdp)) { entry in
                        Text(entry.displayName).tag(Optional(entry.id))
                    }
                }
            }

            HStack {
                Text("Host")
                    .frame(width: 80, alignment: .leading)
                TextField("example.com", text: $userSettings.rdpHost)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            HStack {
                Text("Port")
                    .frame(width: 80, alignment: .leading)
                TextField("3389", text: Binding(
                    get: { String(userSettings.rdpPort) },
                    set: { newVal in
                        if let port = Int(newVal.filter { $0.isNumber }) { userSettings.rdpPort = port }
                    }
                ))
                .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            HStack {
                Text("Domain")
                    .frame(width: 80, alignment: .leading)
                TextField("(optional)", text: $userSettings.rdpDomain)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            HStack {
                Text("Username")
                    .frame(width: 80, alignment: .leading)
                TextField("Required", text: $userSettings.rdpUsername)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            HStack {
                Text("Password")
                    .frame(width: 80, alignment: .leading)
                SecureField("(optional)", text: $userSettings.rdpPassword)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            rdpToggles
            rdpActionRow
            rdpErrorRow
        }
    }

    @ViewBuilder
    private var rdpToggles: some View {
        Toggle(isOn: $userSettings.rdpEnableNLA) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use NLA (Network Level Authentication)")
                Text("Required by most modern Windows hosts")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }

        Toggle(isOn: $userSettings.rdpStrictCompatibilityMode) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Strict compatibility mode")
                Text("Disables advanced graphics/frame-ack capabilities for problematic hosts")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var rdpActionRow: some View {
        HStack {
            Button("Connect") {
                applySelectedCredentialToUserSettings(.rdp)
                NotificationCenter.default.post(name: Notification.Name("RDPConnectRequested"), object: nil)
            }
            .disabled(userSettings.rdpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                      userSettings.rdpUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Disconnect") {
                NotificationCenter.default.post(name: Notification.Name("RDPDisconnectRequested"), object: nil)
            }

            Button("Manage Credentials...") {
                openCredentialsManager(for: RemoteCredentialProtocolType.rdp)
            }

            Spacer()

            Text(connectionStatusText)
                .font(.caption)
                .foregroundColor(connectionStatusColor)
        }
    }

    @ViewBuilder
    private var rdpErrorRow: some View {
        if !AppStatus.protocolLastErrorMessage.isEmpty {
            Text(AppStatus.protocolLastErrorMessage)
                .font(.caption)
                .foregroundColor(.red)
        }
    }

    private func openCredentialsManager(for mode: ConnectionProtocolMode) {
        switch mode {
        case .vnc:
            credentialsManagerProtocol = .vnc
        case .rdp:
            credentialsManagerProtocol = .rdp
        case .kvm:
            credentialsManagerProtocol = .vnc
        }
        showCredentialsManager = true
    }

    private func openCredentialsManager(for type: RemoteCredentialProtocolType) {
        credentialsManagerProtocol = type
        showCredentialsManager = true
    }

    private func applySelectedCredentialToUserSettings(_ type: RemoteCredentialProtocolType) {
        guard let selected = credentialsStore.selectedCredential(for: type) else { return }
        let password = credentialsStore.password(for: selected)
        switch type {
        case .vnc:
            userSettings.vncHost = selected.host
            userSettings.vncPort = selected.port
            userSettings.vncUsername = selected.username
            userSettings.vncPassword = password
            vncPortText = "\(selected.port)"
        case .rdp:
            userSettings.rdpHost = selected.host
            userSettings.rdpPort = selected.port
            userSettings.rdpUsername = selected.username
            userSettings.rdpDomain = selected.domain
            userSettings.rdpPassword = password
        }
    }

    private var connectionStatusText: String {
        switch AppStatus.protocolSessionState {
        case .idle:
            return "Idle"
        case .switching:
            return "Switching"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .error:
            return "Error"
        }
    }

    private var connectionStatusColor: Color {
        switch AppStatus.protocolSessionState {
        case .connected:
            return .green
        case .connecting, .switching:
            return .orange
        case .error:
            return .red
        case .idle:
            return .secondary
        }
    }
}

private enum RemoteCredentialProtocolType: String, Codable, CaseIterable, Identifiable {
    case vnc
    case rdp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vnc:
            return "VNC"
        case .rdp:
            return "RDP"
        }
    }

    var defaultPort: Int {
        switch self {
        case .vnc:
            return 5900
        case .rdp:
            return 3389
        }
    }
}

private struct RemoteCredentialEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var protocolType: RemoteCredentialProtocolType
    var displayName: String
    var host: String
    var port: Int
    var username: String
    var domain: String

    var endpointSummary: String {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.isEmpty {
            return cleanUser.isEmpty ? "Not configured" : cleanUser
        }
        if cleanUser.isEmpty {
            return cleanHost
        }
        return "\(cleanUser) @ \(cleanHost)"
    }
}

private final class RemoteCredentialsStore: ObservableObject {
    static let shared = RemoteCredentialsStore()

    @Published private(set) var allEntries: [RemoteCredentialEntry] = []
    @Published private var selectedVNCID: UUID?
    @Published private var selectedRDPID: UUID?

    private let entriesKey = "remoteCredentials.entries"
    private let selectedVNCKey = "remoteCredentials.selectedVNCID"
    private let selectedRDPKey = "remoteCredentials.selectedRDPID"

    private init() {
        load()
        if allEntries.isEmpty {
            bootstrapFromCurrentSettings()
        }
        ensureSelectionsValid()
        persist()
    }

    func entries(for type: RemoteCredentialProtocolType) -> [RemoteCredentialEntry] {
        allEntries.filter { $0.protocolType == type }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    func selectedCredentialID(for type: RemoteCredentialProtocolType) -> UUID? {
        switch type {
        case .vnc:
            return selectedVNCID
        case .rdp:
            return selectedRDPID
        }
    }

    func selectedCredential(for type: RemoteCredentialProtocolType) -> RemoteCredentialEntry? {
        let selectedID = selectedCredentialID(for: type)
        return allEntries.first(where: { $0.id == selectedID && $0.protocolType == type })
            ?? entries(for: type).first
    }

    func selectCredential(id: UUID?, for type: RemoteCredentialProtocolType) {
        switch type {
        case .vnc:
            selectedVNCID = id
        case .rdp:
            selectedRDPID = id
        }
        persist()
    }

    func upsert(_ entry: RemoteCredentialEntry, password: String) {
        if let existingIndex = allEntries.firstIndex(where: { $0.id == entry.id }) {
            allEntries[existingIndex] = entry
        } else {
            allEntries.append(entry)
        }

        if password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            RemoteCredentialKeychainStore.deletePassword(for: entry.id)
        } else {
            RemoteCredentialKeychainStore.savePassword(password, for: entry.id)
        }

        if selectedCredentialID(for: entry.protocolType) == nil {
            selectCredential(id: entry.id, for: entry.protocolType)
        }
        persist()
    }

    func delete(_ entry: RemoteCredentialEntry) {
        allEntries.removeAll { $0.id == entry.id }
        RemoteCredentialKeychainStore.deletePassword(for: entry.id)

        if selectedVNCID == entry.id { selectedVNCID = entries(for: .vnc).first?.id }
        if selectedRDPID == entry.id { selectedRDPID = entries(for: .rdp).first?.id }
        persist()
    }

    func password(for entry: RemoteCredentialEntry) -> String {
        RemoteCredentialKeychainStore.loadPassword(for: entry.id)
    }

    func protocolSubtitle(for type: RemoteCredentialProtocolType) -> String {
        selectedCredential(for: type)?.endpointSummary ?? "Not configured"
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: entriesKey),
           let decoded = try? JSONDecoder().decode([RemoteCredentialEntry].self, from: data) {
            allEntries = decoded
        }

        if let rawVNC = UserDefaults.standard.string(forKey: selectedVNCKey) {
            selectedVNCID = UUID(uuidString: rawVNC)
        }
        if let rawRDP = UserDefaults.standard.string(forKey: selectedRDPKey) {
            selectedRDPID = UUID(uuidString: rawRDP)
        }
    }

    private func persist() {
        if let encoded = try? JSONEncoder().encode(allEntries) {
            UserDefaults.standard.set(encoded, forKey: entriesKey)
        }
        UserDefaults.standard.set(selectedVNCID?.uuidString, forKey: selectedVNCKey)
        UserDefaults.standard.set(selectedRDPID?.uuidString, forKey: selectedRDPKey)
    }

    private func ensureSelectionsValid() {
        if selectedVNCID == nil || !allEntries.contains(where: { $0.id == selectedVNCID && $0.protocolType == .vnc }) {
            selectedVNCID = entries(for: .vnc).first?.id
        }
        if selectedRDPID == nil || !allEntries.contains(where: { $0.id == selectedRDPID && $0.protocolType == .rdp }) {
            selectedRDPID = entries(for: .rdp).first?.id
        }
    }

    private func bootstrapFromCurrentSettings() {
        let settings = UserSettings.shared

        let vncEntry = RemoteCredentialEntry(
            id: UUID(),
            protocolType: .vnc,
            displayName: "Default VNC",
            host: settings.vncHost,
            port: settings.vncPort,
            username: settings.vncUsername,
            domain: ""
        )

        let rdpEntry = RemoteCredentialEntry(
            id: UUID(),
            protocolType: .rdp,
            displayName: "Default RDP",
            host: settings.rdpHost,
            port: settings.rdpPort,
            username: settings.rdpUsername,
            domain: settings.rdpDomain
        )

        allEntries = [vncEntry, rdpEntry]
        selectedVNCID = vncEntry.id
        selectedRDPID = rdpEntry.id

        if !settings.vncPassword.isEmpty {
            RemoteCredentialKeychainStore.savePassword(settings.vncPassword, for: vncEntry.id)
        }
        if !settings.rdpPassword.isEmpty {
            RemoteCredentialKeychainStore.savePassword(settings.rdpPassword, for: rdpEntry.id)
        }
    }
}

private enum RemoteCredentialKeychainStore {
    private static let service = "com.openterface.remote.credentials"

    static func loadPassword(for id: UUID) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: id),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    static func savePassword(_ value: String, for id: UUID) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: id)
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if status == errSecSuccess { return }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func deletePassword(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: id)
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func account(for id: UUID) -> String {
        "credential_\(id.uuidString)"
    }
}

private struct CredentialsManagerDialog: View {
    @ObservedObject var store: RemoteCredentialsStore
    let initialProtocol: RemoteCredentialProtocolType
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProtocol: RemoteCredentialProtocolType
    @State private var selectedEditorEntry: RemoteCredentialEntry?
    @State private var showEditor = false

    init(store: RemoteCredentialsStore,
         initialProtocol: RemoteCredentialProtocolType,
         onDone: @escaping () -> Void) {
        self.store = store
        self.initialProtocol = initialProtocol
        self.onDone = onDone
        _selectedProtocol = State(initialValue: initialProtocol)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Credentials Manager")
                .font(.title2)
                .bold()

            Picker("Protocol", selection: $selectedProtocol) {
                ForEach(RemoteCredentialProtocolType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)

            List {
                ForEach(store.entries(for: selectedProtocol)) { entry in
                    Button {
                        store.selectCredential(id: entry.id, for: selectedProtocol)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName)
                                    .font(.body)
                                Text(entry.endpointSummary)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if store.selectedCredentialID(for: selectedProtocol) == entry.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit") {
                            selectedEditorEntry = entry
                            showEditor = true
                        }
                        Button("Delete", role: .destructive) {
                            store.delete(entry)
                        }
                    }
                }
            }
            .frame(minHeight: 240)

            HStack {
                Button("Add") {
                    selectedEditorEntry = RemoteCredentialEntry(
                        id: UUID(),
                        protocolType: selectedProtocol,
                        displayName: "",
                        host: "",
                        port: selectedProtocol.defaultPort,
                        username: "",
                        domain: ""
                    )
                    showEditor = true
                }

                Button("Edit") {
                    if let selected = store.selectedCredential(for: selectedProtocol) {
                        selectedEditorEntry = selected
                        showEditor = true
                    }
                }
                .disabled(store.selectedCredential(for: selectedProtocol) == nil)

                Button("Delete", role: .destructive) {
                    if let selected = store.selectedCredential(for: selectedProtocol) {
                        store.delete(selected)
                    }
                }
                .disabled(store.selectedCredential(for: selectedProtocol) == nil)

                Spacer()

                Button("Done") {
                    onDone()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 520)
        .sheet(isPresented: $showEditor) {
            if let editorEntry = selectedEditorEntry {
                CredentialEditorDialog(store: store, initialEntry: editorEntry)
            }
        }
    }
}

private struct CredentialEditorDialog: View {
    @ObservedObject var store: RemoteCredentialsStore
    @Environment(\.dismiss) private var dismiss

    @State private var entry: RemoteCredentialEntry
    @State private var password: String

    init(store: RemoteCredentialsStore, initialEntry: RemoteCredentialEntry) {
        self.store = store
        _entry = State(initialValue: initialEntry)
        _password = State(initialValue: store.password(for: initialEntry))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entry.displayName.isEmpty ? "Add Credential" : "Edit Credential")
                .font(.title3)
                .bold()

            HStack {
                Text("Protocol")
                    .frame(width: 90, alignment: .leading)
                Text(entry.protocolType.displayName)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Name")
                    .frame(width: 90, alignment: .leading)
                TextField("My Credential", text: $entry.displayName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("Host / IP")
                    .frame(width: 90, alignment: .leading)
                TextField("127.0.0.1", text: $entry.host)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("Port")
                    .frame(width: 90, alignment: .leading)
                TextField(
                    "\(entry.protocolType.defaultPort)",
                    text: Binding(
                        get: { "\(entry.port)" },
                        set: { newValue in
                            let digits = newValue.filter { $0.isNumber }
                            if let value = Int(digits) {
                                entry.port = max(1, min(value, 65535))
                            }
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("Username")
                    .frame(width: 90, alignment: .leading)
                TextField(entry.protocolType == .rdp ? "Required" : "Optional", text: $entry.username)
                    .textFieldStyle(.roundedBorder)
            }

            if entry.protocolType == .rdp {
                HStack {
                    Text("Domain")
                        .frame(width: 90, alignment: .leading)
                    TextField("Optional", text: $entry.domain)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Text("Password")
                    .frame(width: 90, alignment: .leading)
                SecureField("Optional", text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    if entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        entry.displayName = "\(entry.protocolType.displayName) Credential"
                    }
                    store.upsert(entry, password: password)
                    store.selectCredential(id: entry.id, for: entry.protocolType)
                    dismiss()
                }
                .disabled(entry.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 360)
    }
}
