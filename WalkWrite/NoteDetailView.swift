import SwiftUI
import MessageUI

@MainActor
struct NoteDetailView: View {
    let noteID: UUID
    @Environment(NoteStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(AIController.self) private var ai
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = AudioPlayer()
    @StateObject private var transcriber = RecorderViewModel()
    @StateObject private var model = WhisperModelManager.shared
    @StateObject private var whisperState = WhisperStateManager.shared
    @State private var editingTranscript = false
    @State private var showingSettings = false
    @State private var confirmDelete = false
    @State private var localError: String?
    @State private var shareItems: [Any] = []
    @State private var showingShare = false
    @State private var mailInfo: MailInfo?
    @State private var temporaryExports: [URL] = []

    var body: some View {
        Group {
            if let note = store[noteID] {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        Text(note.displayTitle).font(.title2).bold().textSelection(.enabled)
                        Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline).foregroundStyle(.secondary)
                        audioSection(note)
                        aiSection(note)
                        if !note.keyPoints.isEmpty { keyPointsSection(note) }
                        actionItemsSection(note)
                        transcriptSection(note)
                        if let localError { Text(localError).foregroundStyle(.red) }
                        if let error = store.storageError { Text(error).foregroundStyle(.red) }
                    }
                    .padding()
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .task(id: note.audioURL) {
                    player.load(note.audioURL)
                    transcriber.attachStore(store)
                    transcriber.transcriptionLanguage = WhisperLanguage(rawValue: settings.whisperLanguage) ?? .automatic
                }
            } else {
                ContentUnavailableView("Note Unavailable", systemImage: "doc", description: Text("The note may have been deleted."))
            }
        }
        .navigationTitle("Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Share Transcript", systemImage: "square.and.arrow.up") { share(includeAudio: false) }
                    Button("Share Audio + Transcript", systemImage: "waveform") { share(includeAudio: true) }
                    Button("Email Transcript", systemImage: "envelope") { email(includeAudio: false) }
                    Button("Email Audio + Transcript", systemImage: "envelope.fill") { email(includeAudio: true) }
                    Button("Delete Note", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        .disabled(store.isReadOnly || transcriber.isProcessing)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("Delete this note and its audio?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Note", role: .destructive) {
                ai.cancel(noteID: noteID)
                player.stop()
                do { try store.delete(id: noteID); dismiss() }
                catch { localError = error.localizedDescription }
            }
        }
        .sheet(isPresented: $editingTranscript) {
            if let note = store[noteID] { TranscriptEditor(note: note) }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingShare, onDismiss: clearExports) { ShareSheet(shareItems) }
        .sheet(item: $mailInfo, onDismiss: clearExports) { info in
            MailComposer(subject: info.subject, body: info.body, attachments: info.attachments)
        }
        .onDisappear {
            player.stop()
            transcriber.cancelTranscription()
        }
    }

    private func audioSection(_ note: Note) -> some View {
        GroupBox("Audio") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button { player.toggle() } label: {
                        Label(player.isPlaying ? "Pause" : "Play",
                              systemImage: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    }.buttonStyle(.bordered)
                    Spacer()
                    Text("\(player.currentTime.mmSS) / \(max(player.duration, note.duration).mmSS)")
                        .font(.caption).monospacedDigit()
                }
                Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                       in: 0...max(player.duration, 0.1))
                    .disabled(player.duration <= 0)
                    .accessibilityLabel("Playback position")
                if let error = player.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
    }

    private func aiSection(_ note: Note) -> some View {
        GroupBox("AI SUMMARY") {
            VStack(alignment: .leading, spacing: 12) {
                if let summary = note.aiSummary {
                    Text(summary).textSelection(.enabled)
                } else {
                    Text("No AI summary yet. Your audio and transcript are saved locally.")
                        .foregroundStyle(.secondary)
                }
                if note.isAIResultStale {
                    Label("This result belongs to an older transcript revision.", systemImage: "clock.arrow.circlepath")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if note.aiModel == "legacy-local-llm" {
                    Text("Imported legacy local AI result — not an OpenAI result.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let model = note.aiModel {
                    Text(model).font(.caption).foregroundStyle(.secondary)
                }
                if let date = note.aiGeneratedAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = note.aiError { Text(error).font(.footnote).foregroundStyle(.orange) }
                if ai.processingIDs.contains(noteID) {
                    ProgressView("Generating AI result…")
                    Button("Cancel AI Processing") { ai.cancel(noteID: noteID) }.buttonStyle(.bordered)
                } else if settings.isBackendConfigured {
                    Button {
                        ai.requestSummary(noteID: noteID)
                    } label: {
                        Label(note.hasAIResult ? "Regenerate AI Summary" : "Generate AI Summary", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isReadOnly || note.editedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || !note.recordingComplete)
                    Text("Sends the saved edited transcript to your backend and OpenAI. A failed regeneration keeps the existing result.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("AI Not Configured").font(.headline)
                    Button("Open AI Settings") { showingSettings = true }.buttonStyle(.bordered)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func keyPointsSection(_ note: Note) -> some View {
        GroupBox("KEY POINTS") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(note.keyPoints.enumerated()), id: \.offset) { _, point in
                    Text("• " + point).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionItemsSection(_ note: Note) -> some View {
        GroupBox("ACTION ITEMS") {
            VStack(alignment: .leading, spacing: 8) {
                if note.actionItems.isEmpty {
                    Text(note.hasAIResult ? "No action items were generated." : "Available after AI processing.")
                        .foregroundStyle(.secondary)
                }
                ForEach(note.actionItems) { item in
                    Toggle(item.text, isOn: Binding(
                        get: { store[noteID]?.actionItems.first(where: { $0.id == item.id })?.completed ?? item.completed },
                        set: { completed in
                            do { try store.setActionCompleted(noteID: noteID, actionID: item.id, completed: completed) }
                            catch { localError = error.localizedDescription }
                        }))
                    .disabled(store.isReadOnly)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func transcriptSection(_ note: Note) -> some View {
        GroupBox("TRANSCRIPT") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Edited transcript · revision \(note.transcriptRevision)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit") { editingTranscript = true }.disabled(store.isReadOnly)
                }
                if note.editedTranscript.isEmpty, note.liveTranscriptDraft != nil {
                    Label("Provisional on-device live transcript — final Whisper text was not available.",
                          systemImage: "waveform.badge.exclamationmark")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Text(note.displayTranscript.isEmpty ? "No transcript yet." : note.displayTranscript)
                    .textSelection(.enabled)
                if let error = note.transcriptionError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
                if let error = transcriber.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if transcriber.isProcessing {
                    ProgressView(value: transcriber.transcriptionProgress)
                    Button("Cancel Local Transcription") { transcriber.cancelTranscription() }
                } else if !note.hasCapturedTranscript {
                    if model.status == .missing {
                        Button("Install Whisper Model") { showingSettings = true }
                    } else {
                        Button("Retry Local Transcription") {
                            player.pause()
                            transcriber.transcriptionLanguage = WhisperLanguage(rawValue: settings.whisperLanguage) ?? .automatic
                            Task { await transcriber.transcribe(noteID: noteID) }
                        }.disabled(store.isReadOnly || whisperState.isTranscribing)
                    }
                }
                if note.hasCapturedTranscript {
                    DisclosureGroup("Original STT transcript (read-only)") {
                        Text(note.rawTranscript.isEmpty ? "(No speech recognized)" : note.rawTranscript)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !note.transcriptSegments.isEmpty {
                    DisclosureGroup("Original timestamps — tap to seek") {
                        if note.editedTranscript != note.rawTranscript {
                            Text("Timestamps refer to the original STT text, not your edits.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(note.transcriptSegments) { segment in
                            HStack(alignment: .top) {
                                Button(segment.startTime.mmSS) { player.seek(to: segment.startTime) }
                                    .font(.caption.monospacedDigit())
                                    .accessibilityLabel("Seek audio to \(segment.startTime.mmSS)")
                                Text(segment.text).textSelection(.enabled)
                                    .foregroundStyle(player.currentTime >= segment.startTime
                                        && player.currentTime < (segment.endTime ?? segment.startTime)
                                        ? Color.accentColor : Color.primary)
                                Spacer(minLength: 0)
                            }.padding(.vertical, 3)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func share(includeAudio: Bool) {
        guard let note = store[noteID] else { return }
        do {
            let (body, file) = try TranscriptSharing.makeItems(for: note)
            temporaryExports.append(file)
            shareItems = [body, file]
            if includeAudio { shareItems.append(note.audioURL) }
            showingShare = true
        } catch { localError = "The transcript could not be exported. The original note is unchanged." }
    }

    private func email(includeAudio: Bool) {
        guard MFMailComposeViewController.canSendMail() else { share(includeAudio: includeAudio); return }
        guard let note = store[noteID] else { return }
        do {
            let (body, file) = try TranscriptSharing.makeItems(for: note)
            temporaryExports.append(file)
            mailInfo = MailInfo(subject: note.displayTitle, body: body,
                                attachments: includeAudio ? [file, note.audioURL] : [file])
        } catch { localError = "The transcript could not be prepared for email." }
    }

    private func clearExports() {
        for file in temporaryExports where file.deletingLastPathComponent().standardizedFileURL
            == FileManager.default.temporaryDirectory.standardizedFileURL {
            try? FileManager.default.removeItem(at: file)
        }
        temporaryExports = []
        shareItems = []
        mailInfo = nil
    }

    private struct MailInfo: Identifiable {
        let id = UUID()
        let subject: String
        let body: String
        let attachments: [URL]
    }
}
