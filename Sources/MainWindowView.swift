import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            VStack(spacing: 0) {
                DashboardHeader()
                Divider()
                RequestListView()
            }
        }
        .navigationTitle("TokenTracker")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Range", selection: $state.selectedTimeRange) {
                    ForEach(TimeRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: state.selectedTimeRange) { _, _ in
                    state.refreshData()
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    state.refreshData()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh data")
            }
        }
    }
}

// MARK: - Dashboard Header

struct DashboardHeader: View {
    @EnvironmentObject var state: AppState

    private var totalInput: Int {
        state.requests.reduce(0) { $0 + $1.inputTokens }
    }
    private var totalOutput: Int {
        state.requests.reduce(0) { $0 + $1.outputTokens }
    }
    private var totalCost: Double {
        state.requests.reduce(0.0) { $0 + $1.estimatedCost }
    }

    var body: some View {
        HStack(spacing: 24) {
            StatCard(
                title: "Input Tokens",
                value: formatTokens(totalInput),
                icon: "arrow.up.doc",
                color: .blue
            )
            StatCard(
                title: "Output Tokens",
                value: formatTokens(totalOutput),
                icon: "arrow.down.doc",
                color: .green
            )
            StatCard(
                title: "Total Tokens",
                value: formatTokens(totalInput + totalOutput),
                icon: "sum",
                color: .orange
            )
            StatCard(
                title: "Est. Cost",
                value: formatCost(totalCost),
                icon: "dollarsign.circle",
                color: .purple
            )
            StatCard(
                title: "Requests",
                value: "\(state.requests.count)",
                icon: "number",
                color: .gray
            )
        }
        .padding()
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.2fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }

    private func formatCost(_ c: Double) -> String {
        if c < 0.01 && c > 0 {
            return String(format: "$%.4f", c)
        }
        return String(format: "$%.2f", c)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List {
            Section("Proxy") {
                HStack {
                    Circle()
                        .fill(state.proxyRunning ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(state.proxyRunning ? "Running" : "Stopped")
                        .foregroundStyle(
                            state.proxyRunning ? .primary : .secondary)
                }

                if state.proxyRunning {
                    Text("localhost:\(state.proxyPort)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Button(state.proxyRunning ? "Stop Proxy" : "Start Proxy") {
                    if state.proxyRunning {
                        state.stopProxy()
                    } else {
                        state.startProxy()
                    }
                }
            }

            Section("Today") {
                LabeledContent("Input", value: "\(state.todayInputTokens)")
                LabeledContent("Output", value: "\(state.todayOutputTokens)")
                LabeledContent("Cost",
                    value: String(format: "$%.4f", state.todayCost))
            }

            if let err = state.errorMessage {
                Section("Error") {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Request List

struct RequestListView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.requests.isEmpty {
            ContentUnavailableView(
                "No Requests",
                systemImage: "tray",
                description: Text(
                    state.proxyRunning
                    ? "Waiting for API calls through the proxy…"
                    : "Start the proxy to begin tracking."
                )
            )
        } else {
            Table(state.requests) {
                TableColumn("Time") { row in
                    Text(timeLabel(row.timestamp))
                        .font(.caption)
                        .monospacedDigit()
                }
                .width(min: 65, ideal: 75)

                TableColumn("Model") { row in
                    Text(row.shortModel)
                        .font(.caption)
                }
                .width(min: 70, ideal: 90)

                TableColumn("Input") { row in
                    Text("\(row.inputTokens)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.blue)
                }
                .width(min: 55, ideal: 70)

                TableColumn("Output") { row in
                    Text("\(row.outputTokens)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.green)
                }
                .width(min: 55, ideal: 70)

                TableColumn("Cache In") { row in
                    let total = row.cacheCreationInputTokens
                        + row.cacheReadInputTokens
                    Text(total > 0 ? "\(total)" : "—")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
                .width(min: 55, ideal: 70)

                TableColumn("Cost") { row in
                    Text(String(format: "$%.4f", row.estimatedCost))
                        .font(.caption)
                        .monospacedDigit()
                }
                .width(min: 60, ideal: 70)

                TableColumn("Status") { row in
                    if row.isError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .help(row.error)
                    } else {
                        Text("\(row.statusCode)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 40, ideal: 50)
            }
        }
    }

    private func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
