import SwiftUI
import Combine

/// Central observable state for the app. Manages the proxy process,
/// reads usage data from the shared SQLite database, and provides
/// computed properties for the UI.
@MainActor
class AppState: ObservableObject {

    // MARK: - Published State

    @Published var proxyRunning = false
    @Published var proxyPort: Int = 5005
    @Published var requests: [UsageRecord] = []
    @Published var todayInputTokens: Int = 0
    @Published var todayOutputTokens: Int = 0
    @Published var todayCost: Double = 0.0
    @Published var errorMessage: String?
    @Published var selectedTimeRange: TimeRange = .today

    // MARK: - Menu Bar

    var menuBarLabel: String {
        if !proxyRunning { return "Off" }
        let total = todayInputTokens + todayOutputTokens
        if total > 1_000_000 {
            return String(format: "%.1fM", Double(total) / 1_000_000)
        } else if total > 1_000 {
            return String(format: "%.0fK", Double(total) / 1_000)
        } else {
            return "\(total)"
        }
    }

    // MARK: - Internal

    private var proxyProcess: Process?
    private var refreshTimer: Timer?
    private let dbPath: String
    private let proxyScriptPath: String

    // MARK: - Init

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("TokenTracker")

        try? FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true)

        self.dbPath = appSupport
            .appendingPathComponent("usage.db").path

        // Proxy script: look in app bundle first, then fall back to
        // a known location next to the app.
        if let bundled = Bundle.main.path(
            forResource: "proxy_server", ofType: "py") {
            self.proxyScriptPath = bundled
        } else {
            // Development fallback: same directory as the built binary
            let devPath = Bundle.main.bundlePath
                .replacingOccurrences(
                    of: "/Contents/MacOS/TokenTracker", with: "")
            self.proxyScriptPath = (devPath as NSString)
                .appendingPathComponent("proxy/proxy_server.py")
        }

        startProxy()
        startRefreshTimer()
    }

    deinit {
        proxyProcess?.terminate()
    }

    // MARK: - Proxy Lifecycle

    func startProxy() {
        guard !proxyRunning else { return }
        guard FileManager.default.fileExists(atPath: proxyScriptPath) else {
            errorMessage = "Proxy script not found at: \(proxyScriptPath)"
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            proxyScriptPath,
            "--port", "\(proxyPort)",
            "--db", dbPath,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Terminate proxy when app quits
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.proxyRunning = false
            }
        }

        do {
            try process.run()
            proxyProcess = process
            proxyRunning = true
            errorMessage = nil

            // Small delay then verify it started
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.verifyProxy()
            }
        } catch {
            errorMessage = "Failed to start proxy: \(error.localizedDescription)"
        }
    }

    func stopProxy() {
        proxyProcess?.terminate()
        proxyProcess = nil
        proxyRunning = false
    }

    func restartProxy() {
        stopProxy()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.startProxy()
        }
    }

    private func verifyProxy() {
        guard let url = URL(string: "http://127.0.0.1:\(proxyPort)/_health")
        else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { [weak self] data, resp, err in
            Task { @MainActor in
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    self?.proxyRunning = true
                    self?.errorMessage = nil
                } else {
                    self?.errorMessage = "Proxy started but not responding"
                }
            }
        }.resume()
    }

    // MARK: - Data Refresh

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: 3.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshData()
            }
        }
        refreshData()
    }

    func refreshData() {
        let db = UsageDB(path: dbPath)
        let range = selectedTimeRange.dateRange

        requests = db.fetchRequests(from: range.start, to: range.end)

        let todayRange = TimeRange.today.dateRange
        let todayRecords = db.fetchRequests(
            from: todayRange.start, to: todayRange.end)
        todayInputTokens = todayRecords.reduce(0) { $0 + $1.inputTokens }
        todayOutputTokens = todayRecords.reduce(0) { $0 + $1.outputTokens }
        todayCost = todayRecords.reduce(0.0) { $0 + $1.estimatedCost }
    }
}

// MARK: - Time Range

enum TimeRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case week = "This Week"
    case month = "This Month"
    case all = "All Time"

    var id: String { rawValue }

    struct DateInterval {
        let start: Date
        let end: Date
    }

    var dateRange: DateInterval {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .today:
            let start = cal.startOfDay(for: now)
            return DateInterval(start: start, end: now)
        case .week:
            let start = cal.dateInterval(of: .weekOfYear, for: now)?.start
                ?? cal.startOfDay(for: now)
            return DateInterval(start: start, end: now)
        case .month:
            let start = cal.dateInterval(of: .month, for: now)?.start
                ?? cal.startOfDay(for: now)
            return DateInterval(start: start, end: now)
        case .all:
            return DateInterval(
                start: Date.distantPast, end: now)
        }
    }
}
