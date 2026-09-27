import Foundation

/// Detects an **idle/unstarted** rate-limit window and decides when it is
/// safe to send one anchor message to start it early — so a fresh 5-hour (or
/// monthly) window doesn't sit wasted while the user is away.
///
/// Detection principle — TWO independent signal shapes, validated against
/// real Anthropic/OpenAI responses:
///
/// 1. **Explicit-nil signal (Claude, confirmed empirically):** a genuinely
///    fresh, never-yet-used window reports `resets_at: null` (and 0%
///    utilization) — there's no scheduled reset time to report because
///    nothing has started the clock. This is a direct, unambiguous signal:
///    no pattern-matching needed, just requires it to persist across a few
///    polls so a single flaky/transient response can't trigger a false
///    start.
/// 2. **Sliding-timestamp signal (seen on Codex's Go-plan window):** the API
///    always reports *some* absolute `resetAt`, and for an unstarted window
///    that value keeps sliding forward in lockstep with wall-clock time
///    (effectively "now + full duration" on every poll). Once real usage
///    starts, `resetAt` becomes a fixed point in time. This needs comparing
///    consecutive samples since there's no explicit "unstarted" marker.
///
/// A single provider might use either shape (or, conceivably, switch between
/// them), so both paths are evaluated independently based on what the
/// current sample looks like.
///
/// Safety model (deliberately conservative — this spends real quota):
/// - Requires several samples spanning real elapsed time before concluding
///   "idle", tolerating polling jitter and API rounding.
/// - At most one attempt per cooldown window, and a hard daily cap.
/// - After sending, the *next* observation must show the idle signal clear
///   to count as confirmed; if it doesn't, that's treated as a failed
///   anchor. Two failed anchors in a row trips a circuit breaker that blocks
///   further attempts until the user manually re-enables the feature.
public final class SessionAutoStarter {
    private let store: any AutoStartStateStoring
    private let config: AutoStartConfig

    public init(store: any AutoStartStateStoring, config: AutoStartConfig = AutoStartConfig()) {
        self.store = store
        self.config = config
    }

    /// - Parameter highConfidence: pass `true` only when this evaluation was
    ///   deliberately scheduled for right after a *known* reset boundary
    ///   (see `knownResetAt` tracking below) rather than an arbitrary poll.
    ///   In that case a single "explicitly unstarted" observation is trusted
    ///   immediately instead of waiting for `minSamples`/`minSpan` — we're
    ///   not guessing whether this is idle, we scheduled the check exactly
    ///   because we expected it to be. Cooldown, daily cap, and the circuit
    ///   breaker still apply unchanged.
    @discardableResult
    public func evaluate(provider: ProviderID, snapshot: UsageSnapshot, now: Date, highConfidence: Bool = false) -> AutoStartDecision {
        var state = store.state(for: provider)
        defer { store.setState(state, for: provider) }

        guard let window = snapshot.primary else {
            return .skip(reason: .noPrimaryWindow)
        }

        resolvePendingConfirmation(&state, window: window, now: now)

        if state.circuitBroken {
            // `circuitBrokenAt == nil` only happens for state persisted by
            // v0.2.0, whose breaker counted *failed CLI launches* (network
            // down, the message never left the Mac) as failed anchors — so
            // those trips are not trustworthy evidence; clear them.
            // Otherwise the breaker re-arms itself after a cooling-off period
            // instead of staying off until the user happens to notice.
            let trippedAt = state.circuitBrokenAt
            if trippedAt == nil || now.timeIntervalSince(trippedAt!) >= config.circuitBreakerAutoReset {
                Self.clearBreaker(&state)
            } else {
                return .skip(reason: .circuitBroken)
            }
        }

        // A known reset boundary that has already passed makes a fresh-looking
        // window a certainty rather than a hunch: the old window is over, and
        // nothing has started the new one. That's the situation after the Mac
        // slept through a reset and wakes only briefly (Power Nap/DarkWake
        // roughly once an hour) — too rarely to collect several samples in a
        // row, and the scheduled post-reset timer doesn't fire during sleep.
        // Remembering the boundary on disk lets the *first* observation act.
        let boundaryPassed = state.lastKnownResetAt.map { $0 <= now } ?? false

        let idleReason: AutoStartDecision.SkipReason?
        switch classify(window) {
        case .explicitlyUnstarted:
            state.samples = []
            if highConfidence || boundaryPassed {
                state.nilResetStreakStart = nil
                state.nilResetObservationCount = 0
                idleReason = nil
            } else {
                idleReason = recordNilResetObservation(&state, now: now)
            }
        case .active(let resetAt):
            state.nilResetStreakStart = nil
            state.nilResetObservationCount = 0
            let freshSliding = isFreshSlidingWindow(window, resetAt: resetAt, now: now)
            if freshSliding, boundaryPassed || highConfidence {
                // Sliding-shape providers (Codex) report "now + full length"
                // for an unused window; right after a known boundary that is
                // just as conclusive as Claude's explicit null.
                state.samples = []
                idleReason = nil
            } else {
                if !freshSliding {
                    // A fixed, genuinely running window: remember when it
                    // ends. (A sliding value is never stored — it would keep
                    // moving the boundary into the future.)
                    state.lastKnownResetAt = resetAt
                }
                idleReason = recordSlidingSample(&state, resetAt: resetAt, now: now)
            }
        case .ambiguous:
            // resetAt is nil but utilization isn't ~0 — an unexpected shape
            // (e.g. a transient partial response). Don't guess; just don't
            // let it silently carry over stale tracking from either path.
            state.samples = []
            state.nilResetStreakStart = nil
            state.nilResetObservationCount = 0
            return .skip(reason: .windowAlreadyTicking)
        }

        if let idleReason {
            return .skip(reason: idleReason)
        }

        // Checked after sampling so detection keeps accumulating evidence
        // during the backoff and can retry the moment it ends.
        if let retryAt = state.retryNotBefore, now < retryAt {
            return .skip(reason: .launchBackoff)
        }

        if let last = state.lastAttemptAt, now.timeIntervalSince(last) < config.minIntervalBetweenAttempts {
            return .skip(reason: .cooldown)
        }

        state.attemptsInLast24h = state.attemptsInLast24h.filter { now.timeIntervalSince($0) < 24 * 60 * 60 }
        guard state.attemptsInLast24h.count < config.maxAttemptsPerDay else {
            return .skip(reason: .dailyCapReached)
        }

        return .start
    }

    /// Call right before launching the anchor message. Follow it with either
    /// `recordLaunchSucceeded` or `recordLaunchFailed` once the CLI returns.
    public func recordAttempt(provider: ProviderID, now: Date) {
        var state = store.state(for: provider)
        state.lastAttemptAt = now
        state.attemptsInLast24h.append(now)
        state.pendingConfirmationSince = now
        store.setState(state, for: provider)
    }

    /// The CLI accepted the message; whether it actually started the window
    /// is judged by the next polls (see `resolvePendingConfirmation`).
    public func recordLaunchSucceeded(provider: ProviderID) {
        var state = store.state(for: provider)
        state.consecutiveLaunchFailures = 0
        state.retryNotBefore = nil
        store.setState(state, for: provider)
    }

    /// The CLI failed before the message could count (no network, CLI not
    /// found, non-zero exit, timeout). That says nothing about whether
    /// anchoring *works*, so it must not feed the circuit breaker, burn the
    /// multi-hour cooldown, or count toward the daily cap — the attempt is
    /// rolled back and retried soon with exponential backoff instead.
    public func recordLaunchFailed(provider: ProviderID, now: Date) {
        var state = store.state(for: provider)
        if let last = state.attemptsInLast24h.last, last == state.lastAttemptAt {
            state.attemptsInLast24h.removeLast()
        }
        state.lastAttemptAt = state.attemptsInLast24h.last
        state.pendingConfirmationSince = nil
        state.consecutiveLaunchFailures += 1
        let exponent = min(state.consecutiveLaunchFailures - 1, 10)
        let delay = min(config.launchRetryMaxDelay, config.launchRetryBaseDelay * pow(2, Double(exponent)))
        state.retryNotBefore = now.addingTimeInterval(delay)
        store.setState(state, for: provider)
    }

    /// Clears history and the circuit breaker. Called when the user toggles
    /// the feature off (so re-enabling later starts clean) or explicitly
    /// resets it from the menu.
    public func resetCircuitBreaker(provider: ProviderID) {
        var state = store.state(for: provider)
        Self.clearBreaker(&state)
        state.consecutiveLaunchFailures = 0
        state.retryNotBefore = nil
        store.setState(state, for: provider)
    }

    private static func clearBreaker(_ state: inout AutoStartState) {
        state.circuitBroken = false
        state.circuitBrokenAt = nil
        state.consecutiveUnconfirmed = 0
        state.samples = []
        state.nilResetStreakStart = nil
        state.nilResetObservationCount = 0
        state.pendingConfirmationSince = nil
    }

    public func currentState(provider: ProviderID) -> AutoStartState {
        store.state(for: provider)
    }

    // MARK: - Signal classification

    private enum WindowSignal {
        case explicitlyUnstarted
        case active(resetAt: Date)
        case ambiguous
    }

    /// An unused window from a provider that reports "now + full length"
    /// instead of null (Codex): nothing consumed, and the reported reset sits
    /// a full window-length from now.
    private func isFreshSlidingWindow(_ window: UsageWindow, resetAt: Date, now: Date) -> Bool {
        guard window.remainingPercent >= 100, let duration = window.windowDuration else { return false }
        return abs(resetAt.timeIntervalSince(now) - duration) <= config.pinTolerance * 2
    }

    private func classify(_ window: UsageWindow) -> WindowSignal {
        if let resetAt = window.resetAt {
            return .active(resetAt: resetAt)
        }
        return window.remainingPercent >= 100 ? .explicitlyUnstarted : .ambiguous
    }

    // MARK: - Path 1: explicit-nil signal

    /// Returns nil once the idle state has persisted long enough to act on,
    /// otherwise the specific reason it's not (yet) actionable.
    private func recordNilResetObservation(_ state: inout AutoStartState, now: Date) -> AutoStartDecision.SkipReason? {
        if state.nilResetStreakStart == nil {
            state.nilResetStreakStart = now
            state.nilResetObservationCount = 1
            return .insufficientSamples
        }
        state.nilResetObservationCount += 1
        guard state.nilResetObservationCount >= config.minSamples else {
            return .insufficientSamples
        }
        let span = now.timeIntervalSince(state.nilResetStreakStart!)
        guard span >= config.minSpan else {
            return .insufficientSpan
        }
        return nil
    }

    // MARK: - Path 2: sliding-timestamp signal

    /// Returns nil once the pinned pattern has persisted long enough to act
    /// on, otherwise the specific reason it's not (yet) actionable.
    private func recordSlidingSample(_ state: inout AutoStartState, resetAt: Date, now: Date) -> AutoStartDecision.SkipReason? {
        // A gap between consecutive samples much larger than the normal
        // polling cadence (Mac slept, app was relaunched, a long network
        // outage) means continuity can't be trusted: the window may have
        // reset naturally somewhere in that gap. Comparing across it would
        // either wrongly poison a genuinely fresh reading with stale pre-gap
        // data, or vice versa — so start the detection clock over instead of
        // pattern-matching across it.
        if let last = state.samples.last, now.timeIntervalSince(last.fetchedAt) > config.maxTrustedGap {
            state.samples = []
        }

        state.samples.append(Sample(fetchedAt: now, resetAt: resetAt))
        if state.samples.count > config.sampleHistoryLimit {
            state.samples.removeFirst(state.samples.count - config.sampleHistoryLimit)
        }

        guard state.samples.count >= config.minSamples else {
            return .insufficientSamples
        }
        let span = state.samples.last!.fetchedAt.timeIntervalSince(state.samples.first!.fetchedAt)
        guard span >= config.minSpan else {
            return .insufficientSpan
        }
        return isPinned(state.samples) ? nil : .windowAlreadyTicking
    }

    private func isPinned(_ samples: [Sample]) -> Bool {
        zip(samples, samples.dropFirst()).allSatisfy { a, b in
            let fetchedDelta = b.fetchedAt.timeIntervalSince(a.fetchedAt)
            let resetDelta = b.resetAt.timeIntervalSince(a.resetAt)
            return abs(resetDelta - fetchedDelta) <= config.pinTolerance
        }
    }

    // MARK: - Confirmation of a prior attempt

    private func resolvePendingConfirmation(_ state: inout AutoStartState, window: UsageWindow, now: Date) {
        guard let pendingSince = state.pendingConfirmationSince else { return }

        let stillIdle: Bool
        switch classify(window) {
        case .explicitlyUnstarted:
            stillIdle = true
        case .ambiguous:
            stillIdle = true // don't count an ambiguous read as confirmation either way yet
        case .active(let resetAt):
            if let lastSample = state.samples.last {
                let fetchedDelta = now.timeIntervalSince(lastSample.fetchedAt)
                let resetDelta = resetAt.timeIntervalSince(lastSample.resetAt)
                stillIdle = abs(resetDelta - fetchedDelta) <= config.pinTolerance
            } else {
                // We were tracking via the nil-reset path and it just
                // produced a real resetAt — that's the window starting.
                stillIdle = false
            }
        }

        if !stillIdle {
            state.consecutiveUnconfirmed = 0
            state.pendingConfirmationSince = nil
            state.samples = []
            state.nilResetStreakStart = nil
            state.nilResetObservationCount = 0
            return
        }

        guard now.timeIntervalSince(pendingSince) > config.confirmationGracePeriod else { return }
        // Still idle well after we sent the anchor: treat as a failed
        // attempt rather than waiting forever.
        state.consecutiveUnconfirmed += 1
        state.pendingConfirmationSince = nil
        if state.consecutiveUnconfirmed >= config.maxUnconfirmedBeforeCircuitBreak {
            state.circuitBroken = true
            state.circuitBrokenAt = now
        }
    }
}

public struct AutoStartConfig: Sendable {
    public var minSamples: Int
    public var minSpan: TimeInterval
    public var pinTolerance: TimeInterval
    public var maxTrustedGap: TimeInterval
    public var minIntervalBetweenAttempts: TimeInterval
    public var maxAttemptsPerDay: Int
    public var confirmationGracePeriod: TimeInterval
    public var maxUnconfirmedBeforeCircuitBreak: Int
    public var sampleHistoryLimit: Int
    /// How long a tripped breaker stays tripped before re-arming by itself.
    public var circuitBreakerAutoReset: TimeInterval
    /// Backoff after a failed CLI launch: base, doubling, capped.
    public var launchRetryBaseDelay: TimeInterval
    public var launchRetryMaxDelay: TimeInterval

    public init(
        minSamples: Int = 3,
        minSpan: TimeInterval = 4 * 60,
        pinTolerance: TimeInterval = 25,
        maxTrustedGap: TimeInterval = 10 * 60,
        minIntervalBetweenAttempts: TimeInterval = 5 * 60 * 60,
        maxAttemptsPerDay: Int = 5,
        confirmationGracePeriod: TimeInterval = 15 * 60,
        maxUnconfirmedBeforeCircuitBreak: Int = 2,
        sampleHistoryLimit: Int = 6,
        circuitBreakerAutoReset: TimeInterval = 24 * 60 * 60,
        launchRetryBaseDelay: TimeInterval = 5 * 60,
        launchRetryMaxDelay: TimeInterval = 60 * 60
    ) {
        self.minSamples = minSamples
        self.minSpan = minSpan
        self.pinTolerance = pinTolerance
        self.maxTrustedGap = maxTrustedGap
        self.minIntervalBetweenAttempts = minIntervalBetweenAttempts
        self.maxAttemptsPerDay = maxAttemptsPerDay
        self.confirmationGracePeriod = confirmationGracePeriod
        self.maxUnconfirmedBeforeCircuitBreak = maxUnconfirmedBeforeCircuitBreak
        self.sampleHistoryLimit = sampleHistoryLimit
        self.circuitBreakerAutoReset = circuitBreakerAutoReset
        self.launchRetryBaseDelay = launchRetryBaseDelay
        self.launchRetryMaxDelay = launchRetryMaxDelay
    }
}

public enum AutoStartDecision: Equatable, Sendable {
    case start
    case skip(reason: SkipReason)

    public enum SkipReason: String, Sendable {
        case noPrimaryWindow
        case circuitBroken
        case insufficientSamples
        case insufficientSpan
        case windowAlreadyTicking
        case cooldown
        case dailyCapReached
        case launchBackoff
    }
}

public struct Sample: Codable, Equatable, Sendable {
    public let fetchedAt: Date
    public let resetAt: Date

    public init(fetchedAt: Date, resetAt: Date) {
        self.fetchedAt = fetchedAt
        self.resetAt = resetAt
    }
}

public struct AutoStartState: Codable, Equatable, Sendable {
    /// Sliding-timestamp path history (see WindowSignal.active).
    public var samples: [Sample]
    /// Explicit-nil path tracking (see WindowSignal.explicitlyUnstarted).
    public var nilResetStreakStart: Date?
    public var nilResetObservationCount: Int

    public var lastAttemptAt: Date?
    public var attemptsInLast24h: [Date]
    public var pendingConfirmationSince: Date?
    public var consecutiveUnconfirmed: Int
    public var circuitBroken: Bool
    public var circuitBrokenAt: Date?
    public var consecutiveLaunchFailures: Int
    public var retryNotBefore: Date?
    /// End of the last window seen actually running. Once it's in the past,
    /// a fresh-looking window is known to be idle (see `evaluate`).
    public var lastKnownResetAt: Date?

    public init(
        samples: [Sample] = [],
        nilResetStreakStart: Date? = nil,
        nilResetObservationCount: Int = 0,
        lastAttemptAt: Date? = nil,
        attemptsInLast24h: [Date] = [],
        pendingConfirmationSince: Date? = nil,
        consecutiveUnconfirmed: Int = 0,
        circuitBroken: Bool = false,
        circuitBrokenAt: Date? = nil,
        consecutiveLaunchFailures: Int = 0,
        retryNotBefore: Date? = nil,
        lastKnownResetAt: Date? = nil
    ) {
        self.samples = samples
        self.nilResetStreakStart = nilResetStreakStart
        self.nilResetObservationCount = nilResetObservationCount
        self.lastAttemptAt = lastAttemptAt
        self.attemptsInLast24h = attemptsInLast24h
        self.pendingConfirmationSince = pendingConfirmationSince
        self.consecutiveUnconfirmed = consecutiveUnconfirmed
        self.circuitBroken = circuitBroken
        self.circuitBrokenAt = circuitBrokenAt
        self.consecutiveLaunchFailures = consecutiveLaunchFailures
        self.retryNotBefore = retryNotBefore
        self.lastKnownResetAt = lastKnownResetAt
    }

    private enum CodingKeys: String, CodingKey {
        case samples, nilResetStreakStart, nilResetObservationCount, lastAttemptAt,
             attemptsInLast24h, pendingConfirmationSince, consecutiveUnconfirmed,
             circuitBroken, circuitBrokenAt, consecutiveLaunchFailures, retryNotBefore,
             lastKnownResetAt
    }

    /// Tolerant decoding: every field falls back to its default when absent,
    /// so adding a field in a new version keeps the rest of the persisted
    /// state (cooldowns, daily cap, breaker) instead of silently wiping it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            samples: try c.decodeIfPresent([Sample].self, forKey: .samples) ?? [],
            nilResetStreakStart: try c.decodeIfPresent(Date.self, forKey: .nilResetStreakStart),
            nilResetObservationCount: try c.decodeIfPresent(Int.self, forKey: .nilResetObservationCount) ?? 0,
            lastAttemptAt: try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt),
            attemptsInLast24h: try c.decodeIfPresent([Date].self, forKey: .attemptsInLast24h) ?? [],
            pendingConfirmationSince: try c.decodeIfPresent(Date.self, forKey: .pendingConfirmationSince),
            consecutiveUnconfirmed: try c.decodeIfPresent(Int.self, forKey: .consecutiveUnconfirmed) ?? 0,
            circuitBroken: try c.decodeIfPresent(Bool.self, forKey: .circuitBroken) ?? false,
            circuitBrokenAt: try c.decodeIfPresent(Date.self, forKey: .circuitBrokenAt),
            consecutiveLaunchFailures: try c.decodeIfPresent(Int.self, forKey: .consecutiveLaunchFailures) ?? 0,
            retryNotBefore: try c.decodeIfPresent(Date.self, forKey: .retryNotBefore),
            lastKnownResetAt: try c.decodeIfPresent(Date.self, forKey: .lastKnownResetAt)
        )
    }
}

public protocol AutoStartStateStoring: Sendable {
    func state(for provider: ProviderID) -> AutoStartState
    func setState(_ state: AutoStartState, for provider: ProviderID)
}

/// Simple in-memory store — the default persisted implementation
/// (UserDefaults-backed) lives in the app target, which owns platform I/O.
public final class InMemoryAutoStartStore: AutoStartStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [ProviderID: AutoStartState] = [:]

    public init() {}

    public func state(for provider: ProviderID) -> AutoStartState {
        lock.lock()
        defer { lock.unlock() }
        return states[provider] ?? AutoStartState()
    }

    public func setState(_ state: AutoStartState, for provider: ProviderID) {
        lock.lock()
        defer { lock.unlock() }
        states[provider] = state
    }
}
