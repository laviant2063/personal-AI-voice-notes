import SwiftUI

@MainActor
struct RecorderSheet: View {
    @Environment(NoteStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = RecorderViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Text(stateText).font(.title2).multilineTextAlignment(.center)
                Text(vm.elapsed.mmSS).font(.system(size: 48, weight: .medium, design: .rounded)).monospacedDigit()
                AudioLevelIndicatorView(audioLevel: vm.audioLevel)
                if let error = vm.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                if vm.isRecording {
                    HStack(spacing: 40) {
                        Button {
                            vm.isPaused ? vm.resumeRecording() : vm.pauseRecording()
                        } label: {
                            Label(vm.isPaused ? "Resume" : "Pause", systemImage: vm.isPaused ? "play.fill" : "pause.fill")
                        }.buttonStyle(.bordered)
                        RecordButton(isRecording: true) { vm.stopRecording() }
                            .accessibilityLabel("Stop and save recording")
                    }
                } else if vm.isProcessing || vm.isPreparingModel {
                    ProgressView(value: vm.transcriptionProgress)
                    Button("Cancel Transcription — Keep Audio") { vm.cancelTranscription() }
                        .buttonStyle(.bordered)
                } else if vm.finishedNote != nil {
                    Button("Close — Audio Saved") { dismiss() }.buttonStyle(.borderedProminent)
                } else if !vm.permissionDenied {
                    RecordButton(isRecording: false) {
                        Task { if await vm.ensurePermission() { vm.startRecording() } }
                    }.accessibilityLabel("Start recording")
                }
                Text("Audio is saved on this device. An installed Whisper model is required for offline transcription.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
            .padding()
            .navigationTitle("Record")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(vm.isRecording || vm.isProcessing || vm.isPreparingModel)
                }
            }
            .interactiveDismissDisabled(vm.isRecording || vm.isProcessing || vm.isPreparingModel)
            .task {
                vm.attachStore(store)
                vm.transcriptionLanguage = WhisperLanguage(rawValue: settings.whisperLanguage) ?? .automatic
                if await vm.ensurePermission() { vm.startRecording() }
            }
            .onChange(of: vm.finishedNote) { _, note in
                if note != nil && vm.errorMessage == nil { dismiss() }
            }
            .onDisappear { vm.cancelTranscription() }
        }
    }

    private var stateText: String {
        if vm.permissionDenied { return "Microphone access denied. Enable it in iOS Settings." }
        if vm.isPaused { return "Paused" }
        if vm.isRecording { return "Recording" }
        if vm.isPreparingModel { return "Loading local Whisper…" }
        if vm.isProcessing { return "Transcribing locally…" }
        if vm.finishedNote != nil { return "Audio Saved" }
        return "Ready"
    }
}
