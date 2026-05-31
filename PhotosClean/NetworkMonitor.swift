//
//  NetworkMonitor.swift
//  PhotosClean
//
//  Lightweight reachability used to gate proactive iCloud prefetching to
//  unmetered networks, so background pre-warming never burns cellular data.
//

import Foundation
import Network

final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.photosclean.networkmonitor")

    /// Updated off the main thread by NWPathMonitor; read atomically via a lock.
    private var _path: NWPath?
    private let lock = NSLock()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self._path = path
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    /// Any usable connection (Wi-Fi or cellular). Defaults to false until the
    /// first path update.
    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _path?.status == .satisfied
    }

    /// An unmetered, unconstrained connection (Wi-Fi/Ethernet, not cellular,
    /// hotspot, or Low Data Mode). Used when the user restricts prefetch to Wi-Fi.
    var isUnmetered: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let path = _path else { return false }
        return path.status == .satisfied && !path.isExpensive && !path.isConstrained
    }
}
