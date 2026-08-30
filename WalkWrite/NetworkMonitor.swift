import Foundation
import Network
import Observation

enum NetworkState: Equatable {
    case unknown, offline, wifi, cellular, other
}

@MainActor
@Observable
final class NetworkMonitor {
    private(set) var state: NetworkState
    private(set) var isExpensive = false
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "VoiceNotes.Network")

    init(initialState: NetworkState = .unknown, startMonitoring: Bool = true) {
        state = initialState
        guard startMonitoring else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let state: NetworkState
            if path.status != .satisfied { state = .offline }
            else if path.usesInterfaceType(.cellular) { state = .cellular }
            else if path.usesInterfaceType(.wifi) { state = .wifi }
            else { state = .other }
            let expensive = path.isExpensive
            Task { @MainActor [weak self] in
                self?.state = state
                self?.isExpensive = expensive
                // Deliberately no upload, retry, or queue-draining callback.
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    var isAvailable: Bool { state == .wifi || state == .cellular || state == .other }
    var needsCellularPermission: Bool { state == .cellular || isExpensive }

    var description: String {
        switch state {
        case .unknown: return "Network status not yet known"
        case .offline: return "Offline — recording and installed local STT still work"
        case .wifi: return isExpensive ? "Metered Wi-Fi" : "Wi-Fi available"
        case .cellular: return "Cellular connection"
        case .other: return "Network available"
        }
    }
}
