import Foundation

/// Runs at most once per interval: immediately when idle, otherwise only the latest call when the
/// interval ends, so the final slider value is never lost.
final class Throttle {
    private let interval: Duration
    private var lastRun = ContinuousClock.now - .seconds(60)
    private var pending: (() -> Void)?
    private var timer: Task<Void, Never>?

    init(interval: Duration) {
        self.interval = interval
    }

    func run(_ action: @escaping () -> Void) {
        let now = ContinuousClock.now
        if timer == nil, now - lastRun >= interval {
            lastRun = now
            action()
            return
        }

        pending = action
        guard timer == nil else { return }
        let deadline = lastRun + interval
        timer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            self?.flush()
        }
    }

    private func flush() {
        timer = nil
        guard let action = pending else { return }
        pending = nil
        lastRun = .now
        action()
    }
}
