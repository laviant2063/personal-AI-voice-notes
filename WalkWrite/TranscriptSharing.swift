import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Explicit user export. Edited text remains the main content of every export.
enum TranscriptSharing {
    static func makeItems(for note: Note) throws -> (String, URL) {
        let isProvisional = note.editedTranscript.isEmpty && note.liveTranscriptDraft != nil
        let body = isProvisional
            ? "Provisional on-device live transcript\n\n" + note.displayTranscript
            : note.editedTranscript
        var content = body
        if note.editedTranscript == note.rawTranscript && !note.transcriptSegments.isEmpty {
            let lines = note.transcriptSegments.map {
                "[\($0.startTime.mmSS)] \($0.text)"
            }.joined(separator: "\n")
            content += "\n\nOriginal local STT timestamps\n" + lines
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceNote-\(UUID().uuidString)").appendingPathExtension("txt")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return (body, file)
    }
}

#if canImport(UIKit)
// MARK: - ShareSheet wrapper

import SwiftUI

/// SwiftUI wrapper around `UIActivityViewController` so we can present the system share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]?

    init(_ items: [Any], applicationActivities: [UIActivity]? = nil) {
        self.activityItems = items
        self.applicationActivities = applicationActivities
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems,
                                 applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Mail composer wrapper

import MessageUI

/// SwiftUI wrapper around `MFMailComposeViewController`.
struct MailComposer: UIViewControllerRepresentable {
    typealias Callback = (MFMailComposeResult, Error?) -> Void

    let subject: String
    let body: String
    let attachments: [URL]?
    var completion: Callback?

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)

        if let atts = attachments {
            for url in atts {
                if let data = try? Data(contentsOf: url) {
                    let mime = url.pathExtension.lowercased() == "wav" ? "audio/wav" : "text/plain"
                    vc.addAttachmentData(data, mimeType: mime, fileName: url.lastPathComponent)
                }
            }
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        var completion: Callback?

        init(completion: Callback?) { self.completion = completion }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            completion?(result, error)
            controller.dismiss(animated: true)
        }
    }
}
#endif
