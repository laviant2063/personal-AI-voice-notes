import SwiftUI

@main
@MainActor
struct WalkWriteApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: NoteStore
    @State private var settings: AppSettings
    @State private var network: NetworkMonitor
    @State private var ai: AIController

    init() {
        let store = NoteStore()
        let settings = AppSettings()
        let network = NetworkMonitor()
        let ai = AIController(store: store, settings: settings, network: network)
        store.onTranscriptionSaved = { [weak ai] id in ai?.transcriptSaved(noteID: id) }
        _store = State(initialValue: store)
        _settings = State(initialValue: settings)
        _network = State(initialValue: network)
        _ai = State(initialValue: ai)
    }

    var body: some Scene {
        WindowGroup {
            NotesListView()
                .environment(store)
                .environment(settings)
                .environment(network)
                .environment(ai)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { ai.cancelAll() }
                    if phase == .active { settings.refreshTokenStatus() }
                }
                // No relaunch, foreground, or network reconnection upload hook.
        }
    }
}
