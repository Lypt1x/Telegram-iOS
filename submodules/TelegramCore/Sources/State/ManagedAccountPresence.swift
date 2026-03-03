import Foundation
import TelegramApi
import Postbox
import SwiftSignalKit
import MtProtoKit

private typealias SignalKitTimer = SwiftSignalKit.Timer

// MARK: - Ghost Mode helper (reads UserDefaults directly to avoid cross-module deps)
private func isGhostModeHideOnlineStatus() -> Bool {
    let defaults = UserDefaults.standard
    guard defaults.bool(forKey: "sg_ghostModeEnabled") else { return false }
    if defaults.object(forKey: "sg_ghostModeHideOnlineStatus") == nil { return true }
    return defaults.bool(forKey: "sg_ghostModeHideOnlineStatus")
}

private final class AccountPresenceManagerImpl {
    private let queue: Queue
    private let network: Network
    let isPerformingUpdate = ValuePromise<Bool>(false, ignoreRepeated: true)
    
    private var shouldKeepOnlinePresenceDisposable: Disposable?
    private let currentRequestDisposable = MetaDisposable()
    private var onlineTimer: SignalKitTimer?
    
    private var wasOnline: Bool = false
    private var ghostModeObserver: NSObjectProtocol?
    
    init(queue: Queue, shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network) {
        self.queue = queue
        self.network = network
        
        self.shouldKeepOnlinePresenceDisposable = (shouldKeepOnlinePresence
        |> distinctUntilChanged
        |> deliverOn(self.queue)).start(next: { [weak self] value in
            guard let self = self else {
                return
            }
            if self.wasOnline != value {
                self.wasOnline = value
                self.updatePresence(value)
            }
        })
        
        // Observe ghost mode toggle from settings UI for instant response.
        // Matches AyuGram Desktop's markAsOnline() pattern (ayu_settings.cpp:376).
        self.ghostModeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("SGGhostModeStateChanged"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            self.queue.async {
                let ghostMode = isGhostModeHideOnlineStatus()
                if ghostMode && self.wasOnline {
                    // Ghost mode just enabled: transition to offline and start
                    // the periodic offline heartbeat via updatePresence.
                    self.updatePresence(true)
                } else if !ghostMode && self.wasOnline {
                    // Ghost mode just disabled: resume normal online presence
                    self.updatePresence(true)
                }
            }
        }
    }
    
    deinit {
        assert(self.queue.isCurrent())
        self.shouldKeepOnlinePresenceDisposable?.dispose()
        self.currentRequestDisposable.dispose()
        self.onlineTimer?.invalidate()
        if let observer = self.ghostModeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func sendStatus(offline: Bool) {
        // Fail closed: never allow online status writes while ghost mode is active.
        if !offline && isGhostModeHideOnlineStatus() {
            return
        }
        let request = self.network.request(Api.functions.account.updateStatus(
            offline: offline ? .boolTrue : .boolFalse
        ))
        self.isPerformingUpdate.set(true)
        self.currentRequestDisposable.set((request
        |> `catch` { _ -> Signal<Api.Bool, NoError> in
            return .single(.boolFalse)
        }
        |> deliverOn(self.queue)).start(completed: { [weak self] in
            self?.isPerformingUpdate.set(false)
        }))
    }
    
    private func updatePresence(_ isOnline: Bool) {
        self.onlineTimer?.invalidate()
        self.onlineTimer = nil
        
        if isGhostModeHideOnlineStatus() {
            // Ghost mode: NEVER send online, proactively enforce offline.
            // The server infers presence from API activity (fetching dialogs,
            // reading messages, etc.) — AyuGram Desktop counters this with a
            // periodic offline heartbeat (ayu_worker.cpp:workerTimer 3s cycle).
            // We match the same 3s interval for aggressive offline enforcement.
            self.sendStatus(offline: true)
            if isOnline {
                // App is in foreground: start periodic offline heartbeat to
                // counteract any server-side presence inference from API calls.
                let timer = SignalKitTimer(timeout: 3.0, repeat: false, completion: { [weak self] in
                    guard let self = self else { return }
                    self.updatePresence(true)
                }, queue: self.queue)
                self.onlineTimer = timer
                timer.start()
            }
            return
        }
        
        // Normal mode (ghost mode OFF)
        if isOnline {
            let timer = SignalKitTimer(timeout: 30.0, repeat: false, completion: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.updatePresence(true)
            }, queue: self.queue)
            self.onlineTimer = timer
            timer.start()
            self.sendStatus(offline: false)
        } else {
            self.sendStatus(offline: true)
        }
    }
}

final class AccountPresenceManager {
    private let queue = Queue()
    private let impl: QueueLocalObject<AccountPresenceManagerImpl>
    
    init(shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network) {
        let queue = self.queue
        self.impl = QueueLocalObject(queue: self.queue, generate: {
            return AccountPresenceManagerImpl(queue: queue, shouldKeepOnlinePresence: shouldKeepOnlinePresence, network: network)
        })
    }
    
    func isPerformingUpdate() -> Signal<Bool, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.isPerformingUpdate.get().start(next: { value in
                    subscriber.putNext(value)
                }))
            }
            return disposable
        }
    }
}
