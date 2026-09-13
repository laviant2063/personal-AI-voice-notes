import SwiftUI

@MainActor
struct RecorderSheet: View {
    @Environment(NoteStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = RecorderViewModel()
    @State private var showStopConfirmation = false
    @State private var isRequestingPermission = true
    @State private var requestedInitialRecording = false

    private let recordingRed = Color(red: 0.93, green: 0.18, blue: 0.27)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                transcriptArea
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom) { bottomControls }
            .toolbar(.hidden, for: .navigationBar)
            .interactiveDismissDisabled(isRequestingPermission || vm.isRecording || vm.isProcessing || vm.isPreparingModel)
            .task {
                guard !requestedInitialRecording else { return }
                requestedInitialRecording = true
                vm.attachStore(store)
                let language = WhisperLanguage(rawValue: settings.whisperLanguage) ?? .automatic
                vm.transcriptionLanguage = language
                let allowed = await vm.ensurePermission()
                guard !Task.isCancelled else { return }
                isRequestingPermission = false
                if allowed { vm.startRecording() }
            }
            .onChange(of: vm.finishedNote) { _, note in
                if note != nil && vm.errorMessage == nil { dismiss() }
            }
            .onDisappear { vm.cancelTranscription() }
            .confirmationDialog("녹음을 중지하고 저장할까요?", isPresented: $showStopConfirmation,
                                titleVisibility: .visible) {
                Button("중지하고 저장", role: .destructive) { vm.stopRecording() }
                Button("계속 녹음", role: .cancel) {}
            } message: {
                Text("지금까지 녹음된 오디오와 받아쓰기 내용을 보존합니다.")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: requestClose) {
                Image(systemName: "chevron.left")
                    .font(.title2.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isRequestingPermission || vm.isProcessing || vm.isPreparingModel)
            .accessibilityLabel("녹음 화면 닫기")

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Text("음성 인식")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityAddTraits(.isSelected)
                Text("요약")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("요약은 녹음 저장 후 노트에서 확인")
                Text("노트")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("노트는 녹음 저장 후 확인")
            }
            .font(.headline)

            Spacer(minLength: 4)
            Color.clear.frame(width: 48, height: 48)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if liveText.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: vm.isPaused ? "pause.circle" : "waveform")
                                .font(.system(size: 34, weight: .light))
                                .foregroundStyle(vm.isPaused ? Color.secondary : recordingRed)
                            Text(emptyTranscriptText)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 72)
                        .accessibilityIdentifier("liveTranscriptPlaceholder")
                    } else {
                        Text(liveText)
                            .font(.system(size: 24, weight: .regular, design: .rounded))
                            .lineSpacing(8)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("liveTranscript")
                    }

                    if vm.isRecording {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(vm.isPaused ? Color.secondary : recordingRed)
                                .frame(width: 10, height: 10)
                            AudioLevelIndicatorView(audioLevel: vm.audioLevel,
                                                    baseWaveColor: recordingRed,
                                                    waveMaxHeight: 32,
                                                    baseLineWidth: 2,
                                                    density: 60)
                                .frame(maxWidth: 180)
                            Spacer()
                            Text(vm.elapsed.mmSS)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .accessibilityIdentifier("recordingElapsedTime")
                        }
                    }

                    if let message = vm.liveSpeechMessage, !message.isEmpty {
                        Label(message, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("liveSpeechStatus")
                    }

                    if let error = vm.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("recordingError")
                    }

                    if vm.isProcessing || vm.isPreparingModel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(stateText).font(.headline)
                            ProgressView(value: vm.transcriptionProgress)
                            Text("오디오는 이미 기기에 저장되었습니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("localTranscriptionProgress")
                    } else if vm.finishedNote != nil {
                        Label("오디오가 기기에 저장되었습니다.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    Color.clear.frame(height: 1).id("transcriptEnd")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .onChange(of: vm.liveTranscript) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("transcriptEnd", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var bottomControls: some View {
        VStack(spacing: 12) {
            if vm.isRecording {
                HStack(spacing: 16) {
                    languageMenu
                    Spacer(minLength: 8)
                    Button {
                        vm.isPaused ? vm.resumeRecording() : vm.pauseRecording()
                    } label: {
                        Image(systemName: vm.isPaused ? "play.fill" : "pause.fill")
                            .font(.title2.weight(.semibold))
                            .frame(width: 62, height: 62)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(vm.isPaused ? "녹음 다시 시작" : "녹음 일시 정지")
                    .accessibilityIdentifier("pauseResumeRecordingButton")

                    RecordButton(isRecording: true, diameter: 72) { vm.stopRecording() }
                        .accessibilityLabel("녹음 중지 및 저장")
                }
            } else if vm.isProcessing || vm.isPreparingModel {
                Button("음성 인식 취소 · 오디오는 보존", role: .cancel) { vm.cancelTranscription() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("cancelTranscriptionButton")
            } else if vm.finishedNote != nil {
                Button("저장된 노트 보기") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("closeSavedRecordingButton")
            } else if !vm.permissionDenied && !isRequestingPermission {
                RecordButton(isRecording: false) { vm.startRecording() }
                    .accessibilityLabel("실시간 음성 인식 노트 시작")
            }

            Text("오디오는 기기에 저장되고, 최종 원문은 설치된 Whisper 모델로 오프라인 변환됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private var languageMenu: some View {
        Menu {
            ForEach(WhisperLanguage.allCases) { language in
                Button {
                    settings.whisperLanguage = language.rawValue
                    vm.changeTranscriptionLanguage(language)
                } label: {
                    if vm.transcriptionLanguage == language {
                        Label(languageName(language), systemImage: "checkmark")
                    } else {
                        Text(languageName(language))
                    }
                }
            }
        } label: {
            Label(languageName(vm.transcriptionLanguage), systemImage: "slider.horizontal.3")
                .font(.headline)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("음성 인식 언어: \(languageName(vm.transcriptionLanguage))")
        .accessibilityIdentifier("transcriptionLanguageMenu")
    }

    private var liveText: String {
        vm.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var emptyTranscriptText: String {
        if isRequestingPermission { return "마이크 권한을 확인하고 있습니다…" }
        if vm.permissionDenied { return "마이크 접근이 필요합니다. iOS 설정에서 권한을 허용해 주세요." }
        if vm.isPaused { return "녹음이 일시 정지되었습니다" }
        if vm.isRecording { return "말씀해 주세요\n실시간 받아쓰기가 여기에 표시됩니다" }
        if vm.isPreparingModel || vm.isProcessing { return "저장된 오디오를 오프라인으로 변환하고 있습니다" }
        if vm.finishedNote != nil { return "녹음이 저장되었습니다" }
        return "녹음을 준비하고 있습니다…"
    }

    private var stateText: String {
        if vm.isPreparingModel { return "로컬 Whisper 불러오는 중…" }
        if vm.isProcessing { return "오프라인 음성 인식 중…" }
        return "녹음 처리 중…"
    }

    private func requestClose() {
        if vm.isRecording {
            showStopConfirmation = true
        } else {
            dismiss()
        }
    }

    private func languageName(_ language: WhisperLanguage) -> String {
        language == .automatic ? "기기 언어 · Whisper 자동" : language.displayName
    }
}
