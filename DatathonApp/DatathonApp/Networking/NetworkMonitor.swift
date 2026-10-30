import Foundation
import Network
import Observation

/// Tracks connectivity and ultra-constrained (satellite) paths.
///
/// The iOS 27.1 SDK exposes `allowUltraConstrainedPaths` on `NWParameters` only; `NWPathMonitor`
/// has no parameters initialiser, so the default monitor is used and `isUltraConstrained` read
/// from its path. Apple's guidance: treat the flag as "very low bandwidth", not proof of satellite.
@Observable
final class NetworkMonitor {
    private(set) var pathSatisfied = true
    private(set) var isUltraConstrained = false
    private(set) var isConstrained = false
    private(set) var isExpensive = false
    private(set) var linkQuality = "unknown"
    private(set) var interfaceName = "—"

    @ObservationIgnored private let monitor: NWPathMonitor
    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        monitor = NWPathMonitor()
        // Updates are delivered on the main queue, matching this type's MainActor isolation.
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let ultra = path.isUltraConstrained
            let constrained = path.isConstrained
            let expensive = path.isExpensive
            let quality: String = switch path.linkQuality {
            case .minimal: "minimal"
            case .moderate: "moderate"
            case .good: "good"
            default: "unknown"
            }
            let iface: String =
                if path.usesInterfaceType(.wifi) { "Wi-Fi" }
                else if path.usesInterfaceType(.cellular) { "Cellular" }
                else if path.usesInterfaceType(.wiredEthernet) { "Ethernet" }
                else if path.usesInterfaceType(.loopback) { "Loopback" }
                else if satisfied { "Other" } else { "None" }
            guard let self else { return }
            self.pathSatisfied = satisfied
            self.isUltraConstrained = ultra
            self.isConstrained = constrained
            self.isExpensive = expensive
            self.linkQuality = quality
            self.interfaceName = iface
        }
        monitor.start(queue: .main)
    }

    /// Online from the app's point of view (honours the developer "simulate offline" toggle).
    var isOnline: Bool { pathSatisfied && !settings.simulateOffline }

    /// Satellite mode: real ultra-constrained path or the developer override.
    var isSatelliteMode: Bool { settings.forceSatellite || isUltraConstrained }
}
