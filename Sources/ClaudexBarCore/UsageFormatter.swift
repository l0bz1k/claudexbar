import Foundation

/// Which side of the quota a percentage describes. Anthropic's and OpenAI's
/// own UIs show *used*; ClaudexBar historically showed *remaining*.
public enum PercentMode: String, Sendable, CaseIterable {
    case remaining
    case used
}

/// Where a window is heading at the current rate of use.
public struct PaceEstimate: Equatable, Sendable {
    public let usedPercent: Int
    /// Fraction of the window's duration already elapsed, 0...1.
    public let elapsedFraction: Double
    /// When usage reaches 100% if it keeps growing at the average rate seen
    /// since the window started.
    public let projectedExhaustion: Date
    public let resetAt: Date

    /// True when, at this rate, the limit runs out before the window resets.
    public var runsOutBeforeReset: Bool { projectedExhaustion < resetAt }
}

public enum UsageFormatter {
    public static func resetLabel(resetAt: Date?, now: Date = Date(), fallback: String = "") -> String {
        guard let resetAt else { return fallback }
        let seconds = max(0, Int(resetAt.timeIntervalSince(now)))
        let minutes = seconds / 60

        if minutes < 60 {
            return "\(minutes)m"
        }

        let hours = minutes / 60
        if hours < 24 {
            let remainderMinutes = minutes % 60
            return remainderMinutes > 0 ? "\(hours)h\(remainderMinutes)m" : "\(hours)h"
        }

        return "\(hours / 24)d"
    }

    public static func display(for window: UsageWindow, now: Date = Date()) -> WindowDisplay {
        // Only a genuinely full window shows the window label and 100%; any
        // real usage (e.g. 99% remaining) is shown precisely so a refresh
        // visibly reflects it.
        if window.remainingPercent >= 100 {
            return WindowDisplay(label: window.windowLabel, remainingPercent: 100)
        }

        let label = resetLabel(resetAt: window.resetAt, now: now, fallback: window.windowLabel)
        return WindowDisplay(label: label, remainingPercent: window.remainingPercent)
    }

    public static func metricDisplay(
        for window: UsageWindow?,
        unavailableLabel: String,
        now: Date = Date(),
        mode: PercentMode = .remaining
    ) -> UsageMetricDisplay {
        guard let window else {
            return UsageMetricDisplay(label: unavailableLabel, value: "∞")
        }
        let display = display(for: window, now: now)
        let shown = mode == .used ? 100 - display.remainingPercent : display.remainingPercent
        return UsageMetricDisplay(label: display.label, value: "\(shown)%")
    }

    public static func percentText(for window: UsageWindow?, mode: PercentMode = .remaining) -> String {
        window.map { "\(mode == .used ? $0.usedPercent : $0.remainingPercent)%" } ?? "∞"
    }

    /// Minimum evidence before projecting a pace: early in a window a single
    /// prompt looks like a runaway rate, which would make the marker noisy.
    public static let paceMinimumElapsedFraction = 0.1
    public static let paceMinimumUsedPercent = 10

    /// Projects when a window runs out at its average rate so far.
    /// Returns nil when the window's timing isn't known, it hasn't started,
    /// it's already exhausted, or there isn't enough evidence yet.
    public static func pace(for window: UsageWindow?, now: Date = Date()) -> PaceEstimate? {
        guard let window,
              let resetAt = window.resetAt,
              let duration = window.windowDuration, duration > 0,
              resetAt > now
        else { return nil }

        let used = window.usedPercent
        guard used >= paceMinimumUsedPercent, used < 100 else { return nil }

        let windowStart = resetAt.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(windowStart)
        let elapsedFraction = min(1, elapsed / duration)
        guard elapsed > 0, elapsedFraction >= paceMinimumElapsedFraction else { return nil }

        let percentPerSecond = Double(used) / elapsed
        let secondsToExhaustion = Double(100 - used) / percentPerSecond
        return PaceEstimate(
            usedPercent: used,
            elapsedFraction: elapsedFraction,
            projectedExhaustion: now.addingTimeInterval(secondsToExhaustion),
            resetAt: resetAt
        )
    }

    /// One-line human explanation, for tooltips.
    public static func paceSummary(_ pace: PaceEstimate, windowName: String, now: Date = Date()) -> String {
        let elapsed = Int((pace.elapsedFraction * 100).rounded())
        let base = "\(windowName): \(pace.usedPercent)% used, \(elapsed)% of the window elapsed"
        if pace.runsOutBeforeReset {
            let runOut = resetLabel(resetAt: pace.projectedExhaustion, now: now, fallback: "soon")
            let reset = resetLabel(resetAt: pace.resetAt, now: now)
            return "\(base) — at this pace it runs out in ~\(runOut), before it resets in \(reset)."
        }
        return "\(base) — on pace to last until it resets."
    }
}
