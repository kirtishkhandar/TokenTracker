import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Circle()
                    .fill(state.proxyRunning ? .green : .red)
                    .frame(width: 8, height: 8)
                Text("TokenTracker")
                    .font(.headline)
                Spacer()
                Text(state.proxyRunning ? "Proxy running" : "Proxy stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Today's stats
            Text("Today")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text("Input")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(state.todayInputTokens)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.blue)
                }
                VStack(alignment: .leading) {
                    Text("Output")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(state.todayOutputTokens)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.green)
                }
                VStack(alignment: .leading) {
                    Text("Est. Cost")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(format: "$%.4f", state.todayCost))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.purple)
                }
            }

            // Recent requests
            if !state.requests.isEmpty {
                Divider()
                Text("Recent")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(state.requests.prefix(5)) { req in
                    HStack {
                        Text(req.shortModel)
                            .font(.caption)
                            .frame(width: 70, alignment: .leading)
                        Text("↑\(req.inputTokens)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.blue)
                        Text("↓\(req.outputTokens)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.green)
                        Spacer()
                        Text(timeAgo(req.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            // Quick actions
            HStack {
                Button(state.proxyRunning ? "Stop" : "Start") {
                    if state.proxyRunning {
                        state.stopProxy()
                    } else {
                        state.startProxy()
                    }
                }
                .controlSize(.small)

                Spacer()

                Button("Quit") {
                    state.stopProxy()
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func timeAgo(_ date: Date) -> String {
        let secs = -date.timeIntervalSinceNow
        if secs < 60 { return "\(Int(secs))s ago" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        return "\(Int(secs / 3600))h ago"
    }
}
