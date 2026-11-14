import Foundation
import Network

/// Publishes network changes (offline, Wi-Fi to mobile data, Low Data Mode).
@MainActor
final class Connectivity: ObservableObject {
    static let shared = Connectivity()
    @Published private(set) var state = NetworkState()
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let interface = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet]
                .first(where: path.usesInterfaceType).map { "\($0)" } ?? ""
            let next = NetworkState(online: path.status == .satisfied, expensive: path.isExpensive,
                                    constrained: path.isConstrained, interface: interface)
            Task { @MainActor in
                if self?.state != next { self?.state = next }
            }
        }
        monitor.start(queue: DispatchQueue(label: "net.miniply.connectivity"))
    }
}
