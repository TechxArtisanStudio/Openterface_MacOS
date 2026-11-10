import SwiftUI

// MARK: - MCP Settings View

struct MCPSettingsView: View {
    @ObservedObject private var settings = UserSettings.shared
    @State private var isServerRunning = false
    @State private var showToken = false
    @State private var copiedConfig = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MCP Server")
                .font(.headline)

            Text("Expose Openterface KVM controls as MCP tools for AI clients (Claude Desktop, Cursor, etc.)")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            Toggle("Enable MCP Server", isOn: $settings.mcpServerEnabled)
                .onChange(of: settings.mcpServerEnabled) { enabled in
                    if enabled {
                        MCPServer.shared.start(
                            port: settings.mcpServerPort,
                            authToken: settings.mcpAuthToken,
                            bindLocalhostOnly: settings.mcpBindLocalhostOnly
                        )
                    } else {
                        MCPServer.shared.stop()
                    }
                    isServerRunning = MCPServer.shared.isRunning
                }

            HStack {
                Text("Port:")
                TextField("Port", value: $settings.mcpServerPort, format: .number)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                    .disabled(settings.mcpServerEnabled)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(isServerRunning ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(isServerRunning ? "Running" : "Stopped")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Toggle("Bind to localhost only", isOn: $settings.mcpBindLocalhostOnly)
                .disabled(settings.mcpServerEnabled)
                .help("When enabled, only local connections are accepted. Disable to allow LAN access.")

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Authentication Token")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack {
                    if showToken {
                        Text(settings.mcpAuthToken)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text(String(repeating: "•", count: 36))
                            .font(.system(.caption, design: .monospaced))
                    }
                    Spacer()
                    Button(showToken ? "Hide" : "Show") {
                        showToken.toggle()
                    }
                    .buttonStyle(.borderless)
                    Button("Regenerate") {
                        settings.regenerateMCPAuthToken()
                    }
                    .buttonStyle(.borderless)
                    .disabled(settings.mcpServerEnabled)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Client Configuration")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Add this to your MCP client config (e.g. Claude Desktop):")
                    .font(.caption)
                    .foregroundColor(.secondary)

                let config = clientConfigJSON
                ScrollView {
                    Text(config)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)

                Button(copiedConfig ? "Copied!" : "Copy Config") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(config, forType: .string)
                    copiedConfig = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedConfig = false
                    }
                }
                .buttonStyle(.bordered)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Available Tools (\(tools.count))")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Exposed to MCP clients when the server is enabled. * = required argument.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tools, id: \.name) { tool in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name)
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(.semibold)
                            if let description = tool.description {
                                Text(description)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(argsSummary(tool))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
            }

            if isServerRunning {
                HStack {
                    Text("Active sessions: \(MCPServer.shared.activeSessionCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding()
        .onAppear {
            isServerRunning = MCPServer.shared.isRunning
            MCPServer.shared.onStatusChanged = { running in
                DispatchQueue.main.async {
                    isServerRunning = running
                }
            }
        }
    }

    private var tools: [MCPToolDefinition] {
        MCPServer.shared.toolRegistry.listTools()
    }

    private func argsSummary(_ tool: MCPToolDefinition) -> String {
        let props = tool.inputSchema.properties?.keys.sorted() ?? []
        guard !props.isEmpty else { return "args: none" }
        let required = Set(tool.inputSchema.required ?? [])
        return "args: " + props.map { required.contains($0) ? "\($0)*" : $0 }.joined(separator: ", ")
    }

    private var clientConfigJSON: String {
        let port = settings.mcpServerPort
        let token = settings.mcpAuthToken
        return """
        {
          "mcpServers": {
            "openterface": {
              "type": "http",
              "url": "http://localhost:\(port)/mcp",
              "headers": {
                "Authorization": "Bearer \(token)"
              }
            }
          }
        }
        """
    }
}