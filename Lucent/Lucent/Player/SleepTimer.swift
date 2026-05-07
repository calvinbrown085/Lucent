import Foundation
import Observation

/// Countdown that runs for `originalMinutes`, raises a 30-second warning before
/// expiry, and invokes `onExpire` if the warning isn't dismissed in time.
///
/// Drives both the "Sleep · 23m" chip in NowPlayingView and the "Still
/// watching?" warning overlay. Single internal `Task` ticks every second while
/// active; `cancel()` and `dismissWarning()` both abort the current task before
/// starting a new one (or none).
@Observable
@MainActor
final class SleepTimer {
    /// Length of the warning phase (seconds before expiry that the warning
    /// overlay appears). 30s mirrors Apple TV / Netflix.
    static let warningSeconds: Int = 30

    private(set) var isActive = false
    private(set) var secondsRemaining: Int = 0
    private(set) var isWarning = false
    private(set) var originalMinutes: Int?

    /// Called on the main actor when the countdown reaches zero. Set by AppModel
    /// to tear down the player and signal NowPlayingView to dismiss.
    var onExpire: (@MainActor () -> Void)?

    private var task: Task<Void, Never>?

    func start(minutes: Int) {
        guard minutes > 0 else { return }
        cancelTask()
        originalMinutes = minutes
        secondsRemaining = minutes * 60
        isWarning = false
        isActive = true
        startTickLoop()
    }

    /// Stop the countdown without firing `onExpire`. Used by the Sleep chip
    /// menu's "Cancel timer" action.
    func cancel() {
        cancelTask()
        resetState()
    }

    /// User pressed a button during the warning phase — re-arm to the original
    /// duration. Mirrors "Still watching? — Yes."
    func dismissWarning() {
        guard isWarning, let mins = originalMinutes else { return }
        cancelTask()
        secondsRemaining = mins * 60
        isWarning = false
        isActive = true
        startTickLoop()
    }

    private func startTickLoop() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard let self else { return }
                self.tick()
                if !self.isActive { return }
            }
        }
    }

    private func tick() {
        guard isActive else { return }
        secondsRemaining -= 1
        if secondsRemaining <= Self.warningSeconds, !isWarning {
            isWarning = true
        }
        if secondsRemaining <= 0 {
            let expire = onExpire
            resetState()
            expire?()
        }
    }

    private func cancelTask() {
        task?.cancel()
        task = nil
    }

    private func resetState() {
        isActive = false
        isWarning = false
        secondsRemaining = 0
        originalMinutes = nil
    }
}
