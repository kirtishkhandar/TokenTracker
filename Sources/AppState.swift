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
    @Published var modelSummaries: [ModelSummary] = []
    @Published var apiKeySummaries: [ApiKeySummary] = []
    @Published var filterModel: String? = nil
    @Published var filterApiKey: String? = nil

    // MARK: - Menu Bar

    /// Tokens consumed in the last 60 seconds (rolling window).
    @Published var recentTokensPerMinute: Int = 0

    /// Dynamic speedometer icon based on current consumption rate (tokens/min).
    /// Uses a 60-second rolling average, refreshed every 3 seconds.
    var menuBarIcon: String {
        if !proxyRunning { return "gauge.with.dots.needle.0percent" }
        switch recentTokensPerMinute {
        case    0..<500:    return "gauge.with.dots.needle.0percent"
        case  500..<5_000:  return "gauge.with.dots.needle.33percent"
        case 5_000..<25_000: return "gauge.with.dots.needle.50percent"
        case 25_000..<100_000: return "gauge.with.dots.needle.67percent"
        default:            return "gauge.with.dots.needle.100percent"
        }
    }

    /// Color tint for the menu bar label based on consumption rate.
    /// Steps: gray → green → mint → yellow → orange → red
    var menuBarColor: Color {
        if !proxyRunning { return .secondary }
        switch recentTokensPerMinute {
        case 0:             return .secondary
        case   1..<500:     return .green
        case  500..<2_000:  return .green
        case 2_000..<5_000: return .mint
        case 5_000..<10_000: return .yellow
        case 10_000..<25_000: return .yellow
        case 25_000..<50_000: return .orange
        case 50_000..<100_000: return .orange
        default:            return .red
        }
    }

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

    /// Requests filtered by selected model/key, or all if no filter.
    var filteredRequests: [UsageRecord] {
        requests.filter { rec in
            if let m = filterModel, rec.model != m { return false }
            if let k = filterApiKey, rec.apiKeyHint != k { return false }
            return true
        }
    }

    // MARK: - Internal

    private(set) var proxyProcess: Process?
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

        installLaunchAgentIfNeeded()
        autoPrune()
        startProxy()
        startRefreshTimer()

        // Ensure proxy is killed on any app termination path (Cmd+Q, Dock quit, etc.)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // willTerminate fires on main thread; call stopProxy synchronously
            MainActor.assumeIsolated {
                self.stopProxy()
            }
        }
    }

    // MARK: - Launch at Login

    static let launchAgentPath = NSHomeDirectory()
        + "/Library/LaunchAgents/com.tokentracker.app.plist"

    /// Install LaunchAgent on first launch so app starts at login by default.
    private func installLaunchAgentIfNeeded() {
        guard !FileManager.default.fileExists(atPath: Self.launchAgentPath) else { return }
        Self.installLaunchAgent()
    }

    static func installLaunchAgent() {
        let appPath = Bundle.main.bundlePath
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.tokentracker.app</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>-a</string>
                <string>\(appPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        try? plist.write(toFile: Self.launchAgentPath, atomically: true, encoding: .utf8)
    }

    static func removeLaunchAgent() {
        try? FileManager.default.removeItem(atPath: Self.launchAgentPath)
    }

    deinit {
        if let proc = proxyProcess, proc.isRunning {
            proc.terminate()
        }
    }

    // MARK: - Proxy Lifecycle

    /// Kill any process listening on the given port (e.g. a stale proxy from a previous run).
    private func killProcessOnPort(_ port: Int) {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        do {
            try lsof.run()
            lsof.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return }
            // Kill each PID found on this port
            for pidStr in output.components(separatedBy: "\n") {
                if let pid = Int32(pidStr.trimmingCharacters(in: .whitespaces)) {
                    kill(pid, SIGTERM)
                }
            }
            // Brief pause to let the port be released
            Thread.sleep(forTimeInterval: 0.3)
        } catch {
            // lsof not available or no process on port – fine, proceed
        }
    }

    func startProxy() {
        guard !proxyRunning else { return }
        guard FileManager.default.fileExists(atPath: proxyScriptPath) else {
            errorMessage = "Proxy script not found at: \(proxyScriptPath)"
            return
        }

        // Kill any stale proxy process occupying our port
        killProcessOnPort(proxyPort)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            proxyScriptPath,
            "--port", "\(proxyPort)",
            "--db", dbPath,
        ]
        // Log proxy output to a file (truncate on each start for clean logs)
        let logDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("TokenTracker")
        let logPath = logDir.appendingPathComponent("proxy.log").path
        // Truncate log file so we only see output from this launch
        FileManager.default.createFile(atPath: logPath, contents: Data())
        let logHandle = FileHandle(forWritingAtPath: logPath)
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice

        // Detect unexpected proxy exit
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.proxyRunning = false
                if proc.terminationStatus != 0 {
                    self?.errorMessage = "Proxy exited with code \(proc.terminationStatus)"
                }
            }
        }

        do {
            try process.run()
            proxyProcess = process
            proxyRunning = true
            errorMessage = nil

            // Set env system-wide so all apps pick it up immediately
            setSystemEnv()

            // Auto-add to ~/.zshrc on first launch
            addToZshrcIfNeeded()

            // Small delay then verify it started
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.verifyProxy()
            }
        } catch {
            errorMessage = "Failed to start proxy: \(error.localizedDescription)"
        }
    }

    func stopProxy() {
        if let proc = proxyProcess, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        proxyProcess = nil
        proxyRunning = false
        unsetSystemEnv()
    }

    func restartProxy() {
        stopProxy()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.startProxy()
        }
    }

    private func verifyProxy(attempt: Int = 1) {
        guard let url = URL(string: "http://127.0.0.1:\(proxyPort)/_health")
        else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        URLSession.shared.dataTask(with: request) { [weak self] _, resp, _ in
            Task { @MainActor in
                guard let self else { return }
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    self.proxyRunning = true
                    self.errorMessage = nil
                } else if attempt < 5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.verifyProxy(attempt: attempt + 1)
                    }
                } else {
                    self.errorMessage = "Proxy started but not responding after \(attempt) attempts"
                }
            }
        }.resume()
    }

    // MARK: - Environment Configuration

    private func setSystemEnv() {
        let proxyURL = "http://localhost:\(proxyPort)"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["setenv", "ANTHROPIC_BASE_URL", proxyURL]
        try? task.run()
        task.waitUntilExit()
    }

    private func unsetSystemEnv() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["unsetenv", "ANTHROPIC_BASE_URL"]
        try? task.run()
        task.waitUntilExit()
    }

    func addToZshrcIfNeeded() {
        let zshrcPath = NSHomeDirectory() + "/.zshrc"
        guard let contents = try? String(contentsOfFile: zshrcPath, encoding: .utf8) else {
            // If file doesn't exist, create it with the export
            let block = """
            # TokenTracker proxy (auto-configured)
            export ANTHROPIC_BASE_URL=http://localhost:\(proxyPort)
            """
            try? block.write(toFile: zshrcPath, atomically: true, encoding: .utf8)
            return
        }

        if !contents.contains("ANTHROPIC_BASE_URL") {
            let block = "\n# TokenTracker proxy (auto-configured)\nexport ANTHROPIC_BASE_URL=http://localhost:\(proxyPort)\n"
            if let handle = FileHandle(forWritingAtPath: zshrcPath) {
                handle.seekToEndOfFile()
                handle.write(block.data(using: .utf8)!)
                handle.closeFile()
            }
        }
    }

    // MARK: - History Management

    /// Delete all request history.
    func clearHistory() {
        let db = UsageDB(path: dbPath)
        db.deleteAll()
        refreshData()
    }

    /// Auto-prune: delete records older than 30 days, or if DB exceeds 100 MB.
    private func autoPrune() {
        let db = UsageDB(path: dbPath)

        // Prune records older than 30 days
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -30, to: Date()) ?? Date()
        db.deleteOlderThan(cutoff)

        // If DB still exceeds 100 MB, keep only last 30 days
        let fileSize = (try? FileManager.default.attributesOfItem(
            atPath: dbPath)[.size] as? Int) ?? 0
        if fileSize > 100 * 1024 * 1024 {
            db.vacuum()
        }
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
        modelSummaries = db.modelSummaries(from: range.start, to: range.end)
        apiKeySummaries = db.apiKeySummaries(from: range.start, to: range.end)

        let todayRange = TimeRange.today.dateRange
        let todayRecords = db.fetchRequests(
            from: todayRange.start, to: todayRange.end)
        todayInputTokens = todayRecords.reduce(0) { $0 + $1.inputTokens }
        todayOutputTokens = todayRecords.reduce(0) { $0 + $1.outputTokens }
        todayCost = todayRecords.reduce(0.0) { $0 + $1.estimatedCost }

        // Rolling rate: tokens consumed in the last 60 seconds
        let oneMinuteAgo = Date().addingTimeInterval(-60)
        let recentRecords = db.fetchRequests(from: oneMinuteAgo, to: Date())
        recentTokensPerMinute = recentRecords.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens
        }
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
