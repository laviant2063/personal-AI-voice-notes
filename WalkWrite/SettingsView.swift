import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AIController.self) private var ai
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = WhisperModelManager.shared
    @StateObject private var whisperState = WhisperStateManager.shared
    @State private var backendAddress = ""
    @State private var newToken = ""
    @State private var errorMessage: String?
    @State private var importingModel = false
    @State private var showAbout = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Online AI") {
                    Toggle("Automatic AI Summary", isOn: $settings.automaticSummary)
                    Toggle("Use Cellular for AI", isOn: $settings.useCellularForAI)
                    LabeledContent("AI Language", value: "Same as Transcript")
                    Text("Automatic summary is OFF by default. When enabled, only a newly transcribed and saved note can be sent. Reconnecting never uploads older notes.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(network.description).font(.footnote)
                    Text("Network status is only a hint; an actual request may still fail.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Personal Backend") {
                    LabeledContent("Backend Status", value: settings.isBackendConfigured ? "Configured locally" : "Not Configured")
                    TextField("HTTPS backend origin", text: $backendAddress)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(settings.hasBackendToken ? "New APP_TOKEN (leave blank to keep)" : "APP_TOKEN", text: $newToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("APP_TOKEN is stored in Keychain. It provides basic endpoint protection, not strong user authentication. OpenAI API keys are managed only on the backend.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Save Backend Settings") { saveBackend() }
                    Button("Check Backend Status") { ai.checkBackendStatus() }
                        .disabled(!settings.isBackendConfigured || ai.isCheckingBackend)
                    if ai.isCheckingBackend { ProgressView() }
                    Text(ai.backendStatusText).font(.footnote)
                    Text("A readiness check sends no transcript and makes no OpenAI request. It does not verify credentials or summary quality.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if settings.isBackendConfigured {
                        Button("Remove Backend Configuration", role: .destructive) {
                            do {
                                ai.cancelAll()
                                try settings.removeBackend()
                                ai.configurationChanged()
                                backendAddress = ""
                                newToken = ""
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                    if let error = settings.configurationError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                Section("Local Speech-to-Text") {
                    LabeledContent("STT Model Status", value: model.statusDescription)
                    LabeledContent("Whisper Runtime", value: WhisperEngine.isAvailable ? "Linked" : "Needs XCFramework build")
                    Picker("Transcription Language", selection: $settings.whisperLanguage) {
                        ForEach(WhisperLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }
                    Button(model.isInstalling ? "Importing…" : "Import Whisper Model (.bin)") { importingModel = true }
                        .disabled(model.isInstalling || whisperState.isTranscribing)
                    if model.isInstalling { ProgressView() }
                    if let file = model.installedModelURL {
                        Text(file.lastPathComponent).font(.caption).textSelection(.enabled)
                    }
                    if model.status == .missing, let message = model.errorMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("First-time model provisioning may require internet. Download a multilingual GGML Whisper model to Files, then import it here. After installation, transcription is offline. LFS pointer files are not models.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Model status checks the file header, not inference quality or memory requirements. Start with a small multilingual model for device testing.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Live text uses Apple Speech only when this device supports on-device recognition for the selected language. It is provisional; unsupported devices continue recording and use local Whisper after Stop.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Privacy") {
                    Text("Transcript text is sent to the configured remote AI backend only when AI processing is requested.")
                    Text("The backend forwards that text to OpenAI. Audio is never uploaded for AI. Your raw transcript is never replaced by AI. Local notes survive AI failures.")
                    Text("Live Speech is forced to on-device processing and has no network fallback. A live draft is never eligible for AI processing until local Whisper saves an edited transcript.")
                    Text("The personal backend does not permanently store notes or transcripts. OpenAI's own data-retention policies still apply.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                Section { Button("About / Open Source") { showAbout = true } }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { newToken = ""; dismiss() } } }
            .onAppear { backendAddress = settings.backendURLString; model.refresh() }
            .onChange(of: settings.useCellularForAI) { _, _ in ai.configurationChanged() }
            .onChange(of: settings.automaticSummary) { _, enabled in if !enabled { ai.cancelAll() } }
            .sheet(isPresented: $showAbout) { InfoSheet() }
            .fileImporter(isPresented: $importingModel, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                do {
                    guard let file = try result.get().first else { return }
                    Task {
                        do { try await model.importModel(from: file); errorMessage = nil }
                        catch { errorMessage = error.localizedDescription }
                    }
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    private func saveBackend() {
        do {
            try settings.saveBackend(urlString: backendAddress, newToken: newToken)
            ai.configurationChanged()
            newToken = ""
            backendAddress = settings.backendURLString
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
