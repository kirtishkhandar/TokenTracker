import SwiftUI

@main
struct TokenTrackerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Main window
        WindowGroup(id: "dashboard") {
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
                Image(systemName: appState.menuBarIcon)
                    .foregroundStyle(appState.menuBarColor)
                Text(appState.menuBarLabel)
                    .monospacedDigit()
                    .foregroundStyle(appState.menuBarColor)
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
