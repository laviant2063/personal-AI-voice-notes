import SwiftUI

struct InfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Personal Voice Notes") {
                    Text("Record, transcribe, edit, search, and listen on this device. Remote AI is optional.")
                    Text("Based on WalkWrite by Louie Bacaj (MIT). Local transcription uses whisper.cpp by the ggml authors (MIT).")
                }
                Section("Verification") {
                    Text("Microphone reliability, long recordings, and Whisper performance must be verified on your iPhone or iPad.")
                }
            }
            .navigationTitle("About")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
