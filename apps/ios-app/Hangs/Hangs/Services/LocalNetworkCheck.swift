//
//  LocalNetworkCheck.swift
//  Hangs
//
//  #212: "games on this Wi-Fi" are offered only off mobile data, where many
//  strangers share one public address.
//

import Network

enum LocalNetworkCheck {
    /// True on Wi-Fi or a wired network, false on mobile data or offline.
    static func isOffCellular() async -> Bool {
        let monitor = NWPathMonitor()
        let path = await withCheckedContinuation { (continuation: CheckedContinuation<NWPath, Never>) in
            monitor.pathUpdateHandler = { path in
                monitor.pathUpdateHandler = nil
                continuation.resume(returning: path)
            }
            monitor.start(queue: DispatchQueue(label: "trubbo.local-network-check"))
        }
        monitor.cancel()
        return path.status == .satisfied && !path.usesInterfaceType(.cellular)
    }
}
