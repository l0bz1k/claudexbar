import Foundation

/// A local time of day (e.g. 14:00) at which a session window should reset
/// to 100%, every day.
public struct GoldenHour: Equatable, Sendable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = max(0, min(23, hour))
        self.minute = max(0, min(59, minute))
    }

    public init(minutesSinceMidnight: Int) {
        let m = ((minutesSinceMidnight % 1440) + 1440) % 1440
        self.init(hour: m / 60, minute: m % 60)
    }

    public var minutesSinceMidnight: Int { hour * 60 + minute }
    public var label: String { String(format: "%02d:%02d", hour, minute) }
}

/// Plans anchors so that a session window resets at the golden hour.
///
/// A window starts with the first message and resets `duration` later, so a
/// reset at golden time G needs an anchor at A = G − duration. (Anthropic
/// rounds a window's start *down* to 10 minutes, which can only move the reset
/// slightly earlier — at G the limit is still back to 100%.)
///
/// For an idle window at time `now`, with G the next golden time:
/// - a window started now that would end by A fits: anchor now, as usual —
///   earlier resets are never skipped;
/// - one that would still be running at A doesn't fit: hold until A (the only
///   case where the app deliberately waits — anchoring now would push the
///   next window past G);
/// - at or after A: anchor now (exactly on time, or late if the Mac slept
///   through A).
public enum GoldenHourPlanner {
    public enum Decision: Equatable, Sendable {
        case anchorNow
        case holdUntil(Date)
    }

    /// The next golden time strictly after `now`, in local time (DST-aware).
    public static func nextGoldenTime(_ golden: GoldenHour, after now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(
            after: now,
            matching: DateComponents(hour: golden.hour, minute: golden.minute, second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(24 * 60 * 60)
    }

    /// When to anchor so the window resets at the next golden time.
    public static func anchorTime(_ golden: GoldenHour, windowDuration: TimeInterval, after now: Date, calendar: Calendar = .current) -> (anchor: Date, reset: Date) {
        let reset = nextGoldenTime(golden, after: now, calendar: calendar)
        return (reset.addingTimeInterval(-windowDuration), reset)
    }

    public static func decide(golden: GoldenHour, windowDuration: TimeInterval, now: Date, calendar: Calendar = .current) -> Decision {
        let (anchor, _) = anchorTime(golden, windowDuration: windowDuration, after: now, calendar: calendar)
        if now >= anchor { return .anchorNow }
        // Conservative: assume no rounding, i.e. the window ends a full
        // duration from now.
        if now.addingTimeInterval(windowDuration) <= anchor { return .anchorNow }
        return .holdUntil(anchor)
    }

    /// An anchor sent more than `tolerance` after the planned anchor time
    /// (the Mac slept through it) resets that much past the golden time, so
    /// it no longer counts as hitting it.
    public static func isLateAnchor(golden: GoldenHour, windowDuration: TimeInterval, now: Date, tolerance: TimeInterval = 10 * 60, calendar: Calendar = .current) -> Bool {
        let (anchor, _) = anchorTime(golden, windowDuration: windowDuration, after: now, calendar: calendar)
        return now > anchor.addingTimeInterval(tolerance)
    }

    /// The most recent golden time whose anchor moment (anchor + tolerance)
    /// has already passed by `now`.
    public static func latestPassedTarget(_ golden: GoldenHour, windowDuration: TimeInterval, now: Date, tolerance: TimeInterval = 10 * 60, calendar: Calendar = .current) -> (anchor: Date, reset: Date)? {
        var candidate = nextGoldenTime(golden, after: now.addingTimeInterval(-3 * 24 * 60 * 60), calendar: calendar)
        var latest: (Date, Date)?
        for _ in 0..<8 {
            let anchor = candidate.addingTimeInterval(-windowDuration)
            guard anchor.addingTimeInterval(tolerance) <= now else { break }
            latest = (anchor, candidate)
            candidate = nextGoldenTime(golden, after: candidate, calendar: calendar)
        }
        return latest
    }

    /// When ClaudexBar last checked at `lastSeen` and the next check is
    /// `now`, did an anchor moment fall in between (Mac asleep, app not
    /// running)? Returns that target, which then couldn't be met on time.
    public static func sleptThroughAnchor(golden: GoldenHour, windowDuration: TimeInterval, lastSeen: Date?, now: Date, tolerance: TimeInterval = 10 * 60, calendar: Calendar = .current) -> (anchor: Date, reset: Date)? {
        // A gap longer than a day and a half is the app having been off or
        // the feature unused, not a nap — nothing to report.
        guard let lastSeen, now.timeIntervalSince(lastSeen) < 36 * 60 * 60,
              let target = latestPassedTarget(golden, windowDuration: windowDuration, now: now, tolerance: tolerance, calendar: calendar),
              lastSeen < target.anchor else { return nil }
        return target
    }

    /// True when a window that is already running at the anchor time won't
    /// reset at (or within `tolerance` of) the golden time — today's golden
    /// hour can't be reached.
    public static func isMissed(golden: GoldenHour, windowDuration: TimeInterval, runningWindowResetsAt reset: Date, now: Date, tolerance: TimeInterval = 10 * 60, calendar: Calendar = .current) -> Bool {
        let (anchor, goldenTime) = anchorTime(golden, windowDuration: windowDuration, after: now, calendar: calendar)
        guard now >= anchor else { return false }
        return abs(reset.timeIntervalSince(goldenTime)) > tolerance
    }
}
