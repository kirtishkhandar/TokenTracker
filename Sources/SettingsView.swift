import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var portText = ""
    @State private var copied = false
    @State private var shellConfigured = false
    @State private var launchAtLogin = false

    var shellCommand: String {
        "export ANTHROPIC_BASE_URL=http://localhost:\(state.proxyPort)"
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            setupTab
                .tabItem { Label("Setup", systemImage: "terminal") }
        }
        .frame(width: 520, height: 340)
        .onAppear {
            portText = "\(state.proxyPort)"
        }
    }

    // MARK: - General Tab

    var generalTab: some View {
        Form {
            Section("Proxy Port") {
                HStack {
                    Text("Port:")
                    TextField("Port", text: $portText)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                    Button("Apply") {
                        if let port = Int(portText),
                           (1024...65535).contains(port) {
                            state.proxyPort = port
                            state.restartProxy()
                        }
                    }
                    .disabled(portText == "\(state.proxyPort)")
                }
                .padding(.vertical, 2)

                HStack {
                    Text("Status:")
                    Circle()
                        .fill(state.proxyRunning ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(state.proxyRunning ? "Running" : "Stopped")
                }
            }

            Section("Data") {
                let dbPath = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                ).first!.appendingPathComponent("TokenTracker/usage.db").path

                LabeledContent("Database:") {
                    Text(dbPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(
                        dbPath,
                        inFileViewerRootedAtPath: ""
                    )
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Setup Tab

    var setupTab: some View {
        Form {
            Section("Shell Configuration") {
                Text("Add this line to your shell profile (~/.zshrc, ~/.bashrc, etc.):")
                    .font(.callout)

                HStack {
                    Text(shellCommand)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)

                    Button {
                        copyToClipboard(shellCommand)
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help("Copy to clipboard")
                }

                Button(shellConfigured ? "Added to ~/.zshrc" : "Add to ~/.zshrc automatically") {
                    addToZshrc()
                }
                .disabled(shellConfigured)
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        if newValue {
                            installLaunchAgent()
                        } else {
                            removeLaunchAgent()
                        }
                    }
            }

            Section("How It Works") {
                VStack(alignment: .leading, spacing: 6) {
                    step("1", "The proxy runs on a local port (e.g., \(state.proxyPort))")
                    step("2", "ANTHROPIC_BASE_URL redirects API calls to the proxy")
                    step("3", "Requests are forwarded to the Anthropic API")
                    step("4", "Token usage from each response is logged to a local SQLite database")
                    step("5", "Your scripts, Claude Code, etc. are all tracked automatically")
                }
                .font(.callout)
            }

            Section("Limitations") {
                Text("Claude.ai (web chat) uses your subscription, not the API key. Those tokens are NOT tracked by this app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            checkZshrc()
            checkLaunchAgent()
        }
    }

    private func checkZshrc() {
        let zshrcPath = NSHomeDirectory() + "/.zshrc"
        if let contents = try? String(contentsOfFile: zshrcPath, encoding: .utf8) {
            shellConfigured = contents.contains("ANTHROPIC_BASE_URL")
        }
    }

    private func addToZshrc() {
        state.addToZshrcIfNeeded()
        shellConfigured = true
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }

    private func checkLaunchAgent() {
        launchAtLogin = FileManager.default.fileExists(atPath: AppState.launchAgentPath)
    }

    private func installLaunchAgent() {
        AppState.installLaunchAgent()
    }

    private func removeLaunchAgent() {
        AppState.removeLaunchAgent()
    }

    private func step(_ num: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(num)
                .font(.caption2.bold())
                .frame(width: 18, height: 18)
                .background(.blue.opacity(0.15),
                             in: Circle())
            Text(text)
        }
    }
}
