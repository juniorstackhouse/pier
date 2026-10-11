import Foundation
import NIOConcurrencyHelpers

/// The first of several ways to do one thing (dial a box directly or through its relay): each starts `stagger` after
/// the one before it, or at once when an earlier one fails, and the first to succeed wins. Results that come after
/// the winner go to `discard` (a connection to close); when all fail, the error is the most telling one (a pinned key
/// that did not match, else the first attempt's).
enum Race {
    static func first<T: Sendable>(
        _ attempts: [@Sendable () async throws -> T],
        stagger: Duration,
        discard: @escaping @Sendable (T) -> Void
    ) async throws -> T {
        precondition(!attempts.isEmpty)
        let state = RaceState<T>(count: attempts.count)
        return try await withCheckedThrowingContinuation { continuation in
            state.start(continuation)
            for (i, attempt) in attempts.enumerated() {
                Task {
                    if i > 0 {
                        let start = ContinuousClock.now
                        while ContinuousClock.now - start < stagger * i, !state.failedUpTo(i), !state.isDone {
                            try? await Task.sleep(for: .milliseconds(40))
                        }
                        if state.isDone { state.skipped(); return }
                    }
                    do {
                        let value = try await attempt()
                        if !state.won(value) { discard(value) }
                    } catch {
                        state.lost(error, index: i)
                    }
                }
            }
        }
    }
}

private final class RaceState<T: Sendable>: @unchecked Sendable {
    private let lock = NIOLock()
    private let count: Int
    private var continuation: CheckedContinuation<T, Error>?
    private var done = false
    private var finished = 0
    private var errors: [(Int, Error)] = []

    init(count: Int) { self.count = count }

    func start(_ c: CheckedContinuation<T, Error>) { lock.withLock { continuation = c } }

    var isDone: Bool { lock.withLock { done } }

    /// Whether every attempt before `index` has failed.
    func failedUpTo(_ index: Int) -> Bool { lock.withLock { errors.filter { $0.0 < index }.count >= index } }

    func won(_ value: T) -> Bool {
        let c: CheckedContinuation<T, Error>? = lock.withLock {
            finished += 1
            guard !done else { return nil }
            done = true
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
        return c != nil
    }

    func lost(_ error: Error, index: Int) {
        let resume: (CheckedContinuation<T, Error>, Error)? = lock.withLock {
            finished += 1
            errors.append((index, error))
            guard !done, finished == count, let c = continuation else { return nil }
            done = true
            continuation = nil
            return (c, Self.telling(errors))
        }
        if let (c, e) = resume { c.resume(throwing: e) }
    }

    func skipped() {
        lock.withLock { finished += 1 }
    }

    private static func telling(_ errors: [(Int, Error)]) -> Error {
        let ordered = errors.sorted { $0.0 < $1.0 }.map(\.1)
        if let pin = ordered.first(where: { if case PierError.pinMismatch = $0 { return true } else { return false } }) { return pin }
        return ordered[0]
    }
}
