import SwiftUI

/// Circular live-record/stop control shared by the home and recording screens.
struct RecordButton: View {
    var isRecording: Bool
    var diameter: CGFloat = 76
    var action: () -> Void

    private let mint = Color(red: 0.02, green: 0.76, blue: 0.69)

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .foregroundStyle(isRecording ? Color.red : mint)
                    .overlay {
                        Circle().stroke(.white.opacity(0.7), lineWidth: 1)
                    }

                if isRecording {
                    Image(systemName: "stop.fill")
                        .font(.system(size: diameter * 0.34, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: diameter * 0.38, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
        .accessibilityIdentifier(isRecording ? "stopRecordingButton" : "liveRecordButton")
    }
}

#Preview("Idle") {
    RecordButton(isRecording: false) {}
}

#Preview("Recording") {
    RecordButton(isRecording: true) {}
}
