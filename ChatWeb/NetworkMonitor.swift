import Foundation
import Network

final class NetworkMonitor {
    var onStatusChange: ((Bool) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.chatweb.network-monitor")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.onStatusChange?(path.status == .satisfied)
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        guard started else { return }
        monitor.cancel()
        started = false
    }

    deinit {
        cancel()
    }
}
