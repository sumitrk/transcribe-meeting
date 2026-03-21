import SwiftUI

@main
struct TranscribeMeetingApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            let icon = appState.isRecording ? "record.circle.fill" : "mic"
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.menu)
    }
}
