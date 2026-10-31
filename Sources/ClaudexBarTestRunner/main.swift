import Foundation
import ClaudexBarCore

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ description: String) throws {
    if !condition() {
        throw TestFailure(description: description)
    }
}

func expectNonNil<T>(_ value: T?, _ description: String) throws -> T {
    guard let value else { throw TestFailure(description: description) }
    return value
}

func fixtureData(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
        throw TestFailure(description: "Missing fixture \(name).json")
    }
    return try Data(contentsOf: url)
}

func testAutoStartDetectsPinnedWindow() throws {
    let store = InMemoryAutoStartStore()
    let config = AutoStartConfig(minSamples: 3, minSpan: 4 * 60, pinTolerance: 10, minIntervalBetweenAttempts: 60 * 60, maxAttemptsPerDay: 2)
    let starter = SessionAutoStarter(store: store, config: config)
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let fullWindow: TimeInterval = 5 * 60 * 60

    // Three polls, 3 minutes apart, each reporting resetAt = now + full window
    // (unstarted: the horizon slides forward in lockstep with wall-clock time).
    var lastDecision: AutoStartDecision = .skip(reason: .insufficientSamples)
    for i in 0..<3 {
        let now = base.addingTimeInterval(TimeInterval(i) * 180)
        let snapshot = UsageSnapshot(
            primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: now.addingTimeInterval(fullWindow)),
            secondary: nil,
            fetchedAt: now
        )
        lastDecision = starter.evaluate(provider: .claude, snapshot: snapshot, now: now)
    }
    try expect(lastDecision == .start, "pinned window across 3 samples spanning >4min should trigger start")
}

func testAutoStartDoesNotFireOnTickingWindow() throws {
    let store = InMemoryAutoStartStore()
    let config = AutoStartConfig(minSamples: 3, minSpan: 4 * 60, pinTolerance: 10)
    let starter = SessionAutoStarter(store: store, config: config)
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    // Started window: resetAt is a FIXED point in time across polls.
    let fixedResetAt = base.addingTimeInterval(3 * 60 * 60)

    var lastDecision: AutoStartDecision = .start
    for i in 0..<3 {
        let now = base.addingTimeInterval(TimeInterval(i) * 180)
        let snapshot = UsageSnapshot(
            primary: UsageWindow(windowLabel: "5h", remainingPercent: 60, resetAt: fixedResetAt),
            secondary: nil,
            fetchedAt: now
        )
        lastDecision = starter.evaluate(provider: .claude, snapshot: snapshot, now: now)
    }
    try expect(lastDecision == .skip(reason: .windowAlreadyTicking), "a resetAt that stays fixed across polls means the window already started")
}

func testAutoStartRequiresMinimumSpanNotJustSampleCount() throws {
    let store = InMemoryAutoStartStore()
    let config = AutoStartConfig(minSamples: 3, minSpan: 4 * 60, pinTolerance: 10)
    let starter = SessionAutoStarter(store: store, config: config)
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let fullWindow: TimeInterval = 5 * 60 * 60

    // 3 samples, but only 10 seconds apart each — real elapsed time is too
    // short to trust the "pinned" pattern (could just be rapid re-polling).
    var lastDecision: AutoStartDecision = .start
    for i in 0..<3 {
        let now = base.addingTimeInterval(TimeInterval(i) * 10)
        let snapshot = UsageSnapshot(
            primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: now.addingTimeInterval(fullWindow)),
            secondary: nil,
            fetchedAt: now
        )
        lastDecision = starter.evaluate(provider: .claude, snapshot: snapshot, now: now)
    }
    try expect(lastDecision == .skip(reason: .insufficientSpan), "3 samples 10s apart don't span enough real time to trust the pattern")
}

func testAutoStartRespectsCooldownAndDailyCap() throws {
    let store = InMemoryAutoStartStore()
    let config = AutoStartConfig(minSamples: 3, minSpan: 4 * 60, pinTolerance: 10, minIntervalBetweenAttempts: 60 * 60, maxAttemptsPerDay: 1)
    let starter = SessionAutoStarter(store: store, config: config)
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let fullWindow: TimeInterval = 5 * 60 * 60

    func pin(atOffsetMinutes offsets: [Int], from anchor: Date) -> AutoStartDecision {
        var decision: AutoStartDecision = .start
        for m in offsets {
            let now = anchor.addingTimeInterval(TimeInterval(m) * 60)
            let snapshot = UsageSnapshot(
                primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: now.addingTimeInterval(fullWindow)),
                secondary: nil,
                fetchedAt: now
            )
            decision = starter.evaluate(provider: .codex, snapshot: snapshot, now: now)
        }
        return decision
    }

    let first = pin(atOffsetMinutes: [0, 3, 6], from: base)
    try expect(first == .start, "first pinned run should trigger")
    starter.recordAttempt(provider: .codex, now: base.addingTimeInterval(6 * 60))

    // Immediately after, still pinned: cooldown should block a second attempt.
    let second = pin(atOffsetMinutes: [7, 10, 13], from: base)
    try expect(second == .skip(reason: .cooldown), "an attempt within the cooldown window must not fire again")
}

func testAutoStartCircuitBreaksAfterRepeatedUnconfirmedAttempts() throws {
    let store = InMemoryAutoStartStore()
    let config = AutoStartConfig(
        minSamples: 3,
        minSpan: 4 * 60,
        pinTolerance: 10,
        minIntervalBetweenAttempts: 1, // effectively no cooldown, to isolate circuit-breaker behavior
        maxAttemptsPerDay: 10,
        confirmationGracePeriod: 5 * 60,
        maxUnconfirmedBeforeCircuitBreak: 2
    )
    let starter = SessionAutoStarter(store: store, config: config)
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let fullWindow: TimeInterval = 5 * 60 * 60

    func stillPinnedSnapshot(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: now.addingTimeInterval(fullWindow)),
            secondary: nil,
            fetchedAt: now
        )
    }

    // Round 1: pin detected, attempt recorded, but the window never actually
    // starts (still pinned) past the confirmation grace period -> failure #1.
    var t = base
    for m in [0, 3, 6] {
        t = base.addingTimeInterval(TimeInterval(m) * 60)
        _ = starter.evaluate(provider: .claude, snapshot: stillPinnedSnapshot(now: t), now: t)
    }
    starter.recordAttempt(provider: .claude, now: t)
    t = t.addingTimeInterval(20 * 60) // past confirmationGracePeriod, still pinned
    _ = starter.evaluate(provider: .claude, snapshot: stillPinnedSnapshot(now: t), now: t)
    try expect(!starter.currentState(provider: .claude).circuitBroken, "one failed anchor should not trip the breaker yet")

    // Round 2: same story again -> failure #2 trips the breaker.
    for m in 1...3 {
        t = t.addingTimeInterval(TimeInterval(m) * 3 * 60)
        _ = starter.evaluate(provider: .claude, snapshot: stillPinnedSnapshot(now: t), now: t)
    }
    starter.recordAttempt(provider: .claude, now: t)
    t = t.addingTimeInterval(20 * 60)
    let finalDecision = starter.evaluate(provider: .claude, snapshot: stillPinnedSnapshot(now: t), now: t)
    try expect(starter.currentState(provider: .claude).circuitBroken, "two failed anchors in a row should trip the circuit breaker")
    try expect(finalDecision == .skip(reason: .circuitBroken), "a tripped breaker must block further evaluation")

    starter.resetCircuitBreaker(provider: .claude)
    try expect(!starter.currentState(provider: .claude).circuitBroken, "resetCircuitBreaker should clear the tripped state")
}

func testAutoStartDetectsExplicitNilResetAtSignal() throws {
    // Reproduces the real captured timeline: Claude reports resets_at as
    // null (not "now + 5h") for a genuinely fresh, never-used window.
    let store = InMemoryAutoStartStore()
    let config = AutoStartConfig(minSamples: 3, minSpan: 4 * 60)
    let starter = SessionAutoStarter(store: store, config: config)
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    var lastDecision: AutoStartDecision = .skip(reason: .insufficientSamples)
    for offsetMinutes in [0, 3, 6] {
        let now = base.addingTimeInterval(TimeInterval(offsetMinutes) * 60)
        let snapshot = UsageSnapshot(
            primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: nil),
            secondary: nil,
            fetchedAt: now
        )
        lastDecision = starter.evaluate(provider: .claude, snapshot: snapshot, now: now)
    }
    try expect(lastDecision == .start, "resetAt=nil at 100% remaining, sustained for 3 polls over 6 minutes, must trigger start")
}

func testAutoStartDoesNotFireOnSingleNilResetBlip() throws {
    let store = InMemoryAutoStartStore()
    let config = AutoStartConfig(minSamples: 3, minSpan: 4 * 60)
    let starter = SessionAutoStarter(store: store, config: config)
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    let snapshot = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: nil),
        secondary: nil,
        fetchedAt: base
    )
    let decision = starter.evaluate(provider: .claude, snapshot: snapshot, now: base)
    try expect(decision != .start, "a single nil-resetAt observation must not fire on its own")
}

func testAutoStartConfirmsAnchorWhenNilResetBecomesReal() throws {
    let store = InMemoryAutoStartStore()
    let config = AutoStartConfig(minSamples: 3, minSpan: 4 * 60, confirmationGracePeriod: 15 * 60, maxUnconfirmedBeforeCircuitBreak: 2)
    let starter = SessionAutoStarter(store: store, config: config)
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    for offsetMinutes in [0, 3, 6] {
        let now = base.addingTimeInterval(TimeInterval(offsetMinutes) * 60)
        let snapshot = UsageSnapshot(primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: nil), secondary: nil, fetchedAt: now)
        _ = starter.evaluate(provider: .claude, snapshot: snapshot, now: now)
    }
    let attemptTime = base.addingTimeInterval(6 * 60)
    starter.recordAttempt(provider: .claude, now: attemptTime)

    // Next poll: the window actually started (real resetAt, usage > 0%).
    let confirmTime = attemptTime.addingTimeInterval(60)
    let startedSnapshot = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 98, resetAt: confirmTime.addingTimeInterval(5 * 60 * 60)),
        secondary: nil,
        fetchedAt: confirmTime
    )
    _ = starter.evaluate(provider: .claude, snapshot: startedSnapshot, now: confirmTime)

    try expect(starter.currentState(provider: .claude).consecutiveUnconfirmed == 0, "seeing a real resetAt after the nil-signal anchor should confirm success")
    try expect(!starter.currentState(provider: .claude).circuitBroken, "a confirmed anchor must not trip the breaker")
}

func testAutoStartHighConfidenceFiresOnSingleObservation() throws {
    // Simulates a check deliberately scheduled for right after a *known*
    // resetAt boundary: a single "explicitly unstarted" read should be
    // enough, no multi-sample wait needed.
    let store = InMemoryAutoStartStore()
    let config = AutoStartConfig(minSamples: 3, minSpan: 4 * 60)
    let starter = SessionAutoStarter(store: store, config: config)
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    let snapshot = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: nil),
        secondary: nil,
        fetchedAt: now
    )
    let decision = starter.evaluate(provider: .claude, snapshot: snapshot, now: now, highConfidence: true)
    try expect(decision == .start, "a high-confidence scheduled check should fire on the very first idle observation")
}

func testAutoStartHighConfidenceStillRespectsCooldown() throws {
    let store = InMemoryAutoStartStore()
    let config = AutoStartConfig(minSamples: 3, minSpan: 4 * 60, minIntervalBetweenAttempts: 60 * 60)
    let starter = SessionAutoStarter(store: store, config: config)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    starter.recordAttempt(provider: .claude, now: now)

    let snapshot = UsageSnapshot(primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: nil), secondary: nil, fetchedAt: now)
    let decision = starter.evaluate(provider: .claude, snapshot: snapshot, now: now.addingTimeInterval(30), highConfidence: true)
    try expect(decision == .skip(reason: .cooldown), "high confidence bypasses the sample wait, not the cooldown/safety caps")
}

func testAutoStartResetsHistoryAcrossAnOrganicWindowResetGap() throws {
    let store = InMemoryAutoStartStore()
    let config = AutoStartConfig(minSamples: 3, minSpan: 4 * 60, pinTolerance: 25)
    let starter = SessionAutoStarter(store: store, config: config)
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let fullWindow: TimeInterval = 5 * 60 * 60

    // Evening: window is actively ticking (fixed resetAt), two observations
    // close together — mirrors "22:00" and "22:02" from a real session.
    let tickingResetAt = base.addingTimeInterval(70 * 60) // fixed point in time
    for offset in [0, 120] {
        let now = base.addingTimeInterval(TimeInterval(offset))
        let snapshot = UsageSnapshot(
            primary: UsageWindow(windowLabel: "5h", remainingPercent: 38, resetAt: tickingResetAt),
            secondary: nil,
            fetchedAt: now
        )
        _ = starter.evaluate(provider: .claude, snapshot: snapshot, now: now)
    }

    // Mac sleeps for ~6.5 hours. The window naturally resets on its own
    // partway through (nobody sent a message), so by the time the network
    // comes back it's freshly unstarted — a different epoch than the two
    // samples above, which described the old, already-ticking window.
    let wakeBase = base.addingTimeInterval(6.5 * 60 * 60)
    var lastDecision: AutoStartDecision = .skip(reason: .insufficientSamples)
    for offsetSeconds in stride(from: 0, through: 5 * 60, by: 60) {
        let now = wakeBase.addingTimeInterval(TimeInterval(offsetSeconds))
        let snapshot = UsageSnapshot(
            primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: now.addingTimeInterval(fullWindow)),
            secondary: nil,
            fetchedAt: now
        )
        lastDecision = starter.evaluate(provider: .claude, snapshot: snapshot, now: now)
    }

    try expect(
        lastDecision == .start,
        "a freshly-unstarted window after wake must not be blocked by stale pre-sleep samples from the window's previous epoch"
    )
}

// MARK: - v0.2.1: launch failures, breaker recovery, persistence, Codex headers

private func idleClaudeSnapshot(_ now: Date) -> UsageSnapshot {
    UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: nil),
        secondary: nil,
        fetchedAt: now
    )
}

func testAutoStartLaunchFailureRollsBackAndBacksOff() throws {
    let store = InMemoryAutoStartStore()
    let config = AutoStartConfig(launchRetryBaseDelay: 5 * 60, launchRetryMaxDelay: 60 * 60)
    let starter = SessionAutoStarter(store: store, config: config)
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    starter.recordAttempt(provider: .claude, now: t0)
    starter.recordLaunchFailed(provider: .claude, now: t0)
    let state = starter.currentState(provider: .claude)
    try expect(state.attemptsInLast24h.isEmpty, "a failed launch must not count toward the daily cap")
    try expect(state.lastAttemptAt == nil, "a failed launch must not start the multi-hour cooldown")
    try expect(state.pendingConfirmationSince == nil, "a failed launch must not await confirmation")

    let during = starter.evaluate(provider: .claude, snapshot: idleClaudeSnapshot(t0.addingTimeInterval(60)), now: t0.addingTimeInterval(60), highConfidence: true)
    try expect(during == .skip(reason: .launchBackoff), "within the backoff window a retry must wait")

    let after = t0.addingTimeInterval(6 * 60)
    let retry = starter.evaluate(provider: .claude, snapshot: idleClaudeSnapshot(after), now: after, highConfidence: true)
    try expect(retry == .start, "once the short backoff passes, it retries — not 5 hours later")
}

func testAutoStartLaunchFailuresNeverTripBreakerAndBackoffCaps() throws {
    let store = InMemoryAutoStartStore()
    let config = AutoStartConfig(confirmationGracePeriod: 60, launchRetryBaseDelay: 5 * 60, launchRetryMaxDelay: 60 * 60)
    let starter = SessionAutoStarter(store: store, config: config)
    var now = Date(timeIntervalSince1970: 1_700_000_000)

    var delays: [TimeInterval] = []
    for _ in 0..<8 {
        starter.recordAttempt(provider: .claude, now: now)
        starter.recordLaunchFailed(provider: .claude, now: now)
        let retryAt = try expectNonNil(starter.currentState(provider: .claude).retryNotBefore, "backoff scheduled")
        delays.append(retryAt.timeIntervalSince(now))
        now = retryAt.addingTimeInterval(1)
        _ = starter.evaluate(provider: .claude, snapshot: idleClaudeSnapshot(now), now: now)
    }
    try expect(!starter.currentState(provider: .claude).circuitBroken, "network/CLI failures must never trip the breaker")
    try expect(delays.prefix(4) == [300, 600, 1200, 2400], "backoff doubles from 5 minutes: \(delays)")
    try expect(delays.last == 3600, "backoff is capped at 1 hour: \(delays)")

    starter.recordAttempt(provider: .claude, now: now)
    starter.recordLaunchSucceeded(provider: .claude)
    let state = starter.currentState(provider: .claude)
    try expect(state.consecutiveLaunchFailures == 0 && state.retryNotBefore == nil, "a successful launch clears the backoff")
}

func testAutoStartBreakerAutoResetsAfterCoolingOff() throws {
    let store = InMemoryAutoStartStore()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    store.setState(AutoStartState(circuitBroken: true, circuitBrokenAt: t0), for: .claude)
    let starter = SessionAutoStarter(store: store, config: AutoStartConfig(circuitBreakerAutoReset: 24 * 60 * 60))

    let early = t0.addingTimeInterval(23 * 60 * 60)
    try expect(
        starter.evaluate(provider: .claude, snapshot: idleClaudeSnapshot(early), now: early) == .skip(reason: .circuitBroken),
        "the breaker holds during the cooling-off period"
    )
    let later = t0.addingTimeInterval(24 * 60 * 60 + 1)
    _ = starter.evaluate(provider: .claude, snapshot: idleClaudeSnapshot(later), now: later)
    try expect(!starter.currentState(provider: .claude).circuitBroken, "the breaker re-arms by itself after 24h")
}

func testAutoStartClearsBreakerTrippedByLegacyVersion() throws {
    // v0.2.0 persisted `circuitBroken: true` without a timestamp, and tripped
    // it on network-level launch failures. Such state must not stay stuck.
    let store = InMemoryAutoStartStore()
    store.setState(AutoStartState(circuitBroken: true, circuitBrokenAt: nil), for: .claude)
    let starter = SessionAutoStarter(store: store)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    _ = starter.evaluate(provider: .claude, snapshot: idleClaudeSnapshot(now), now: now)
    try expect(!starter.currentState(provider: .claude).circuitBroken, "a legacy (timestamp-less) trip is cleared on upgrade")
}

func testAutoStartStateDecodesOlderPersistedShape() throws {
    // Exactly the keys v0.2.0 wrote — none of the v0.2.1 additions.
    let legacyJSON = #"""
    {"samples":[],"nilResetObservationCount":2,"attemptsInLast24h":[700000000],
     "lastAttemptAt":700000000,"consecutiveUnconfirmed":1,"circuitBroken":false}
    """#
    let state = try JSONDecoder().decode(AutoStartState.self, from: Data(legacyJSON.utf8))
    try expect(state.attemptsInLast24h.count == 1, "older state keeps its daily-cap history")
    try expect(state.lastAttemptAt != nil, "older state keeps its cooldown")
    try expect(state.consecutiveUnconfirmed == 1 && state.nilResetObservationCount == 2, "older counters survive")
    try expect(state.consecutiveLaunchFailures == 0 && state.retryNotBefore == nil, "new fields default cleanly")
}

private struct StubCodexAuth: CodexAuthReading {
    let accountID: String?
    func readAccessToken() throws -> String { "test-token" }
    func readAccountID() -> String? { accountID }
}

private final class CapturingHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: URLRequest?
    private let body: Data

    init(body: Data) { self.body = body }

    var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { captured = request }
        return HTTPResponse(data: body, statusCode: 200)
    }
}

private func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached {
        box.value = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

func testCodexSendsAccountIDHeaderWhenKnown() throws {
    let body = try fixtureData("codex_usage")
    let withID = CapturingHTTPClient(body: body)
    _ = runBlocking { await CodexProvider(authReader: StubCodexAuth(accountID: "acct-123"), httpClient: withID).fetchUsage() }
    try expect(withID.lastRequest?.value(forHTTPHeaderField: "chatgpt-account-id") == "acct-123", "account id is forwarded")

    let withoutID = CapturingHTTPClient(body: body)
    _ = runBlocking { await CodexProvider(authReader: StubCodexAuth(accountID: nil), httpClient: withoutID).fetchUsage() }
    try expect(withoutID.lastRequest != nil, "request was made")
    try expect(withoutID.lastRequest?.value(forHTTPHeaderField: "chatgpt-account-id") == nil, "no header when unknown")
}

func testCodexAuthReaderReadsAccountID() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claudexbar-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let withID = dir.appendingPathComponent("with.json")
    try Data(#"{"tokens":{"access_token":"t","account_id":" db451ad8 "}}"#.utf8).write(to: withID)
    try expect(CodexAuthReader(authURL: withID).readAccountID() == "db451ad8", "account_id is read and trimmed")

    let blank = dir.appendingPathComponent("blank.json")
    try Data(#"{"tokens":{"access_token":"t","account_id":""}}"#.utf8).write(to: blank)
    try expect(CodexAuthReader(authURL: blank).readAccountID() == nil, "an empty account_id is treated as unknown")
}

func testClaudeTokenRefreshBodyEscapesReservedCharacters() throws {
    let body = String(decoding: ClaudeOAuthFlow.formBody(["refresh_token": "a+b&c=d"]), as: UTF8.self)
    try expect(body == "refresh_token=a%2Bb%26c%3Dd", "+, & and = are escaped in form bodies: \(body)")
}

// MARK: - v0.3.0: percent mode, pace, window durations, ProcessRunner

func testPercentModeShowsUsedOrRemaining() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let window = UsageWindow(windowLabel: "5h", remainingPercent: 28, resetAt: now.addingTimeInterval(3600))
    try expect(UsageFormatter.percentText(for: window) == "28%", "remaining is the default")
    try expect(UsageFormatter.percentText(for: window, mode: .used) == "72%", "used = 100 - remaining")
    try expect(UsageFormatter.metricDisplay(for: window, unavailableLabel: "5h", now: now, mode: .used).value == "72%", "tray value follows mode")
    let full = UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: nil)
    try expect(UsageFormatter.metricDisplay(for: full, unavailableLabel: "5h", now: now, mode: .used).value == "0%", "a fresh window reads 0% used")
    try expect(UsageFormatter.percentText(for: nil, mode: .used) == "∞", "a missing window stays ∞")
}

func testPaceProjectsExhaustionBeforeReset() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let duration: TimeInterval = 5 * 3600
    // 1h into a 5h window, 50% used: 50%/h => the rest lasts 1h, reset is 4h away.
    let window = UsageWindow(windowLabel: "5h", remainingPercent: 50, resetAt: now.addingTimeInterval(4 * 3600), windowDuration: duration)
    let pace = try expectNonNil(UsageFormatter.pace(for: window, now: now), "pace is computed")
    try expect(abs(pace.elapsedFraction - 0.2) < 0.001, "20% of the window elapsed")
    try expect(abs(pace.projectedExhaustion.timeIntervalSince(now) - 3600) < 1, "runs out in ~1h")
    try expect(pace.runsOutBeforeReset, "1h to exhaustion < 4h to reset")
    try expect(UsageFormatter.paceSummary(pace, windowName: "Session", now: now).contains("runs out in ~1h"), "summary explains it")
}

func testPaceOnTrackAndInsufficientEvidence() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let duration: TimeInterval = 5 * 3600
    // 4h in, 50% used: rest lasts 4h, reset is 1h away => fine.
    let fine = UsageWindow(windowLabel: "5h", remainingPercent: 50, resetAt: now.addingTimeInterval(3600), windowDuration: duration)
    try expect(UsageFormatter.pace(for: fine, now: now)?.runsOutBeforeReset == false, "slow burn is on pace")
    // 10 minutes in (3% of window): too early to judge.
    let early = UsageWindow(windowLabel: "5h", remainingPercent: 70, resetAt: now.addingTimeInterval(duration - 600), windowDuration: duration)
    try expect(UsageFormatter.pace(for: early, now: now) == nil, "no projection before 10% of the window elapsed")
    // Barely used.
    let light = UsageWindow(windowLabel: "5h", remainingPercent: 95, resetAt: now.addingTimeInterval(3600), windowDuration: duration)
    try expect(UsageFormatter.pace(for: light, now: now) == nil, "no projection under 10% used")
    // Exhausted, unstarted, or no duration.
    try expect(UsageFormatter.pace(for: UsageWindow(windowLabel: "5h", remainingPercent: 0, resetAt: now.addingTimeInterval(3600), windowDuration: duration), now: now) == nil, "already exhausted")
    try expect(UsageFormatter.pace(for: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: nil, windowDuration: duration), now: now) == nil, "unstarted")
    try expect(UsageFormatter.pace(for: UsageWindow(windowLabel: "5h", remainingPercent: 50, resetAt: now.addingTimeInterval(3600)), now: now) == nil, "unknown duration")
}

func testProvidersReportWindowDurations() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let claude = try ClaudeProvider.parseUsageResponse(try fixtureData("claude_usage"), fetchedAt: now)
    try expect(claude.primary?.windowDuration == 5 * 3600, "Claude session is 5h")
    try expect(claude.secondary?.windowDuration == 7 * 24 * 3600, "Claude weekly is 7d")
    let go = try CodexProvider.parseUsageResponse(try fixtureData("codex_usage_go_plan_check"), fetchedAt: now)
    try expect(go.secondary?.windowDuration == 2_592_000, "Codex Go window duration comes from limit_window_seconds")
    let legacy = try CodexProvider.parseUsageResponse(try fixtureData("codex_usage"), fetchedAt: now)
    try expect(legacy.primary?.windowDuration == 5 * 3600 && legacy.secondary?.windowDuration == 7 * 24 * 3600, "legacy Codex shape falls back to 5h/7d")
}

func testProcessRunnerCapturesExitCodeAndStreams() throws {
    let result = runBlocking {
        await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2; exit 3"], timeout: 10)
    }
    try expect(result.exitCode == 3 && !result.succeeded, "exit code is reported: \(result.exitCode)")
    try expect(result.stdout.contains("out") && result.stderr.contains("err"), "both streams captured")
    try expect(result.diagnosticExcerpt() == "err", "excerpt prefers stderr: \(result.diagnosticExcerpt())")
}

func testProcessRunnerDrainsLargeOutputWithoutDeadlock() throws {
    // ~1 MB on stdout: far beyond the 64 KB pipe buffer. If output weren't
    // drained while the child runs, this would block until the timeout.
    let started = Date()
    let result = runBlocking {
        await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes x | head -c 1048576; echo tail-marker"],
            timeout: 20,
            outputLimit: 4096
        )
    }
    try expect(result.succeeded && !result.timedOut, "large output completes: exit \(result.exitCode) timedOut \(result.timedOut)")
    try expect(Date().timeIntervalSince(started) < 10, "no pipe-buffer stall")
    try expect(result.stdout.utf8.count <= 4096 && result.stdout.contains("tail-marker"), "only the tail is kept")
}

func testProcessRunnerTimesOutAndReportsLaunchFailure() throws {
    let started = Date()
    let slow = runBlocking {
        await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.5)
    }
    try expect(slow.timedOut && !slow.succeeded, "a hung child is timed out")
    try expect(Date().timeIntervalSince(started) < 8, "timeout actually fires")

    let missing = runBlocking {
        await ProcessRunner.run(executable: URL(fileURLWithPath: "/nonexistent/claudexbar-test"), arguments: [], timeout: 5)
    }
    try expect(missing.launchFailed && !missing.succeeded, "a missing executable is a launch failure, not a hang")
}

func testProcessRunnerExcerptIsSingleLineAndRedacted() throws {
    let result = runBlocking {
        await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo 'line one' >&2; echo 'token sk-ant-api03-SECRETSECRETSECRET' >&2; exit 1"],
            timeout: 10
        )
    }
    let excerpt = result.diagnosticExcerpt()
    try expect(!excerpt.contains("\n") && excerpt.contains("line one | token"), "multi-line stderr is joined: \(excerpt)")
    try expect(!excerpt.contains("SECRETSECRETSECRET"), "secrets are redacted: \(excerpt)")
}

// MARK: - v0.3.1: act on the first observation after a known boundary

func testAutoStartActsOnFirstObservationAfterSleepingThroughReset() throws {
    // Reproduces the night of 2026-09-27: the window ran until 01:40Z, the Mac
    // slept, and only woke for ~45 s about once an hour.
    let store = InMemoryAutoStartStore()
    let starter = SessionAutoStarter(store: store)
    let reset = Date(timeIntervalSince1970: 1_790_476_800) // the running window's end
    let evening = reset.addingTimeInterval(-3 * 3600)

    let running = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 60, resetAt: reset, windowDuration: 5 * 3600),
        secondary: nil,
        fetchedAt: evening
    )
    _ = starter.evaluate(provider: .claude, snapshot: running, now: evening)
    try expect(starter.currentState(provider: .claude).lastKnownResetAt == reset, "a running window's end is remembered")

    // First DarkWake two hours after the reset: one observation, fresh window.
    let dawn = reset.addingTimeInterval(2 * 3600)
    let decision = starter.evaluate(provider: .claude, snapshot: idleClaudeSnapshot(dawn), now: dawn)
    try expect(decision == .start, "the first fresh observation after a passed boundary anchors immediately: \(decision)")
}

func testAutoStartWithoutPassedBoundaryStillNeedsSeveralSamples() throws {
    let store = InMemoryAutoStartStore()
    let starter = SessionAutoStarter(store: store)
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    // No history at all (fresh install): keep the conservative multi-sample rule.
    try expect(starter.evaluate(provider: .claude, snapshot: idleClaudeSnapshot(now), now: now) == .skip(reason: .insufficientSamples), "no known boundary -> no shortcut")
    // A known boundary that is still in the future doesn't count either.
    store.setState(AutoStartState(lastKnownResetAt: now.addingTimeInterval(3600)), for: .claude)
    try expect(starter.evaluate(provider: .claude, snapshot: idleClaudeSnapshot(now), now: now) == .skip(reason: .insufficientSamples), "future boundary -> no shortcut")
}

func testAutoStartSlidingProviderUsesPassedBoundaryButNeverStoresSlidingReset() throws {
    let store = InMemoryAutoStartStore()
    let starter = SessionAutoStarter(store: store)
    let boundary = Date(timeIntervalSince1970: 1_790_000_000)
    store.setState(AutoStartState(lastKnownResetAt: boundary), for: .codex)
    let now = boundary.addingTimeInterval(3600)
    let duration: TimeInterval = 5 * 3600
    let fresh = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: now.addingTimeInterval(duration), windowDuration: duration),
        secondary: nil,
        fetchedAt: now
    )
    try expect(starter.evaluate(provider: .codex, snapshot: fresh, now: now) == .start, "Codex-style fresh window after a passed boundary anchors at once")
    try expect(starter.currentState(provider: .codex).lastKnownResetAt == boundary, "a sliding 'now + length' reset is never stored as a boundary")
}

func testAutoStartStateKeepsLastKnownResetAcrossDecoding() throws {
    let state = AutoStartState(lastKnownResetAt: Date(timeIntervalSince1970: 1_790_000_000))
    let decoded = try JSONDecoder().decode(AutoStartState.self, from: try JSONEncoder().encode(state))
    try expect(decoded.lastKnownResetAt == state.lastKnownResetAt, "boundary survives a relaunch")
}

// MARK: - v0.3.2: a started window at 100% shows its countdown

func testFullButStartedWindowShowsCountdown() throws {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let duration: TimeInterval = 5 * 3600
    // An anchor rounded to 0% used, clock running: 4h51m to go.
    let anchored = UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: now.addingTimeInterval(4 * 3600 + 51 * 60), windowDuration: duration)
    let shown = UsageFormatter.display(for: anchored, now: now)
    try expect(shown.label == "4h51m" && shown.remainingPercent == 100, "started window shows its countdown: \(shown.label)")
}

func testUnstartedWindowShapesStillShowWindowName() throws {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let duration: TimeInterval = 5 * 3600
    let claudeIdle = UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: nil, windowDuration: duration)
    try expect(UsageFormatter.display(for: claudeIdle, now: now).label == "5h", "Claude idle (null reset) shows the window name")
    let codexIdle = UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: now.addingTimeInterval(duration - 30), windowDuration: duration)
    try expect(UsageFormatter.display(for: codexIdle, now: now).label == "5h", "Codex idle (reset = now + length) shows the window name")
    let unknownLength = UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: now.addingTimeInterval(3600))
    try expect(UsageFormatter.display(for: unknownLength, now: now).label == "5h", "unknown duration keeps the old behaviour")
    let partial = UsageWindow(windowLabel: "5h", remainingPercent: 99, resetAt: now.addingTimeInterval(3600), windowDuration: duration)
    try expect(UsageFormatter.display(for: partial, now: now).label == "1h", "partial usage still shows the countdown")
}

// MARK: - v0.3.3: Claude credential sources

private final class StubClaudeReader: ClaudeCredentialReading, @unchecked Sendable {
    private let lock = NSLock()
    private var candidates: [ClaudeCredentialCandidate]
    private(set) var discardCount = 0

    init(_ candidates: [ClaudeCredentialCandidate]) { self.candidates = candidates }

    func readCredentials() throws -> ClaudeCredentials {
        guard let first = credentialCandidates().first else { throw UsageError.missingAuth }
        return first.credentials
    }

    func credentialCandidates() -> [ClaudeCredentialCandidate] {
        lock.withLock { candidates }
    }

    func discardOwnedCredentials() {
        lock.withLock {
            discardCount += 1
            candidates.removeAll { $0.source == .claudexbar }
        }
    }
}

/// Answers by URL path: the token endpoint and the usage endpoint get
/// separate canned responses; every request is recorded.
private final class RoutingHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    private let refreshStatus: Int
    private let usageStatusByToken: [String: Int]
    private let usageBody: Data

    init(refreshStatus: Int, usageStatusByToken: [String: Int], usageBody: Data) {
        self.refreshStatus = refreshStatus
        self.usageStatusByToken = usageStatusByToken
        self.usageBody = usageBody
    }

    var refreshRequestCount: Int {
        lock.withLock { requests.filter { $0.httpMethod == "POST" }.count }
    }

    var usageTokens: [String] {
        lock.withLock {
            requests.filter { $0.httpMethod != "POST" }
                .compactMap { $0.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") }
        }
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { requests.append(request) }
        if request.httpMethod == "POST" {
            return HTTPResponse(data: Data(#"{"error":"invalid_grant"}"#.utf8), statusCode: refreshStatus)
        }
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        let status = usageStatusByToken[token] ?? 401
        return HTTPResponse(data: status == 200 ? usageBody : Data(), statusCode: status)
    }
}

private let pastMillis = 1_000          // expired long ago
private let futureMillis = Int.max / 2  // far in the future

func testDeadOwnSessionFallsBackToFreshClaudeCodeLogin() throws {
    // Exactly the 2026-10-28 situation: ClaudexBar's own session is expired
    // and its refresh token is rejected, while Claude Code was just re-logged.
    let reader = StubClaudeReader([
        ClaudeCredentialCandidate(credentials: ClaudeCredentials(accessToken: "own-old", refreshToken: "own-dead-rt", expiresAt: pastMillis), source: .claudexbar),
        ClaudeCredentialCandidate(credentials: ClaudeCredentials(accessToken: "cc-fresh", refreshToken: "cc-rt", expiresAt: futureMillis), source: .claudeCode)
    ])
    let http = RoutingHTTPClient(refreshStatus: 400, usageStatusByToken: ["cc-fresh": 200], usageBody: try fixtureData("claude_usage"))
    let persisted = ResultBox<Int>(); persisted.value = 0
    let provider = ClaudeProvider(credentialReader: reader, httpClient: http, persistRefreshed: { _ in persisted.value! += 1 })

    let result = runBlocking { await provider.fetchUsage() }
    guard case .success = result else { throw TestFailure(description: "expected success via Claude Code login, got \(result)") }
    try expect(http.usageTokens == ["cc-fresh"], "usage was read with Claude Code's fresh token: \(http.usageTokens)")
    try expect(reader.discardCount == 1, "the definitively rejected own session is discarded")
    try expect(persisted.value == 0, "nothing was persisted")

    // Next poll goes straight to Claude Code — no repeated failing refresh.
    _ = runBlocking { await provider.fetchUsage() }
    try expect(http.refreshRequestCount == 1, "the dead refresh token isn't retried every minute")
}

func testClaudeCodeCredentialIsNeverRefreshed() throws {
    // An expired Claude Code token must not be refreshed by ClaudexBar:
    // refreshing rotates the refresh token and logs Claude Code out.
    let reader = StubClaudeReader([
        ClaudeCredentialCandidate(credentials: ClaudeCredentials(accessToken: "cc-old", refreshToken: "cc-rt", expiresAt: pastMillis), source: .claudeCode)
    ])
    let http = RoutingHTTPClient(refreshStatus: 200, usageStatusByToken: [:], usageBody: Data())
    let provider = ClaudeProvider(credentialReader: reader, httpClient: http, persistRefreshed: { _ in })
    let result = runBlocking { await provider.fetchUsage() }
    guard case .failure(.authExpired) = result else { throw TestFailure(description: "expected authExpired, got \(result)") }
    try expect(http.refreshRequestCount == 0, "no refresh request is ever made with Claude Code's refresh token")
    try expect(http.requests.isEmpty, "an expired foreign token isn't even sent")
}

func testClaudeCode401DoesNotTriggerRefresh() throws {
    let reader = StubClaudeReader([
        ClaudeCredentialCandidate(credentials: ClaudeCredentials(accessToken: "cc-revoked", refreshToken: "cc-rt", expiresAt: futureMillis), source: .claudeCode)
    ])
    let http = RoutingHTTPClient(refreshStatus: 200, usageStatusByToken: ["cc-revoked": 401], usageBody: Data())
    let provider = ClaudeProvider(credentialReader: reader, httpClient: http, persistRefreshed: { _ in })
    let result = runBlocking { await provider.fetchUsage() }
    guard case .failure(.authExpired) = result else { throw TestFailure(description: "expected authExpired, got \(result)") }
    try expect(http.refreshRequestCount == 0, "a 401 on Claude Code's token doesn't refresh it either")
}

// MARK: - v0.4.0: in-app updates

func testUpdateCheckerTargetsTheFork() throws {
    // Upstream's releases lack this fork's patches; offering them as an
    // "update" would silently downgrade users.
    try expect(UpdateChecker.repoSlug == "l0bz1k/claudexbar", "update checks must come from the fork: \(UpdateChecker.repoSlug)")
}

func testUpdateCheckerParsesReleaseWithAssets() throws {
    let json = #"""
    {"tag_name":"v0.4.0","html_url":"https://github.com/l0bz1k/claudexbar/releases/tag/v0.4.0","body":"### Added\n- things",
     "assets":[
      {"name":"ClaudexBar.zip.sha256","browser_download_url":"https://example.com/ClaudexBar.zip.sha256"},
      {"name":"ClaudexBar.zip","browser_download_url":"https://example.com/ClaudexBar.zip"}]}
    """#
    let update = try expectNonNil(UpdateChecker.parseRelease(Data(json.utf8), currentVersion: "0.3.3"), "release parses")
    try expect(update.latest == "0.4.0" && update.isNewer, "v-prefix stripped and newer than 0.3.3")
    try expect(update.zipURL?.absoluteString == "https://example.com/ClaudexBar.zip", "zip asset found by name")
    try expect(update.checksumURL?.absoluteString == "https://example.com/ClaudexBar.zip.sha256", "checksum asset found by name")
    try expect(update.canInstallInPlace && update.notes.contains("things"), "installable, notes kept")

    let bare = #"{"tag_name":"v0.4.0","html_url":"https://x/y"}"#
    let noAssets = try expectNonNil(UpdateChecker.parseRelease(Data(bare.utf8), currentVersion: "0.4.0"), "assetless release parses")
    try expect(!noAssets.canInstallInPlace && !noAssets.isNewer, "no assets -> release page only; same version is not newer")
}

func testUpdateChecksumVerification() throws {
    let data = Data("ClaudexBar archive".utf8)
    // shasum -a 256 of the bytes above
    let digest = "1d6ba51c8b1b2f2c35bdf0cc3cd0f7abf3b3d8db30b7ad91e2b3da8e5ee9e8c4"
    let actual = UpdateCheckerDigest.hex(data)
    try expect(UpdateChecker.matchesSHA256(data, checksumText: "\(actual)  ClaudexBar.zip\n"), "shasum format matches")
    try expect(UpdateChecker.matchesSHA256(data, checksumText: actual.uppercased()), "bare, case-insensitive digest matches")
    try expect(!UpdateChecker.matchesSHA256(data, checksumText: "\(digest)  ClaudexBar.zip"), "a different digest is rejected")
    try expect(!UpdateChecker.matchesSHA256(data, checksumText: "not-a-hash"), "garbage is rejected")
    try expect(!UpdateChecker.matchesSHA256(data, checksumText: ""), "empty is rejected")
}

import CryptoKit
enum UpdateCheckerDigest {
    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

// MARK: - v0.4.1: CDN block recognition

private let cloudflareBlockPage = Data("""
<html>
  <head>
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <style global>body{font-family:Arial,Helvetica,sans-serif}</style>
  </head>
  <body><h1>Unable to load site</h1><p>Please try again later. If you are using a VPN, try turning it off.</p>
  <p>Check the status page for information on outages.</p><p>[IP:45.141.79.41 | Ray ID:a5191cfb5ea596dd]</p></body>
</html>
""".utf8)

private struct StaticHTTPClient: HTTPClient {
    let status: Int
    let body: Data
    func data(for request: URLRequest) async throws -> HTTPResponse { HTTPResponse(data: body, statusCode: status) }
}

func testEdgeBlockIsRecognisedWithIP() throws {
    let error = try expectNonNil(EdgeBlockDetector.blockError(statusCode: 403, body: cloudflareBlockPage), "block page recognised")
    try expect(error == .blockedByEdge(ip: "45.141.79.41"), "exit IP extracted: \(error)")
    try expect(error.statusLabel == "vpn" && !error.isTransient, "shown as 'vpn', not masked by stale data")
    try expect(error.sanitizedDescription.contains("45.141.79.41"), "log line names the IP")
}

func testEdgeBlockDetectionIsNarrow() throws {
    let json403 = Data(#"{"detail":"Forbidden"}"#.utf8)
    try expect(EdgeBlockDetector.blockError(statusCode: 403, body: json403) == nil, "an API's own JSON 403 is not a CDN block")
    try expect(EdgeBlockDetector.blockError(statusCode: 503, body: cloudflareBlockPage) == nil, "Cloudflare 5xx outage pages are not a block")
    try expect(EdgeBlockDetector.blockError(statusCode: 403, body: Data("<html><body>Forbidden</body></html>".utf8)) == nil, "generic HTML 403 without Cloudflare markers is not a block")
}

func testProvidersReportEdgeBlock() throws {
    let codex = CodexProvider(authReader: StubCodexAuth(accountID: "a"), httpClient: StaticHTTPClient(status: 403, body: cloudflareBlockPage))
    let codexResult = runBlocking { await codex.fetchUsage() }
    guard case .failure(.blockedByEdge(ip: "45.141.79.41")) = codexResult else { throw TestFailure(description: "Codex: expected blockedByEdge, got \(codexResult)") }

    let reader = StubClaudeReader([
        ClaudeCredentialCandidate(credentials: ClaudeCredentials(accessToken: "t", refreshToken: nil, expiresAt: futureMillis), source: .claudeCode)
    ])
    let claude = ClaudeProvider(credentialReader: reader, httpClient: StaticHTTPClient(status: 403, body: cloudflareBlockPage), persistRefreshed: { _ in })
    let claudeResult = runBlocking { await claude.fetchUsage() }
    guard case .failure(.blockedByEdge) = claudeResult else { throw TestFailure(description: "Claude: expected blockedByEdge, got \(claudeResult)") }

    let plain = CodexProvider(authReader: StubCodexAuth(accountID: "a"), httpClient: StaticHTTPClient(status: 403, body: Data(#"{"detail":"x"}"#.utf8)))
    let plainResult = runBlocking { await plain.fetchUsage() }
    guard case .failure(.server(statusCode: 403)) = plainResult else { throw TestFailure(description: "plain 403 stays a server error, got \(plainResult)") }
}

// MARK: - v0.4.3: credential sources are read lazily

private final class CountingClaudeReader: ClaudeCredentialReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _claudeCodeReads = 0
    var claudeCodeReads: Int { lock.withLock { _claudeCodeReads } }
    let own: ClaudeCredentials?
    let claudeCode: ClaudeCredentials

    init(own: ClaudeCredentials?, claudeCode: ClaudeCredentials) {
        self.own = own
        self.claudeCode = claudeCode
    }

    func readCredentials() throws -> ClaudeCredentials { throw UsageError.missingAuth }

    func credentialLoaders() -> [ClaudeCredentialLoader] {
        [
            ClaudeCredentialLoader(source: .claudexbar) { [own] in own },
            ClaudeCredentialLoader(source: .claudeCode) { [self] in
                lock.withLock { _claudeCodeReads += 1 }
                return claudeCode
            }
        ]
    }
}

func testWorkingOwnSessionNeverReadsClaudeCodeKeychain() throws {
    // Each read of Claude Code's Keychain item can cost a password prompt
    // (Claude Code rewriting the item resets its access list).
    let reader = CountingClaudeReader(
        own: ClaudeCredentials(accessToken: "own", refreshToken: "rt", expiresAt: futureMillis),
        claudeCode: ClaudeCredentials(accessToken: "cc", refreshToken: nil, expiresAt: futureMillis)
    )
    let http = RoutingHTTPClient(refreshStatus: 200, usageStatusByToken: ["own": 200], usageBody: try fixtureData("claude_usage"))
    let provider = ClaudeProvider(credentialReader: reader, httpClient: http, persistRefreshed: { _ in })
    for _ in 0..<5 {
        guard case .success = runBlocking({ await provider.fetchUsage() }) else { throw TestFailure(description: "own session should succeed") }
    }
    try expect(reader.claudeCodeReads == 0, "Claude Code's credential is never read while the own session works: \(reader.claudeCodeReads)")
}

func testDeadOwnSessionStillFallsBackLazily() throws {
    let reader = CountingClaudeReader(
        own: nil,
        claudeCode: ClaudeCredentials(accessToken: "cc", refreshToken: nil, expiresAt: futureMillis)
    )
    let http = RoutingHTTPClient(refreshStatus: 200, usageStatusByToken: ["cc": 200], usageBody: try fixtureData("claude_usage"))
    let provider = ClaudeProvider(credentialReader: reader, httpClient: http, persistRefreshed: { _ in })
    guard case .success = runBlocking({ await provider.fetchUsage() }) else { throw TestFailure(description: "fallback to Claude Code should succeed") }
    try expect(reader.claudeCodeReads == 1, "Claude Code's credential is read when it's actually needed")
}

// MARK: - v0.5.0: OpenRouter and OpenCode Go

func testOpenRouterParsesQuotaAndCredits() throws {
    // Shape of a real /api/v1/key + /api/v1/credits response (2026-10-30).
    let key = Data(#"{"data":{"limit":null,"limit_remaining":null,"usage":0.0009255,"is_free_tier":false,"free_model_daily_requests":{"used":0,"limit":1000,"remaining":1000}}}"#.utf8)
    let credits = Data(#"{"data":{"total_credits":10,"total_usage":0.0009255}}"#.utf8)
    let now = ISO8601DateFormatter().date(from: "2026-10-30T20:00:00Z")!
    let snapshot = try OpenRouterProvider.parseUsage(key: key, credits: credits, now: now)
    let quota = try expectNonNil(snapshot.primary, "free-model quota window")
    try expect(quota.remainingPercent == 100 && quota.windowLabel == "1d", "1000/1000 free requests left")
    try expect(quota.resetAt == ISO8601DateFormatter().date(from: "2026-10-31T00:00:00Z"), "free quota resets at 00:00 UTC")
    let balance = try expectNonNil(snapshot.secondary, "credit balance window")
    try expect(balance.windowLabel == "$10.00" && balance.remainingPercent == 99, "balance label and share: \(balance.windowLabel) \(balance.remainingPercent)")
}

func testOpenRouterPrefersKeyLimitAndPartialQuota() throws {
    let key = Data(#"{"data":{"limit":20,"limit_remaining":5,"usage":15,"free_model_daily_requests":{"used":30,"limit":50,"remaining":20}}}"#.utf8)
    let snapshot = try OpenRouterProvider.parseUsage(key: key, credits: nil, now: Date())
    try expect(snapshot.primary?.remainingPercent == 40, "20 of 50 free requests left")
    try expect(snapshot.secondary?.remainingPercent == 25 && snapshot.secondary?.windowLabel == "$5.00", "a key spending limit wins over the account balance")
    try expect((try? OpenRouterProvider.parseUsage(key: Data("{}".utf8), credits: nil, now: Date())) == nil, "garbage is a decoding error")
}

func testOpenCodeGoParsesDocumentedShape() throws {
    let body = Data(#"""
    {"usage":{"rolling":{"percent":12,"resetsAt":"2026-10-30T22:00:00Z"},
              "weekly":{"percent":8,"resetsAt":null},
              "monthly":{"percent":35,"resetsAt":"2026-11-01T00:00:00Z"}}}
    """#.utf8)
    let snapshot = try OpenCodeGoProvider.parseUsage(body, now: Date())
    try expect(snapshot.primary?.remainingPercent == 88 && snapshot.primary?.windowLabel == "5h", "rolling 5h window, percent is the share used")
    try expect(snapshot.secondary?.windowLabel == "30d" && snapshot.secondary?.remainingPercent == 65, "the tighter of weekly/monthly takes the second column")
    try expect(snapshot.extraWindows.map(\.windowLabel) == ["7d"], "the other long window goes to the tooltip")
    try expect(snapshot.primary?.resetAt == ISO8601DateFormatter().date(from: "2026-10-30T22:00:00Z"), "reset parsed")
}

func testOpenCodeGoToleratesAlternateShapes() throws {
    let capitalised = Data(#"{"Usage":{"rolling":{"percent":50,"resetsAt":null},"weekly":{"percent":10,"resetsAt":null}}}"#.utf8)
    let a = try OpenCodeGoProvider.parseUsage(capitalised, now: Date())
    try expect(a.primary?.remainingPercent == 50 && a.secondary?.windowLabel == "7d", "capitalised root key")

    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let flat = Data(#"{"rollingUsage":{"percent":20,"resetInSec":3600},"monthlyUsage":{"usagePercent":4}}"#.utf8)
    let b = try OpenCodeGoProvider.parseUsage(flat, now: now)
    try expect(b.primary?.resetAt == now.addingTimeInterval(3600), "second-based reset field")
    try expect(b.secondary?.remainingPercent == 96 && b.secondary?.windowLabel == "30d", "flat *Usage keys")
    try expect((try? OpenCodeGoProvider.parseUsage(Data(#"{"usage":{}}"#.utf8), now: now)) == nil, "no windows is a decoding error")
}

func testOpencodeKeyReaderAndDefaults() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claudexbar-oc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let auth = dir.appendingPathComponent("auth.json")
    try Data(#"{"openrouter":{"type":"api","key":" sk-or-file "}}"#.utf8).write(to: auth)

    let fromFile = OpencodeKeyReader(authURL: auth, environment: [:])
    try expect(fromFile.key(provider: "openrouter", environmentVariable: "OPENROUTER_API_KEY") == "sk-or-file", "key read from opencode's auth.json, trimmed")
    try expect(fromFile.key(provider: "opencode-go", environmentVariable: "OPENCODE_API_KEY") == nil, "absent provider -> nil")
    let fromEnv = OpencodeKeyReader(authURL: auth, environment: ["OPENROUTER_API_KEY": "sk-or-env"])
    try expect(fromEnv.key(provider: "openrouter", environmentVariable: "OPENROUTER_API_KEY") == "sk-or-env", "environment variable wins")

    try expect(!ProviderID.openrouter.enabledByDefault && !ProviderID.opencodeGo.enabledByDefault, "API-key providers are opt-in")
    try expect(ProviderID(rawValue: "opencode-go") == .opencodeGo, "stable raw value for settings")
}

func testOpenCodeGoHTTPOutcomes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claudexbar-oc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let auth = dir.appendingPathComponent("auth.json")
    try Data(#"{"opencode-go":{"type":"api","key":"sk-go"}}"#.utf8).write(to: auth)
    let reader = OpencodeKeyReader(authURL: auth, environment: [:])

    let unauthorized = OpenCodeGoProvider(keyReader: reader, httpClient: StaticHTTPClient(status: 401, body: Data()))
    guard case .failure(.authExpired) = runBlocking({ await unauthorized.fetchUsage() }) else { throw TestFailure(description: "401 -> authExpired") }

    let noKey = OpenCodeGoProvider(keyReader: OpencodeKeyReader(authURL: dir.appendingPathComponent("none.json"), environment: [:]), httpClient: StaticHTTPClient(status: 200, body: Data()))
    guard case .failure(.missingAuth) = runBlocking({ await noKey.fetchUsage() }) else { throw TestFailure(description: "no key -> missingAuth") }
}

// MARK: - v0.5.1: OpenCode Free, opencode version, aligned menu

/// The real refusal opencode stored on 2026-10-30 (trimmed).
private let realFreeTierRefusal = #"""
{"role":"assistant","providerID":"opencode","modelID":"flint-40b-free","time":{"created":1793365969598,"completed":1793366137246},
 "error":{"name":"APIError","data":{"message":"Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go",
  "statusCode":429,"isRetryable":true,"responseHeaders":{"date":"Fri, 30 Oct 2026 13:15:37 GMT","retry-after":"42127"}}}}
"""#

func testOpenCodeFreeResetFromRealRefusal() throws {
    let reset = try expectNonNil(OpenCodeFreeProvider.resetDate(fromRefusal: realFreeTierRefusal), "reset computed")
    try expect(reset == ISO8601DateFormatter().date(from: "2026-10-31T00:57:44Z"), "Date header + Retry-After: \(reset)")

    let during = OpenCodeFreeProvider.snapshot(refusalJSON: realFreeTierRefusal, now: ISO8601DateFormatter().date(from: "2026-10-30T20:21:00Z")!)
    try expect(during.primary?.remainingPercent == 0 && during.primary?.resetAt == reset, "blocked: 0% with a countdown")
    try expect(UsageFormatter.metricDisplay(for: during.primary, unavailableLabel: "free", now: ISO8601DateFormatter().date(from: "2026-10-30T20:21:00Z")!).label == "4h36m", "tray counts down to the reset")

    let after = OpenCodeFreeProvider.snapshot(refusalJSON: realFreeTierRefusal, now: ISO8601DateFormatter().date(from: "2026-10-31T01:00:00Z")!)
    try expect(after.primary?.displayValue == "ok" && UsageFormatter.percentText(for: after.primary) == "ok", "after the reset: 'ok', not an invented percentage")
    try expect(OpenCodeFreeProvider.snapshot(refusalJSON: nil, now: Date()).primary?.displayValue == "ok", "never refused: 'ok'")

    let otherProvider = realFreeTierRefusal.replacingOccurrences(of: #""providerID":"opencode""#, with: #""providerID":"openrouter""#)
    try expect(OpenCodeFreeProvider.resetDate(fromRefusal: otherProvider) == nil, "another provider's 429 is not opencode's free tier")
}

func testOpenCodeFreeReadsNewestRefusalFromDatabase() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claudexbar-ocdb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = dir.appendingPathComponent("opencode.db")
    func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
    let older = realFreeTierRefusal.replacingOccurrences(of: "42127", with: "60")
    let userText = #"{"role":"user","text":"why do I get Free usage exceeded?"}"#
    let sql = """
    CREATE TABLE message (id text primary key, session_id text, time_created integer, time_updated integer, data text);
    INSERT INTO message VALUES ('a','s',1,1,\(q(older)));
    INSERT INTO message VALUES ('b','s',2,2,\(q(realFreeTierRefusal)));
    INSERT INTO message VALUES ('c','s',3,3,\(q(userText)));
    """
    let created = runBlocking {
        await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/sqlite3"), arguments: [db.path, sql], timeout: 20)
    }
    try expect(created.succeeded, "test database created: \(created.stderr)")
    let newest = try expectNonNil(OpenCodeFreeProvider.latestRefusal(databaseURL: db), "database readable")
    try expect(newest.contains("42127"), "the newest stored refusal is used, user text mentioning the error is ignored")
    try expect(OpenCodeFreeProvider.latestRefusal(databaseURL: dir.appendingPathComponent("missing.db")) == nil, "missing database -> unreadable")
}

func testOpencodeCLIVersionAndCapabilities() throws {
    try expect(ProviderID.opencodeFree.hasCLI && !ProviderID.opencodeFree.isCodingCLI, "opencode shows a version but gets no auto-start/auto-update")
    try expect(!ProviderID.openrouter.hasCLI && !ProviderID.opencodeFree.enabledByDefault, "API rows carry no CLI; OpenCode Free is opt-in")
    let release = Data(#"{"tag_name":"v2.2.3"}"#.utf8)
    try expect(CLIVersionParser.latestVersion(provider: .opencodeFree, from: release) == "2.2.3", "opencode latest version from its GitHub release")
}

// MARK: - v0.6.1: CLI update selection

func testCLIUpdateSelectionDefaults() throws {
    let cliProviders = ProviderID.allCases.filter(\.hasCLI)
    try expect(cliProviders == [.codex, .claude, .opencodeFree], "three CLIs can be updated: \(cliProviders)")
    // Defaults: Codex and Claude Code on, opencode off (major-version jumps).
    let defaultsOn = cliProviders.filter(\.isCodingCLI)
    try expect(defaultsOn == [.codex, .claude], "auto-update defaults to Codex and Claude Code only")
    try expect(ProviderID.opencodeFree.cliName == "opencode" && ProviderID.claude.cliName == "Claude Code", "CLI names in the menu")
}

// MARK: - v0.7.0: AI Golden Hour

private var moscow: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Moscow")!
    return c
}

private func msk(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    moscow.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

func testGoldenHourDecisions() throws {
    let golden = GoldenHour(hour: 14, minute: 0)
    let five: TimeInterval = 5 * 3600
    func decide(_ now: Date) -> GoldenHourPlanner.Decision {
        GoldenHourPlanner.decide(golden: golden, windowDuration: five, now: now, calendar: moscow)
    }
    try expect(decide(msk(2, 3)) == .anchorNow, "03:00 window ends 08:00, before the 09:00 anchor: runs as usual")
    try expect(decide(msk(2, 7, 30)) == .holdUntil(msk(2, 9)), "07:30 window would still run at 09:00: hold until 09:00")
    try expect(decide(msk(2, 8)) == .holdUntil(msk(2, 9)), "08:00 would end 13:00, past 09:00: hold")
    try expect(decide(msk(2, 9, 1)) == .anchorNow, "at the anchor time: anchor")
    try expect(decide(msk(2, 11)) == .anchorNow, "late (Mac slept through 09:00): anchor right away")
    let plan = GoldenHourPlanner.anchorTime(golden, windowDuration: five, after: msk(2, 9, 1), calendar: moscow)
    try expect(plan.anchor == msk(2, 9) && plan.reset == msk(2, 14), "anchor 09:00 → reset 14:00")
    try expect(GoldenHourPlanner.nextGoldenTime(GoldenHour(hour: 0, minute: 30), after: msk(2, 23), calendar: moscow) == msk(3, 0, 30), "golden time across midnight")
}

/// Greedy chain of windows from an evening until the next golden time: every
/// window that fits runs as usual, and the last one resets exactly at golden.
private func simulateChain(golden: GoldenHour, window: TimeInterval, from start: Date) -> (resets: [Date], holds: Int) {
    var now = start
    var resets: [Date] = []
    var holds = 0
    let target = GoldenHourPlanner.nextGoldenTime(golden, after: start.addingTimeInterval(window), calendar: moscow)
    while now < target {
        switch GoldenHourPlanner.decide(golden: golden, windowDuration: window, now: now, calendar: moscow) {
        case .anchorNow:
            now = now.addingTimeInterval(window) // the window runs, then resets
            resets.append(now)
        case .holdUntil(let anchor):
            holds += 1
            now = anchor
        }
    }
    return (resets, holds)
}

func testGoldenHourChainHitsTargetWithoutSkippingWindows() throws {
    let golden = GoldenHour(hour: 14, minute: 0)
    let five = simulateChain(golden: golden, window: 5 * 3600, from: msk(1, 15))
    try expect(five.resets.last == msk(2, 14), "5 h windows: last reset lands on 14:00: \(five.resets)")
    try expect(five.resets.count == 4 && five.holds == 1, "resets 20→01→06, one hold until 09:00, then 14:00 (\(five.resets.count) resets, \(five.holds) hold)")

    // A future provider with 3-hour windows gets the same treatment.
    let three = simulateChain(golden: golden, window: 3 * 3600, from: msk(1, 15))
    try expect(three.resets.last == msk(2, 14), "3 h windows: last reset lands on 14:00: \(three.resets)")
    try expect(three.holds == 1, "only the window that can't fit is held")
}

func testGoldenHourMissDetection() throws {
    let golden = GoldenHour(hour: 14, minute: 0)
    let five: TimeInterval = 5 * 3600
    try expect(GoldenHourPlanner.isMissed(golden: golden, windowDuration: five, runningWindowResetsAt: msk(2, 12, 30), now: msk(2, 9, 30), calendar: moscow), "window running at 09:30 resetting 12:30: today is missed")
    try expect(!GoldenHourPlanner.isMissed(golden: golden, windowDuration: five, runningWindowResetsAt: msk(2, 14, 5), now: msk(2, 9, 30), calendar: moscow), "resetting within 10 min of 14:00 counts as on target")
    try expect(!GoldenHourPlanner.isMissed(golden: golden, windowDuration: five, runningWindowResetsAt: msk(2, 12, 30), now: msk(2, 8), calendar: moscow), "before the anchor time nothing is missed yet")
    try expect(GoldenHour(minutesSinceMidnight: 14 * 60 + 5).label == "14:05" && GoldenHour(minutesSinceMidnight: -10).label == "23:50", "time-of-day storage")
}

func testAutoStartCapsFollowWindowLength() throws {
    func starter(lastAttempt: Date) -> SessionAutoStarter {
        let store = InMemoryAutoStartStore()
        store.setState(AutoStartState(lastAttemptAt: lastAttempt, attemptsInLast24h: [lastAttempt]), for: .claude)
        return SessionAutoStarter(store: store)
    }
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let now = t0.addingTimeInterval(2 * 3600 + 55 * 60)
    func idle(_ duration: TimeInterval) -> UsageSnapshot {
        UsageSnapshot(primary: UsageWindow(windowLabel: "w", remainingPercent: 100, resetAt: nil, windowDuration: duration), secondary: nil, fetchedAt: now)
    }
    try expect(starter(lastAttempt: t0).evaluate(provider: .claude, snapshot: idle(3 * 3600), now: now, highConfidence: true) == .start, "3 h window: the next one may start ~3 h later")
    try expect(starter(lastAttempt: t0).evaluate(provider: .claude, snapshot: idle(5 * 3600), now: now, highConfidence: true) == .skip(reason: .cooldown), "5 h window keeps its ~5 h cooldown")
}

func testProvidersListAlphabetically() throws {
    try expect(ProviderID.displayOrder == [.claude, .codex, .opencodeFree, .opencodeGo, .openrouter],
               "menus list providers alphabetically: \(ProviderID.displayOrder.map(\.displayName))")
}

func testResetLabelsUseAbsoluteResetDates() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    try expect(UsageFormatter.resetLabel(resetAt: now.addingTimeInterval(42 * 60), now: now) == "42m", "42 minute label")
    try expect(UsageFormatter.resetLabel(resetAt: now.addingTimeInterval(4 * 60 * 60), now: now) == "4h", "4 hour label")
    try expect(UsageFormatter.resetLabel(resetAt: now.addingTimeInterval(4 * 60 * 60 + 35 * 60), now: now) == "4h35m", "4h35m label keeps the minute remainder instead of rounding down to 4h")
    try expect(UsageFormatter.resetLabel(resetAt: now.addingTimeInterval(59 * 60), now: now) == "59m", "59 minute label stays under the hour boundary")
    try expect(UsageFormatter.resetLabel(resetAt: now.addingTimeInterval(60 * 60), now: now) == "1h", "exact hour boundary has no dangling '0m'")
    try expect(UsageFormatter.resetLabel(resetAt: now.addingTimeInterval(23 * 60 * 60 + 59 * 60), now: now) == "23h59m", "just under the day boundary keeps the minute remainder")
    try expect(UsageFormatter.resetLabel(resetAt: now.addingTimeInterval(4 * 24 * 60 * 60), now: now) == "4d", "4 day label")
}

func testCountdownChangesWhenNowChangesWithoutNewFetch() throws {
    let resetAt = Date(timeIntervalSince1970: 10_000)
    let fetched = Date(timeIntervalSince1970: 8_000)
    let later = fetched.addingTimeInterval(600)
    let window = UsageWindow(windowLabel: "5h", remainingPercent: 45, resetAt: resetAt)

    try expect(UsageFormatter.display(for: window, now: fetched).label == "33m", "initial countdown label")
    try expect(UsageFormatter.display(for: window, now: later).label == "23m", "later countdown label")
}

func testFullWindowUsesWindowLabelButPartialShowsExactPercent() throws {
    let now = Date(timeIntervalSince1970: 1_000)

    // Genuinely full: window label + 100%.
    let full = UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: now.addingTimeInterval(45 * 60))
    let fullDisplay = UsageFormatter.display(for: full, now: now)
    try expect(fullDisplay.label == "5h", "full window label")
    try expect(fullDisplay.remainingPercent == 100, "full window percent")

    // 1% used: shown precisely (99%) with a reset countdown, not clamped to 100.
    let partial = UsageWindow(windowLabel: "5h", remainingPercent: 99, resetAt: now.addingTimeInterval(45 * 60))
    let partialDisplay = UsageFormatter.display(for: partial, now: now)
    try expect(partialDisplay.remainingPercent == 99, "99% shown exactly, not clamped")
    try expect(partialDisplay.label == "45m", "99% uses a reset countdown")
}

func testMissingWindowFormatsAsUnlimitedFiveHourWindow() throws {
    let display = UsageFormatter.metricDisplay(for: nil, unavailableLabel: "5h")
    try expect(display.label == "5h", "missing 5h window keeps its label")
    try expect(display.value == "∞", "missing 5h window shows unlimited")
    try expect(UsageFormatter.percentText(for: nil) == "∞", "missing menu percentage shows unlimited")
}

func testCodexUsageResponseParsing() throws {
    let data = try fixtureData("codex_usage")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = try CodexProvider.parseUsageResponse(data, fetchedAt: now)
    let primary = try expectNonNil(snapshot.primary, "Codex primary window")
    let secondary = try expectNonNil(snapshot.secondary, "Codex secondary window")

    try expect(primary.windowLabel == "5h", "Codex primary label")
    try expect(primary.remainingPercent == 93, "Codex primary remaining")
    try expect(primary.resetAt == now.addingTimeInterval(2_100), "Codex primary reset")
    try expect(secondary.windowLabel == "1w", "Codex secondary label")
    try expect(secondary.remainingPercent == 70, "Codex secondary remaining")
    try expect(secondary.resetAt == now.addingTimeInterval(395_000), "Codex secondary reset")
}

func testCodexUsageResponseParsingSupportsWeeklyOnlyWindow() throws {
    let data = try fixtureData("codex_usage_weekly_only")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = try CodexProvider.parseUsageResponse(data, fetchedAt: now)

    try expect(snapshot.primary == nil, "Codex missing 5h window stays unavailable")
    let weekly = try expectNonNil(snapshot.secondary, "Codex weekly window remains available")
    try expect(weekly.windowLabel == "1w", "Codex weekly label")
    try expect(weekly.remainingPercent == 70, "Codex weekly remaining")
    try expect(weekly.resetAt == now.addingTimeInterval(566_340), "Codex weekly reset")

    let restored = try CodexProvider.parseUsageResponse(try fixtureData("codex_usage"), fetchedAt: now)
    try expect(restored.primary != nil, "Codex 5h window restores when it returns")
}

func testCodexUsageResponseParsingSupportsGoPlanMonthlyWindow() throws {
    let data = try fixtureData("codex_usage_go_plan_check")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = try CodexProvider.parseUsageResponse(data, fetchedAt: now)

    try expect(snapshot.primary == nil, "Go plan has no 5h window")
    let monthly = try expectNonNil(snapshot.secondary, "Go plan monthly window surfaces")
    try expect(monthly.windowLabel == "30d", "Go plan window label reflects 30-day duration")
    try expect(monthly.remainingPercent == 43, "Go plan remaining percent (100 - 57)")
}

func testClaudeUsageResponseParsingUsesSevenDayFallback() throws {
    let data = try fixtureData("claude_usage")
    let snapshot = try ClaudeProvider.parseUsageResponse(data, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let primary = try expectNonNil(snapshot.primary, "Claude primary window")
    let secondary = try expectNonNil(snapshot.secondary, "Claude secondary window")

    try expect(primary.windowLabel == "5h", "Claude primary label")
    try expect(primary.remainingPercent == 88, "Claude primary remaining")
    try expect(primary.resetAt == ISO8601DateFormatter.parseClaudexDate("2026-06-03T19:00:00Z"), "Claude primary reset")
    try expect(secondary.windowLabel == "7d", "Claude secondary label")
    try expect(secondary.remainingPercent == 64, "Claude secondary remaining")
    try expect(secondary.resetAt == ISO8601DateFormatter.parseClaudexDate("2026-06-08T02:28:55Z"), "Claude secondary reset")
}

func testClaudeCredentialReaderAcceptsOAuthEnvironmentToken() throws {
    let credentials = try ClaudeCredentialReader.credentialsFromEnvironment([
        "CLAUDE_CODE_OAUTH_TOKEN": "Bearer sk-ant-oat01-test-token"
    ])

    try expect(credentials.accessToken == "sk-ant-oat01-test-token", "env token stripped")
    try expect(credentials.refreshToken == nil, "env token has no refresh token")
    try expect(credentials.expiresAt == nil, "env token has no local expiry")
}

func testPKCEChallengeMatchesRFC7636Vector() throws {
    // RFC 7636 Appendix B reference vector.
    let pkce = PKCEChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    try expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "S256 challenge matches RFC vector")
}

func testPastedCodeSplitSeparatesCodeAndState() throws {
    let split = ClaudeOAuthFlow.splitPastedCode("  AbC123def#st-9-XYZ \n")
    try expect(split.code == "AbC123def", "code parsed before #")
    try expect(split.state == "st-9-XYZ", "state parsed after #")

    let bare = ClaudeOAuthFlow.splitPastedCode("justacode")
    try expect(bare.code == "justacode", "bare code parsed")
    try expect(bare.state == nil, "bare code has no state")
}

func testAuthorizeURLUsesPlatformFlowAndProvenScopes() throws {
    let url = ClaudeOAuthFlow().authorizeURL()
    let components = try expectNonNil(URLComponents(url: url, resolvingAgainstBaseURL: false), "authorize url parses")
    let items = components.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

    try expect(url.host == "claude.com" && url.path == "/cai/oauth/authorize", "authorize endpoint is claude.com/cai")
    try expect(value("redirect_uri") == "https://platform.claude.com/oauth/code/callback", "platform-code redirect, not localhost")
    try expect(value("code_challenge_method") == "S256", "uses S256 PKCE")
    let scope = value("scope") ?? ""
    try expect(scope.contains("user:profile") && scope.contains("user:inference"), "requests usage-required scopes")
    try expect(!scope.contains("org:create_api_key"), "omits org:create_api_key (breaks the authorize request)")
}

func testTokenResponseParsingBuildsCredentialWithExpiry() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let json = Data(#"{"access_token":"sk-ant-oat01-abc","refresh_token":"sk-ant-ort01-def","expires_in":28800,"token_type":"Bearer"}"#.utf8)
    let credential = try expectNonNil(ClaudeOAuthFlow.parseTokenResponse(json, now: now), "token response parses")

    try expect(credential.accessToken == "sk-ant-oat01-abc", "access token parsed")
    try expect(credential.refreshToken == "sk-ant-ort01-def", "refresh token parsed")
    try expect(credential.expiresAt == 1_000_000 + 28_800_000, "expiry computed from expires_in")

    // The stored JSON shape must round-trip back through the credential reader.
    var oauth: [String: Any] = ["accessToken": credential.accessToken]
    oauth["refreshToken"] = credential.refreshToken
    oauth["expiresAt"] = credential.expiresAt
    let storedData = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    let reread = try expectNonNil(ClaudeCredentialReader.decodeCredentials(data: storedData), "stored credential re-reads")
    try expect(reread == credential, "stored credential round-trips")
}

func testRefreshResponseParsingRotatesRefreshTokenAndFallsBack() throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let rotated = ClaudeProvider.parseRefreshResponse(
        Data(#"{"access_token":"sk-ant-oat01-new","refresh_token":"sk-ant-ort01-new","expires_in":28800}"#.utf8),
        fallbackRefreshToken: "sk-ant-ort01-old",
        now: now
    )
    try expect(rotated?.refreshToken == "sk-ant-ort01-new", "rotated refresh token kept")

    let noRotation = ClaudeProvider.parseRefreshResponse(
        Data(#"{"access_token":"sk-ant-oat01-new"}"#.utf8),
        fallbackRefreshToken: "sk-ant-ort01-old",
        now: now
    )
    try expect(noRotation?.refreshToken == "sk-ant-ort01-old", "falls back to existing refresh token when none returned")
}

func testUsageErrorTransientClassification() throws {
    try expect(UsageError.rateLimited.isTransient, "rate limit is transient")
    try expect(UsageError.network.isTransient, "network is transient")
    try expect(UsageError.server(statusCode: 503).isTransient, "server error is transient")
    try expect(!UsageError.authExpired.isTransient, "auth expired needs attention")
    try expect(!UsageError.missingAuth.isTransient, "missing auth needs attention")
    try expect(!UsageError.decoding.isTransient, "decoding error is not transient")
}

func testUpdateCheckerVersionComparison() throws {
    try expect(UpdateChecker.isVersion("0.2.0", newerThan: "0.1.0"), "0.2.0 > 0.1.0")
    try expect(UpdateChecker.isVersion("0.10.0", newerThan: "0.9.0"), "0.10.0 > 0.9.0 (numeric, not lexical)")
    try expect(UpdateChecker.isVersion("1.0.0", newerThan: "0.99.99"), "major beats minor/patch")
    try expect(!UpdateChecker.isVersion("0.1.0", newerThan: "0.1.0"), "equal is not newer")
    try expect(!UpdateChecker.isVersion("0.1.0", newerThan: "0.2.0"), "older is not newer")
}

func testCLIVersionParsingAndAvailability() throws {
    try expect(
        CLIVersionParser.semanticVersion(in: "2.1.218 (Claude Code)") == "2.1.218",
        "Claude installed version parses"
    )
    try expect(
        CLIVersionParser.semanticVersion(in: "codex-cli 0.145.0") == "0.145.0",
        "Codex installed version parses"
    )
    try expect(
        CLIVersionParser.latestVersion(
            provider: .claude,
            from: Data(#"{"tag_name":"v2.1.219"}"#.utf8)
        ) == "2.1.219",
        "Claude GitHub release parses"
    )
    try expect(
        CLIVersionParser.latestVersion(
            provider: .codex,
            from: Data(#"{"version":"0.146.0"}"#.utf8)
        ) == "0.146.0",
        "Codex npm release parses"
    )

    let snapshot = CLIUpdateSnapshot(
        installed: [.claude: "2.1.218", .codex: "0.145.0"],
        latest: [.claude: "2.1.219", .codex: "0.145.0"]
    )
    try expect(snapshot.hasUpdate(for: .claude), "Claude update detected")
    try expect(!snapshot.hasUpdate(for: .codex), "equal Codex version is current")
    try expect(snapshot.hasAnyUpdate, "aggregate update state detected")
}

func testSecretScannerRedactsTokenShapedStringsFromLogMessages() throws {
    let leaky = "reauth produced sk-ant-oat01-AbCdEf012345_token.value and a jwt eyJhbGciOiJIUzI1.AAAABBBBCCCCDDDD"
    let redacted = SecretScanner.redact(leaky)

    try expect(SecretScanner.containsSecret(leaky), "scanner flags token-shaped input")
    try expect(!redacted.contains("sk-ant-oat01"), "redaction removes Claude token")
    try expect(redacted.range(of: "sk-ant-[A-Za-z0-9._-]{8,}", options: .regularExpression) == nil, "no token-shaped substring remains")
    try expect(!SecretScanner.containsSecret(redacted), "redacted output has no secrets")
    try expect(redacted.contains("[REDACTED]"), "redaction marks removed secrets")

    let benign = "usage ok"
    try expect(!SecretScanner.containsSecret(benign), "status strings are not flagged")
    try expect(SecretScanner.redact(benign) == benign, "status strings pass through untouched")
}

func testProviderSelectionCyclesOnlyEnabledProviders() throws {
    var selection = ProviderSelection(activeProvider: .codex, enabledProviders: [.codex, .claude])

    selection.toggleEnabled(.claude)
    try expect(selection.enabledProviders == [.codex], "Claude can be disabled")
    try expect(selection.nextProvider() == .codex, "single enabled provider does not cycle")

    selection.toggleEnabled(.claude)
    selection.activeProvider = .codex
    try expect(selection.nextProvider() == .claude, "cycles to next enabled provider")
}

func testProviderSelectionCanBeEmptyForPausedMode() throws {
    var selection = ProviderSelection(activeProvider: .claude, enabledProviders: [.claude])

    selection.toggleEnabled(.claude)

    try expect(selection.enabledProviders.isEmpty, "last provider can be disabled for paused mode")
    try expect(selection.activeProvider == .claude, "active provider remains stable while paused")
    try expect(selection.nextProvider() == .claude, "empty selection has no cycle target")
}

func makeSnapshot(remaining: Int, at fetchedAt: Date = Date(timeIntervalSince1970: 0)) -> UsageSnapshot {
    let window = UsageWindow(windowLabel: "5h", remainingPercent: remaining, resetAt: nil)
    return UsageSnapshot(primary: window, secondary: window, fetchedAt: fetchedAt)
}

func testUsageDeltaTrackerFindsSingleActiveProvider() throws {
    var tracker = UsageDeltaTracker()
    tracker.record(provider: .claude, snapshot: makeSnapshot(remaining: 90))
    tracker.record(provider: .codex, snapshot: makeSnapshot(remaining: 80))
    try expect(tracker.dominantProvider() == nil, "first snapshots produce no delta")

    tracker.record(provider: .claude, snapshot: makeSnapshot(remaining: 85))
    tracker.record(provider: .codex, snapshot: makeSnapshot(remaining: 80))
    try expect(tracker.dominantProvider() == .claude, "only Claude consumed usage")
}

func testUsageDeltaTrackerLargerDeltaWinsAndTiesDoNothing() throws {
    var tracker = UsageDeltaTracker()
    tracker.record(provider: .claude, snapshot: makeSnapshot(remaining: 90))
    tracker.record(provider: .codex, snapshot: makeSnapshot(remaining: 90))

    tracker.record(provider: .claude, snapshot: makeSnapshot(remaining: 80))
    tracker.record(provider: .codex, snapshot: makeSnapshot(remaining: 88))
    try expect(tracker.dominantProvider() == .claude, "larger delta wins when both increase")

    tracker.record(provider: .claude, snapshot: makeSnapshot(remaining: 75))
    tracker.record(provider: .codex, snapshot: makeSnapshot(remaining: 83))
    try expect(tracker.dominantProvider() == nil, "equal deltas produce no candidate")
}

func testUsageDeltaTrackerIgnoresWindowResets() throws {
    var tracker = UsageDeltaTracker()
    tracker.record(provider: .codex, snapshot: makeSnapshot(remaining: 5))
    tracker.record(provider: .codex, snapshot: makeSnapshot(remaining: 100))
    try expect(tracker.dominantProvider() == nil, "remaining going up (window reset) is not usage")
}

func testUsageDeltaTrackerIgnoresMissingPrimaryAndRebaselinesOnRestore() throws {
    let resetAt = Date(timeIntervalSince1970: 20_000)
    var tracker = UsageDeltaTracker()
    tracker.record(
        provider: .codex,
        snapshot: UsageSnapshot(
            primary: UsageWindow(windowLabel: "5h", remainingPercent: 80, resetAt: resetAt),
            secondary: nil,
            fetchedAt: Date()
        )
    )
    tracker.record(
        provider: .codex,
        snapshot: UsageSnapshot(
            primary: nil,
            secondary: UsageWindow(windowLabel: "1w", remainingPercent: 70, resetAt: resetAt),
            fetchedAt: Date()
        )
    )
    tracker.record(
        provider: .codex,
        snapshot: UsageSnapshot(
            primary: UsageWindow(windowLabel: "5h", remainingPercent: 60, resetAt: resetAt),
            secondary: nil,
            fetchedAt: Date()
        )
    )

    try expect(tracker.dominantProvider() == nil, "restored primary window starts a new delta baseline")
}

func testSmartSwitchForegroundNeedsStabilityThenSwitches() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    var engine = SmartProviderSwitchEngine(activeProvider: .codex)

    let first = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: .claude, usageDeltaProvider: nil),
        now: start
    )
    try expect(first == nil, "foreground candidate does not switch immediately")

    let flicker = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: nil, usageDeltaProvider: nil),
        now: start.addingTimeInterval(5)
    )
    try expect(flicker == nil, "losing foreground resets the debounce")

    _ = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: .claude, usageDeltaProvider: nil),
        now: start.addingTimeInterval(10)
    )
    let stable = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: .claude, usageDeltaProvider: nil),
        now: start.addingTimeInterval(21)
    )
    try expect(stable == .claude, "stable foreground switches after the debounce")
    try expect(engine.activeProvider == .claude, "engine tracks the new active provider")
}

func testSmartSwitchForegroundBeatsUsageDelta() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    var engine = SmartProviderSwitchEngine(activeProvider: .codex)

    _ = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: .claude, usageDeltaProvider: .codex),
        now: start
    )
    let stable = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: .claude, usageDeltaProvider: .codex),
        now: start.addingTimeInterval(11)
    )
    try expect(stable == .claude, "foreground wins over a conflicting usage delta")
}

func testSmartSwitchUsageDeltaSwitchesWithoutForeground() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    var engine = SmartProviderSwitchEngine(activeProvider: .codex)

    let switched = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: nil, usageDeltaProvider: .claude),
        now: start
    )
    try expect(switched == .claude, "usage delta alone switches (it is already refresh-interval slow)")

    let idle = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: nil, usageDeltaProvider: nil),
        now: start.addingTimeInterval(60)
    )
    try expect(idle == nil, "no candidate keeps the last selection")
    try expect(engine.activeProvider == .claude, "idle does not fall back anywhere")
}

func testSmartSwitchManualPinBlocksAutoSwitchTemporarily() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    var engine = SmartProviderSwitchEngine(activeProvider: .claude)

    engine.recordManualSelection(.codex, now: start)

    let blocked = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: .claude, usageDeltaProvider: nil),
        now: start.addingTimeInterval(599)
    )
    try expect(blocked == nil, "manual pin blocks auto-switch for 10 minutes")

    _ = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: .claude, usageDeltaProvider: nil),
        now: start.addingTimeInterval(601)
    )
    let afterPin = engine.evaluate(
        signals: SmartProviderSignals(foregroundProvider: .claude, usageDeltaProvider: nil),
        now: start.addingTimeInterval(612)
    )
    try expect(afterPin == .claude, "auto-switch resumes after the pin expires")
}

func testSmartProviderTextMatcherDoesNotTreatClaudexBarAsClaude() throws {
    try expect(SmartProviderTextMatcher.provider(in: ["ClaudexBar"]) == nil, "app name is not a provider")
    try expect(SmartProviderTextMatcher.provider(in: ["Claude Code"]) == .claude, "Claude Code text maps to Claude")
    try expect(SmartProviderTextMatcher.provider(in: ["/usr/local/bin/codex"]) == .codex, "codex executable maps to Codex")
}

func testThresholdCreatesOneUsageNotificationPerCooldown() throws {
    var store = NotificationCycleStore()
    let resetAt = Date(timeIntervalSince1970: 2_000)
    let window = UsageWindow(windowLabel: "5h", remainingPercent: 18, resetAt: resetAt)
    let snapshot = UsageSnapshot(primary: window, secondary: window, fetchedAt: Date())
    let evaluator = NotificationEvaluator(threshold: .twentyPercent, minimumUsageNotificationInterval: 30 * 60)

    let first = evaluator.decisions(activeProvider: .codex, snapshots: [.codex: snapshot], store: &store, now: Date(timeIntervalSince1970: 1_000))
    let soonAfter = evaluator.decisions(activeProvider: .codex, snapshots: [.codex: snapshot], store: &store, now: Date(timeIntervalSince1970: 1_100))
    let afterCooldown = evaluator.decisions(activeProvider: .codex, snapshots: [.codex: snapshot], store: &store, now: Date(timeIntervalSince1970: 2_901))

    try expect(first.count == 1, "only one threshold notification is delivered at once")
    try expect(first.first?.windowKind == .primary, "primary window is delivered first")
    try expect(soonAfter.isEmpty, "usage notifications are rate limited")
    try expect(afterCooldown.count == 1, "second window can notify after cooldown")
    try expect(afterCooldown.first?.windowKind == .secondary, "secondary window was delayed, not discarded")
}

func testMissingPrimaryWindowDoesNotNotify() throws {
    let weekly = UsageWindow(
        windowLabel: "1w",
        remainingPercent: 70,
        resetAt: Date(timeIntervalSince1970: 20_000)
    )
    let snapshot = UsageSnapshot(
        primary: nil,
        secondary: weekly,
        fetchedAt: Date(timeIntervalSince1970: 1_000)
    )
    let evaluator = NotificationEvaluator(threshold: .twentyPercent)
    var store = NotificationCycleStore()

    let decisions = evaluator.decisions(
        activeProvider: .codex,
        snapshots: [.codex: snapshot],
        store: &store,
        now: Date(timeIntervalSince1970: 1_000)
    )
    try expect(decisions.isEmpty, "missing primary window does not notify")
}

func testNotificationCooldownStartsOnlyWhenNotificationIsDelivered() throws {
    var store = NotificationCycleStore()
    let resetAt = Date(timeIntervalSince1970: 4_000)
    let healthy = UsageWindow(windowLabel: "5h", remainingPercent: 60, resetAt: resetAt)
    let low = UsageWindow(windowLabel: "5h", remainingPercent: 18, resetAt: resetAt)
    let evaluator = NotificationEvaluator(threshold: .twentyPercent, minimumUsageNotificationInterval: 30 * 60)

    let none = evaluator.decisions(
        activeProvider: .codex,
        snapshots: [.codex: UsageSnapshot(primary: healthy, secondary: healthy, fetchedAt: Date())],
        store: &store,
        now: Date(timeIntervalSince1970: 1_000)
    )
    let firstLow = evaluator.decisions(
        activeProvider: .codex,
        snapshots: [.codex: UsageSnapshot(primary: low, secondary: healthy, fetchedAt: Date())],
        store: &store,
        now: Date(timeIntervalSince1970: 1_100)
    )

    try expect(none.isEmpty, "healthy usage does not notify")
    try expect(firstLow.count == 1, "first low usage is not suppressed by a healthy refresh")
}

func testDefaultUsageNotificationCooldownIsThreeHours() throws {
    var store = NotificationCycleStore()
    let resetAt = Date(timeIntervalSince1970: 20_000)
    let primary = UsageWindow(windowLabel: "5h", remainingPercent: 18, resetAt: resetAt)
    let firstSnapshot = UsageSnapshot(primary: primary, secondary: UsageWindow(windowLabel: "7d", remainingPercent: 80, resetAt: resetAt), fetchedAt: Date())
    let secondSnapshot = UsageSnapshot(primary: primary, secondary: UsageWindow(windowLabel: "7d", remainingPercent: 12, resetAt: resetAt), fetchedAt: Date())
    let evaluator = NotificationEvaluator(threshold: .twentyPercent)

    let first = evaluator.decisions(
        activeProvider: .codex,
        snapshots: [.codex: firstSnapshot],
        store: &store,
        now: Date(timeIntervalSince1970: 1_000)
    )
    let beforeThreeHours = evaluator.decisions(
        activeProvider: .codex,
        snapshots: [.codex: secondSnapshot],
        store: &store,
        now: Date(timeIntervalSince1970: 1_000 + (3 * 60 * 60) - 1)
    )
    let afterThreeHours = evaluator.decisions(
        activeProvider: .codex,
        snapshots: [.codex: secondSnapshot],
        store: &store,
        now: Date(timeIntervalSince1970: 1_000 + (3 * 60 * 60))
    )

    try expect(first.count == 1, "first low usage notifies")
    try expect(beforeThreeHours.isEmpty, "default cooldown blocks notifications before three hours")
    try expect(afterThreeHours.count == 1, "default cooldown allows notifications after three hours")
}

func testCrossProviderHintRequiresTwentyFivePointAdvantage() throws {
    var store = NotificationCycleStore()
    let now = Date(timeIntervalSince1970: 1_000)
    let resetAt = Date(timeIntervalSince1970: 3_000)
    let low = UsageWindow(windowLabel: "5h", remainingPercent: 18, resetAt: resetAt)
    let high = UsageWindow(windowLabel: "5h", remainingPercent: 70, resetAt: resetAt)
    let codex = UsageSnapshot(primary: low, secondary: high, fetchedAt: now)
    let claude = UsageSnapshot(primary: high, secondary: high, fetchedAt: now)

    let decisions = NotificationEvaluator(threshold: .twentyPercent).decisions(
        activeProvider: .codex,
        snapshots: [.codex: codex, .claude: claude],
        store: &store,
        now: now
    )

    try expect(decisions.first?.inactiveProviderHint?.provider == .claude, "cross-provider hint provider")
    try expect(decisions.first?.inactiveProviderHint?.remainingPercent == 70, "cross-provider hint remaining")
}

func testRecoveryNotificationFiresOnceAfterDepletedWindowRestores() throws {
    var store = NotificationCycleStore()
    let evaluator = NotificationEvaluator(threshold: .twentyPercent)
    let depletedReset = Date(timeIntervalSince1970: 2_000)
    let restoredReset = Date(timeIntervalSince1970: 20_000)
    let depleted = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 0, resetAt: depletedReset),
        secondary: UsageWindow(windowLabel: "7d", remainingPercent: 80, resetAt: restoredReset),
        fetchedAt: Date(timeIntervalSince1970: 1_000)
    )
    let restored = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: restoredReset),
        secondary: UsageWindow(windowLabel: "7d", remainingPercent: 80, resetAt: restoredReset),
        fetchedAt: Date(timeIntervalSince1970: 2_100)
    )

    let beforeReset = evaluator.recoveryDecisions(
        activeProvider: .codex,
        snapshots: [.codex: depleted],
        store: &store,
        now: Date(timeIntervalSince1970: 1_000)
    )
    let afterReset = evaluator.recoveryDecisions(
        activeProvider: .codex,
        snapshots: [.codex: restored],
        store: &store,
        now: Date(timeIntervalSince1970: 2_100)
    )
    let duplicateRefresh = evaluator.recoveryDecisions(
        activeProvider: .codex,
        snapshots: [.codex: restored],
        store: &store,
        now: Date(timeIntervalSince1970: 2_200)
    )

    try expect(beforeReset.isEmpty, "depleted window only arms recovery")
    try expect(afterReset.count == 1, "restored window notifies once")
    try expect(afterReset.first?.provider == .codex, "recovery provider")
    try expect(afterReset.first?.windowKind == .primary, "recovery window kind")
    try expect(afterReset.first?.window.remainingPercent == 100, "recovery remaining percent")
    try expect(duplicateRefresh.isEmpty, "recovery is deduped for the restored cycle")
}

func testRecoveryNotificationRespectsNotificationOffSetting() throws {
    var store = NotificationCycleStore()
    let evaluator = NotificationEvaluator(threshold: .off)
    let depleted = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 0, resetAt: Date(timeIntervalSince1970: 2_000)),
        secondary: UsageWindow(windowLabel: "7d", remainingPercent: 80, resetAt: Date(timeIntervalSince1970: 20_000)),
        fetchedAt: Date(timeIntervalSince1970: 1_000)
    )
    let restored = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: Date(timeIntervalSince1970: 20_000)),
        secondary: UsageWindow(windowLabel: "7d", remainingPercent: 80, resetAt: Date(timeIntervalSince1970: 20_000)),
        fetchedAt: Date(timeIntervalSince1970: 2_100)
    )

    _ = evaluator.recoveryDecisions(
        activeProvider: .codex,
        snapshots: [.codex: depleted],
        store: &store,
        now: Date(timeIntervalSince1970: 1_000)
    )
    let afterReset = evaluator.recoveryDecisions(
        activeProvider: .codex,
        snapshots: [.codex: restored],
        store: &store,
        now: Date(timeIntervalSince1970: 2_100)
    )

    try expect(afterReset.isEmpty, "notification off suppresses recovery")
}

func testRecoveryNotificationEvaluatesAllEnabledSources() throws {
    var store = NotificationCycleStore()
    let evaluator = NotificationEvaluator(threshold: .twentyPercent)
    let depleted = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 0, resetAt: Date(timeIntervalSince1970: 2_000)),
        secondary: UsageWindow(windowLabel: "7d", remainingPercent: 80, resetAt: Date(timeIntervalSince1970: 20_000)),
        fetchedAt: Date(timeIntervalSince1970: 1_000)
    )
    let restored = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 100, resetAt: Date(timeIntervalSince1970: 20_000)),
        secondary: UsageWindow(windowLabel: "7d", remainingPercent: 80, resetAt: Date(timeIntervalSince1970: 20_000)),
        fetchedAt: Date(timeIntervalSince1970: 2_100)
    )
    let healthyCodex = UsageSnapshot(
        primary: UsageWindow(windowLabel: "5h", remainingPercent: 60, resetAt: Date(timeIntervalSince1970: 8_000)),
        secondary: UsageWindow(windowLabel: "7d", remainingPercent: 70, resetAt: Date(timeIntervalSince1970: 20_000)),
        fetchedAt: Date(timeIntervalSince1970: 2_100)
    )

    _ = evaluator.recoveryDecisions(
        sources: [
            NotificationSourceSnapshot(provider: .claude, snapshot: depleted)
        ],
        store: &store,
        now: Date(timeIntervalSince1970: 1_000)
    )
    let decisions = evaluator.recoveryDecisions(
        sources: [
            NotificationSourceSnapshot(provider: .codex, snapshot: healthyCodex),
            NotificationSourceSnapshot(provider: .claude, snapshot: restored)
        ],
        store: &store,
        now: Date(timeIntervalSince1970: 2_100)
    )

    try expect(decisions.count == 1, "recovery evaluates inactive provider source")
    try expect(decisions.first?.provider == .claude, "inactive Claude recovery provider")
}

let tests: [(String, () throws -> Void)] = [
    ("providers list alphabetically", testProvidersListAlphabetically),
    ("golden hour decisions", testGoldenHourDecisions),
    ("golden hour chain hits target without skipping windows", testGoldenHourChainHitsTargetWithoutSkippingWindows),
    ("golden hour miss detection", testGoldenHourMissDetection),
    ("auto-start caps follow window length", testAutoStartCapsFollowWindowLength),
    ("CLI update selection defaults", testCLIUpdateSelectionDefaults),
    ("OpenCode Free reset from real refusal", testOpenCodeFreeResetFromRealRefusal),
    ("OpenCode Free reads newest refusal from database", testOpenCodeFreeReadsNewestRefusalFromDatabase),
    ("opencode CLI version and capabilities", testOpencodeCLIVersionAndCapabilities),
    ("OpenRouter parses quota and credits", testOpenRouterParsesQuotaAndCredits),
    ("OpenRouter prefers key limit; partial quota", testOpenRouterPrefersKeyLimitAndPartialQuota),
    ("OpenCode Go parses documented shape", testOpenCodeGoParsesDocumentedShape),
    ("OpenCode Go tolerates alternate shapes", testOpenCodeGoToleratesAlternateShapes),
    ("opencode key reader and defaults", testOpencodeKeyReaderAndDefaults),
    ("OpenCode Go HTTP outcomes", testOpenCodeGoHTTPOutcomes),
    ("working own session never reads Claude Code keychain", testWorkingOwnSessionNeverReadsClaudeCodeKeychain),
    ("dead own session still falls back lazily", testDeadOwnSessionStillFallsBackLazily),
    ("edge block is recognised, with IP", testEdgeBlockIsRecognisedWithIP),
    ("edge block detection is narrow", testEdgeBlockDetectionIsNarrow),
    ("providers report edge block", testProvidersReportEdgeBlock),
    ("update checker targets the fork", testUpdateCheckerTargetsTheFork),
    ("update checker parses release with assets", testUpdateCheckerParsesReleaseWithAssets),
    ("update checksum verification", testUpdateChecksumVerification),
    ("dead own session falls back to fresh Claude Code login", testDeadOwnSessionFallsBackToFreshClaudeCodeLogin),
    ("Claude Code credential is never refreshed", testClaudeCodeCredentialIsNeverRefreshed),
    ("Claude Code 401 does not trigger refresh", testClaudeCode401DoesNotTriggerRefresh),
    ("full but started window shows countdown", testFullButStartedWindowShowsCountdown),
    ("unstarted window shapes still show window name", testUnstartedWindowShapesStillShowWindowName),
    ("auto-start acts on first observation after sleeping through a reset", testAutoStartActsOnFirstObservationAfterSleepingThroughReset),
    ("auto-start without a passed boundary still needs several samples", testAutoStartWithoutPassedBoundaryStillNeedsSeveralSamples),
    ("auto-start sliding provider uses passed boundary, never stores sliding reset", testAutoStartSlidingProviderUsesPassedBoundaryButNeverStoresSlidingReset),
    ("auto-start state keeps last known reset across decoding", testAutoStartStateKeepsLastKnownResetAcrossDecoding),
    ("percent mode shows used or remaining", testPercentModeShowsUsedOrRemaining),
    ("pace projects exhaustion before reset", testPaceProjectsExhaustionBeforeReset),
    ("pace: on track, and no projection without evidence", testPaceOnTrackAndInsufficientEvidence),
    ("providers report window durations", testProvidersReportWindowDurations),
    ("ProcessRunner captures exit code and streams", testProcessRunnerCapturesExitCodeAndStreams),
    ("ProcessRunner drains large output without deadlock", testProcessRunnerDrainsLargeOutputWithoutDeadlock),
    ("ProcessRunner times out and reports launch failure", testProcessRunnerTimesOutAndReportsLaunchFailure),
    ("ProcessRunner excerpt is single-line and redacted", testProcessRunnerExcerptIsSingleLineAndRedacted),
    ("auto-start launch failure rolls back and backs off", testAutoStartLaunchFailureRollsBackAndBacksOff),
    ("auto-start launch failures never trip breaker; backoff caps", testAutoStartLaunchFailuresNeverTripBreakerAndBackoffCaps),
    ("auto-start breaker auto-resets after cooling off", testAutoStartBreakerAutoResetsAfterCoolingOff),
    ("auto-start clears breaker tripped by legacy version", testAutoStartClearsBreakerTrippedByLegacyVersion),
    ("auto-start state decodes older persisted shape", testAutoStartStateDecodesOlderPersistedShape),
    ("Codex sends chatgpt-account-id when known", testCodexSendsAccountIDHeaderWhenKnown),
    ("Codex auth reader reads account_id", testCodexAuthReaderReadsAccountID),
    ("Claude refresh body escapes reserved characters", testClaudeTokenRefreshBodyEscapesReservedCharacters),
    ("auto-start detects pinned/unstarted window", testAutoStartDetectsPinnedWindow),
    ("auto-start ignores an already-ticking window", testAutoStartDoesNotFireOnTickingWindow),
    ("auto-start requires real elapsed time, not just sample count", testAutoStartRequiresMinimumSpanNotJustSampleCount),
    ("auto-start respects cooldown and daily cap", testAutoStartRespectsCooldownAndDailyCap),
    ("auto-start circuit-breaks after repeated unconfirmed attempts", testAutoStartCircuitBreaksAfterRepeatedUnconfirmedAttempts),
    ("auto-start clears stale history across a sleep/organic-reset gap", testAutoStartResetsHistoryAcrossAnOrganicWindowResetGap),
    ("auto-start detects explicit nil-resetAt signal (real Claude timeline)", testAutoStartDetectsExplicitNilResetAtSignal),
    ("auto-start does not fire on a single nil-resetAt blip", testAutoStartDoesNotFireOnSingleNilResetBlip),
    ("auto-start confirms anchor when nil-resetAt becomes real", testAutoStartConfirmsAnchorWhenNilResetBecomesReal),
    ("auto-start high-confidence fires on a single observation", testAutoStartHighConfidenceFiresOnSingleObservation),
    ("auto-start high-confidence still respects cooldown", testAutoStartHighConfidenceStillRespectsCooldown),
    ("reset labels use absolute reset dates", testResetLabelsUseAbsoluteResetDates),
    ("countdown changes without new fetch", testCountdownChangesWhenNowChangesWithoutNewFetch),
    ("full window label vs exact partial percent", testFullWindowUsesWindowLabelButPartialShowsExactPercent),
    ("missing window unlimited formatting", testMissingWindowFormatsAsUnlimitedFiveHourWindow),
    ("Codex usage response parsing", testCodexUsageResponseParsing),
    ("Codex weekly-only usage parsing", testCodexUsageResponseParsingSupportsWeeklyOnlyWindow),
    ("Codex Go-plan monthly window parsing", testCodexUsageResponseParsingSupportsGoPlanMonthlyWindow),
    ("Claude usage response parsing", testClaudeUsageResponseParsingUsesSevenDayFallback),
    ("Claude env OAuth token", testClaudeCredentialReaderAcceptsOAuthEnvironmentToken),
    ("PKCE S256 challenge", testPKCEChallengeMatchesRFC7636Vector),
    ("Pasted code split", testPastedCodeSplitSeparatesCodeAndState),
    ("Authorize URL platform flow", testAuthorizeURLUsesPlatformFlowAndProvenScopes),
    ("OAuth token response parsing", testTokenResponseParsingBuildsCredentialWithExpiry),
    ("OAuth refresh rotation", testRefreshResponseParsingRotatesRefreshTokenAndFallsBack),
    ("Usage error transient classification", testUsageErrorTransientClassification),
    ("Update version comparison", testUpdateCheckerVersionComparison),
    ("CLI version parsing and availability", testCLIVersionParsingAndAvailability),
    ("Secret scanner redaction", testSecretScannerRedactsTokenShapedStringsFromLogMessages),
    ("Provider selection model", testProviderSelectionCyclesOnlyEnabledProviders),
    ("Provider selection paused mode", testProviderSelectionCanBeEmptyForPausedMode),
    ("usage delta tracker single provider", testUsageDeltaTrackerFindsSingleActiveProvider),
    ("usage delta tracker ties and magnitude", testUsageDeltaTrackerLargerDeltaWinsAndTiesDoNothing),
    ("usage delta tracker window reset", testUsageDeltaTrackerIgnoresWindowResets),
    ("usage delta tracker missing primary", testUsageDeltaTrackerIgnoresMissingPrimaryAndRebaselinesOnRestore),
    ("smart switch foreground debounce", testSmartSwitchForegroundNeedsStabilityThenSwitches),
    ("smart switch foreground beats delta", testSmartSwitchForegroundBeatsUsageDelta),
    ("smart switch delta without foreground", testSmartSwitchUsageDeltaSwitchesWithoutForeground),
    ("smart switch manual pin", testSmartSwitchManualPinBlocksAutoSwitchTemporarily),
    ("Smart provider text matcher", testSmartProviderTextMatcherDoesNotTreatClaudexBarAsClaude),
    ("threshold notification dedupe", testThresholdCreatesOneUsageNotificationPerCooldown),
    ("missing primary window notification", testMissingPrimaryWindowDoesNotNotify),
    ("notification cooldown starts on delivery", testNotificationCooldownStartsOnlyWhenNotificationIsDelivered),
    ("default usage notification cooldown", testDefaultUsageNotificationCooldownIsThreeHours),
    ("cross-provider hint", testCrossProviderHintRequiresTwentyFivePointAdvantage),
    ("recovery notification fires once", testRecoveryNotificationFiresOnceAfterDepletedWindowRestores),
    ("recovery notification off setting", testRecoveryNotificationRespectsNotificationOffSetting),
    ("recovery notification all enabled sources", testRecoveryNotificationEvaluatesAllEnabledSources)
]

for (name, test) in tests {
    do {
        try test()
        print("PASS \(name)")
    } catch {
        print("FAIL \(name): \(error)")
        exit(1)
    }
}

print("PASS \(tests.count) ClaudexBar core tests")
