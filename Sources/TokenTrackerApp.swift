import SwiftUI

@main
struct TokenTrackerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Main window (launched from Dock icon)
        WindowGroup {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: 700, minHeight: 500)
        }
        .defaultSize(width: 900, height: 650)

        // Menu bar extra (persistent)
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chart.bar.fill")
                Text(appState.menuBarLabel)
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
