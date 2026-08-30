import Foundation
import AVFoundation
import Combine

@MainActor
final class AudioPlayer: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?

    override init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pause() }
            }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
                let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    Task { @MainActor in self?.pause() }
                }
            }
    }

    deinit {
        player?.stop()
        timer?.invalidate()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    func load(_ url: URL) {
        stop()
        player = nil
        errorMessage = nil
        duration = 0
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            guard player.prepareToPlay() else { throw PlayerError.unavailable }
            self.player = player
            duration = player.duration
        } catch { errorMessage = "The saved audio could not be opened. Its file has not been changed." }
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { errorMessage = PlayerError.unavailable.localizedDescription; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            if player.currentTime >= player.duration { player.currentTime = 0 }
            guard player.play() else { throw PlayerError.unavailable }
            isPlaying = true
            errorMessage = nil
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.currentTime = self.player?.currentTime ?? 0
                }
            }
        } catch { errorMessage = "Audio playback could not start. Check the current audio route."; releaseSession() }
    }

    func pause() {
        guard isPlaying, let player else { return }
        player.pause()
        currentTime = player.currentTime
        isPlaying = false
        timer?.invalidate()
        releaseSession()
    }

    func stop() {
        let wasPlaying = isPlaying
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        currentTime = 0
        timer?.invalidate()
        if wasPlaying { releaseSession() }
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite, let player else { return }
        player.currentTime = min(max(0, time), duration)
        currentTime = player.currentTime
    }

    private func releaseSession() {
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { errorMessage = "The audio session could not be released normally." }
    }

    private enum PlayerError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Audio playback is unavailable. The original file is preserved." }
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.currentTime = self.duration
            self.isPlaying = false
            self.timer?.invalidate()
            if !flag { self.errorMessage = "Playback ended with an audio error." }
            self.releaseSession()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.stop()
            self?.errorMessage = "The audio file could not be decoded. It has been preserved."
        }
    }
}
