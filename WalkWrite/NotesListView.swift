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
                    Label("AI 미설정 · 로컬 노트 기능은 계속 사용할 수 있습니다", systemImage: "iphone")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                        .accessibilityIdentifier("aiConfigurationStatus")
                }
                if store.notes.isEmpty {
                    EmptyNotesView()
                } else if filteredNotes.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        Section("최근 노트") {
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
            .navigationTitle("내 노트")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in NoteDetailView(noteID: id) }
            .searchable(text: $searchText, prompt: "노트와 받아쓰기 검색")
            .safeAreaInset(edge: .bottom) {
                HStack(alignment: .bottom, spacing: 12) {
                    if whisperState.isTranscribing {
                        Label("로컬 음성 인식 중", systemImage: "waveform")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    RecordButton(isRecording: false, diameter: 72) { showRecorder = true }
                        .accessibilityLabel("실시간 음성 인식 노트 시작")
                        .disabled(store.isReadOnly || whisperState.isTranscribing)
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .fullScreenCover(isPresented: $showRecorder) { RecorderSheet() }
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

private struct EmptyNotesView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("노트가 없습니다")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("emptyNotesTitle")
            Text("녹음을 시작하여 첫 노트를 만들어보세요")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
