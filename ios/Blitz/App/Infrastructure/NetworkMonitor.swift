import ClaudeKit
import Foundation
import Network
import os

/// Wraps `NWPathMonitor`: publishes online/offline changes and lets the API client wait for
/// the network to return instead of failing a message while the device is between networks.
/// `@unchecked`: all mutable state lives in the lock; `NWPathMonitor` is used from its queue.
final class NetworkMonitor: ConnectivityMonitoring, @unchecked Sendable {
    private struct State: Sendable {
        var isConnected = true
        var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
        var onChange: (@Sendable (Bool) -> Void)?
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.appstack.blitz.network", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: State())

    func start(onChange: @escaping @Sendable (Bool) -> Void) {
        state.withLock { $0.onChange = onChange }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(isConnected: path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    var isConnected: Bool {
        state.withLock { $0.isConnected }
    }

    func waitUntilConnected(timeout: Duration) async -> Bool {
        if isConnected { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let connected = state.withLock { state -> Bool in
                    if state.isConnected { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if connected {
                    continuation.resume(returning: true)
                    return
                }
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.resolve(id, connected: false)
                }
            }
        } onCancel: {
            resolve(id, connected: false)
        }
    }

    private func resolve(_ id: UUID, connected: Bool) {
        let continuation = state.withLock { $0.waiters.removeValue(forKey: id) }
        continuation?.resume(returning: connected)
    }

    private func update(isConnected: Bool) {
        let (waiters, onChange, changed) = state.withLock { state in
            let changed = state.isConnected != isConnected
            state.isConnected = isConnected
            let waiters = isConnected ? Array(state.waiters.values) : []
            if isConnected { state.waiters.removeAll() }
            return (waiters, state.onChange, changed)
        }
        for waiter in waiters { waiter.resume(returning: true) }
        if changed { onChange?(isConnected) }
    }
}
