import SwiftUI

@MainActor
struct TranscriptEditor: View {
    @Environment(NoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private let noteID: UUID
    private let canAdoptProvisionalDraft: Bool
    @State private var draft: String
    @State private var originalText: String
    @State private var originalRevision: Int
    @State private var errorMessage: String?
    @State private var confirmDiscard = false

    init(note: Note) {
        noteID = note.id
        canAdoptProvisionalDraft = note.liveTranscriptDraft != nil && note.editedTranscript.isEmpty
        _draft = State(initialValue: note.displayTranscript)
        _originalText = State(initialValue: note.displayTranscript)
        _originalRevision = State(initialValue: note.transcriptRevision)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Edits change only your edited transcript. The original STT text remains unchanged.")
                    .font(.footnote).foregroundStyle(.secondary)
                if canAdoptProvisionalDraft {
                    Text("Save to adopt this provisional live transcript as your edited transcript.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                TextEditor(text: $draft).accessibilityLabel("Edited transcript")
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .padding()
            .navigationTitle("Edit Transcript")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if draft == originalText { dismiss() } else { confirmDiscard = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled((draft == originalText && !canAdoptProvisionalDraft) || store.isReadOnly)
                }
            }
            .interactiveDismissDisabled(draft != originalText)
            .confirmationDialog("Discard unsaved edits?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Edits", role: .destructive) { dismiss() }
            }
        }
    }

    private func save() {
        guard let current = store[noteID] else { errorMessage = "The note no longer exists."; return }
        guard current.transcriptRevision == originalRevision else {
            errorMessage = "A newer transcript revision was saved elsewhere. Keep a copy of this draft, then reopen the editor."
            return
        }
        do {
            try store.editTranscript(id: noteID, text: draft)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
