import SwiftUI

@MainActor
struct NotesListView: View {
    @Environment(NoteStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(AIController.self) private var ai
    @Environment(NetworkMonitor.self) private var network
    @StateObject private var whisperState = WhisperStateManager.shared
    @State private var showRecorder = false
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false

    private var filteredNotes: [Note] { store.notes.filter { $0.matchesSearch(searchText) } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = store.storageError {
                    Text(error).font(.footnote).foregroundStyle(.red).padding()
                }
                if !settings.isBackendConfigured {
                    Label("AI Not Configured — local notes still work", systemImage: "iphone")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                if store.notes.isEmpty {
                    ContentUnavailableView("No Notes Yet", systemImage: "mic",
                                           description: Text("Tap Record to save a voice note on this device."))
                } else if filteredNotes.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        Section("Recent Notes") {
                            ForEach(filteredNotes) { note in
                                NavigationLink(value: note.id) { NoteRow(note: note) }
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        Button { share(note) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                                            .tint(.blue)
                                    }
                            }
                            .onDelete { offsets in
                                // Map displayed offsets to stable IDs BEFORE changing the store.
                                let ids = offsets.compactMap { filteredNotes.indices.contains($0) ? filteredNotes[$0].id : nil }
                                for id in ids {
                                    ai.cancel(noteID: id)
                                    do { try store.delete(id: id) }
                                    catch { ai.message = error.localizedDescription }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Voice Notes")
            .navigationDestination(for: UUID.self) { id in NoteDetailView(noteID: id) }
            .searchable(text: $searchText, prompt: "Search notes and transcripts")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if whisperState.isTranscribing { Text("Local transcription is running").font(.caption) }
                    RecordButton(isRecording: false) { showRecorder = true }
                        .accessibilityLabel("Record a voice note")
                        .disabled(store.isReadOnly || whisperState.isTranscribing)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showRecorder) { RecorderSheet() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showShareSheet, onDismiss: clearShare) { ShareSheet(shareItems) }
            .alert("Voice Notes", isPresented: Binding(
                get: { ai.message != nil }, set: { if !$0 { ai.message = nil } })) {
                    Button("OK") { ai.message = nil }
                } message: { Text(ai.message ?? "") }
        }
    }

    private func share(_ note: Note) {
        do {
            let (body, file) = try TranscriptSharing.makeItems(for: note)
            shareItems = [body, file]
            showShareSheet = true
        } catch { ai.message = "The transcript could not be prepared for sharing." }
    }

    private func clearShare() {
        for case let file as URL in shareItems where file.deletingLastPathComponent() == FileManager.default.temporaryDirectory {
            try? FileManager.default.removeItem(at: file)
        }
        shareItems = []
    }
}

private struct NoteRow: View {
    let note: Note
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.displayTitle).font(.headline).lineLimit(2)
            if note.transcriptionStatus == .failed {
                Label("Audio saved · transcription needs attention", systemImage: "waveform")
                    .font(.caption).foregroundStyle(.secondary)
            } else if note.transcriptionStatus == .processing {
                Text("Transcribing locally…").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(note.createdAt.formatted(.dateTime.year().month().day().hour().minute()))
                Spacer()
                Text(note.duration.mmSS)
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
