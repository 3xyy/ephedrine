import Foundation
import Network

/// Watches the network path. Two monitors: any interface (outages) and Wi-Fi
/// only (for the Wi-Fi-dependent features). Callbacks arrive on the main queue.
final class NetworkWatch {
    /// Whether the network is usable on any interface; main thread.
    var onChange: ((Bool) -> Void)?
    /// Whether a Wi-Fi path is up; main thread.
    private(set) var wifiSatisfied = false
    /// Whether the network is usable on any interface (Ethernet counts); main thread. True until a path says otherwise.
    private(set) var anySatisfied = true
    private let any = NWPathMonitor()
    private let wifi = NWPathMonitor(requiredInterfaceType: .wifi)

    func start() {
        any.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async { self?.anySatisfied = ok; self?.onChange?(ok) }
        }
        wifi.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async { self?.wifiSatisfied = ok }
        }
        any.start(queue: DispatchQueue(label: "ephedrine.netpath"))
        wifi.start(queue: DispatchQueue(label: "ephedrine.wifipath"))
    }
}
