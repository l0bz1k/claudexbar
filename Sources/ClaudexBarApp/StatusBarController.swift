import AppKit
import ClaudexBarCore
import UserNotifications

@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings = AppSettings.shared
    private let logger = SanitizedLogger.shared
    private let smartSwitchDetector = SmartProviderDetector()
    private let providers: [ProviderID: any UsageProvider] = [
        .codex: CodexProvider(),
        // Persist rotated tokens after every refresh so ClaudexBar's own
        // credential stays valid without re-login.
        .claude: ClaudeProvider(persistRefreshed: { credentials in
            try? ClaudeCredentialStore().save(credentials)
        }),
        .openrouter: OpenRouterProvider(),
        .opencodeGo: OpenCodeGoProvider(),
        .opencodeFree: OpenCodeFreeProvider()
    ]

    private var snapshots: [ProviderID: UsageSnapshot] = [:]
    private var errors: [ProviderID: UsageError] = [:]
    private var statusOverrides: [ProviderID: String] = [:]
    private var codexReauthProcess: Process?
    private var claudeReauthInProgress = false
    private var appearanceObservation: NSKeyValueObservation?
    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var smartSwitchTimer: Timer?
    private var cliUpdateCheckTimer: Timer?
    private var appUpdateCheckTimer: Timer?
    /// A newer release of this fork, shown at the top of the menu.
    private var availableUpdate: UpdateChecker.Update?
    private var updateInstallInProgress = false
    private var smartSwitchEngine: SmartProviderSwitchEngine?
    private var usageDeltaTracker = UsageDeltaTracker()
    private var refreshesInFlight: Set<ProviderID> = []
    private var presentedMenu: NSMenu?
    private var cliUpdateSnapshot: CLIUpdateSnapshot?
    private var cliUpdateCheckInProgress = false
    private var cliUpdateInProgress = false
    private var notificationStore = NotificationCycleStore()
    private var lastAuthNotificationAt: [ProviderID: Date] = [:]
    private let autoStarter = SessionAutoStarter(store: UserDefaultsAutoStartStore())
    private var autoStartInFlight: Set<ProviderID> = []
    // Once a window's resetAt is known (it's actively ticking), a one-shot
    // timer is armed for right after that boundary instead of waiting on the
    // polling-based idle heuristic to notice after the fact.
    private var scheduledResetCheckTimers: [ProviderID: Timer] = [:]
    private var goldenAnchorTimers: [ProviderID: (at: Date, timer: Timer)] = [:]
    private var goldenHoldLogged: [ProviderID: Date] = [:]
    private var scheduledResetCheckFor: [ProviderID: Date] = [:]
    private var pendingHighConfidenceCheck: Set<ProviderID> = []
    private var wakeObserver: NSObjectProtocol?
    private var providerSelection: ProviderSelection {
        get {
            ProviderSelection(activeProvider: settings.activeProvider, enabledProviders: settings.enabledProviders)
        }
        set {
            settings.activeProvider = newValue.activeProvider
            settings.enabledProviders = newValue.enabledProviders
        }
    }
    private var activeProvider: ProviderID {
        get { providerSelection.activeProvider }
        set {
            var selection = providerSelection
            selection.activeProvider = newValue
            providerSelection = selection
        }
    }

    func start() {
        AppPaths.ensureDirectories()
        AppPaths.housekeeping()
        settings.removeLegacyCodexAccountSettings()
        requestNotificationAuthorizationIfAvailable()
        smartSwitchEngine = SmartProviderSwitchEngine(activeProvider: settings.activeProvider)
        configureButton()
        observeWake()
        updateImage()
        refreshAll()
        scheduleTimers()
        configureCLIUpdates()
        checkCLIUpdatesQuietly()
        checkForUpdatesIfDue()
    }

    /// Refresh shortly after the Mac wakes instead of waiting for the next
    /// timer tick: after a long sleep every snapshot is stale, and a window
    /// may have reset overnight. The short delay lets Wi‑Fi/VPN reconnect.
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard let self else { return }
                self.logger.log(provider: self.activeProvider, message: "woke from sleep, refreshing")
                self.refreshAll()
                self.checkForUpdatesIfDue()
            }
        }
    }

    private var activeEnabledProvider: ProviderID? {
        providerSelection.enabledProviders.contains(activeProvider) ? activeProvider : nil
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // No pressed-state highlight behind the custom pill.
        (button.cell as? NSButtonCell)?.highlightsBy = []

        // Re-render the pill when the system appearance (light/dark) changes.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.updateImage() }
        }
    }

    private func scheduleTimers() {
        refreshTimer?.invalidate()
        countdownTimer?.invalidate()
        smartSwitchTimer?.invalidate()
        cliUpdateCheckTimer?.invalidate()
        appUpdateCheckTimer?.invalidate()

        // Hourly tick, daily check: the last-check time is persisted, so a
        // sleeping Mac or a relaunch doesn't reset or skip the schedule.
        appUpdateCheckTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.checkForUpdatesIfDue() }
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: settings.refreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refreshAll() }
        }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.updateImage() }
        }
        if settings.smartSwitchEnabled {
            smartSwitchTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.evaluateSmartSwitch() }
            }
        }
        cliUpdateCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.checkCLIUpdatesQuietly() }
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        switch NSApp.currentEvent?.type {
        case .rightMouseUp:
            showMenu()
        default:
            toggleProvider()
        }
    }

    private func toggleProvider() {
        let enabled = providerSelection.enabledProviders
        guard enabled.count > 1 else { return }
        let index = enabled.firstIndex(of: activeProvider) ?? -1
        let next = enabled[(index + 1) % enabled.count]
        activeProvider = next
        smartSwitchEngine?.recordManualSelection(next, now: Date())
        updateImage()
        refreshActiveProvider()
    }

    private func evaluateSmartSwitch() {
        guard settings.smartSwitchEnabled else { return }
        let enabled = Set(providerSelection.enabledProviders)
        guard enabled.count > 1 else { return }

        if smartSwitchEngine == nil {
            smartSwitchEngine = SmartProviderSwitchEngine(activeProvider: activeProvider)
        }
        if smartSwitchEngine?.activeProvider != activeProvider {
            smartSwitchEngine?.recordExternalSelection(activeProvider)
        }

        let signals = SmartProviderSignals(
            foregroundProvider: smartSwitchDetector.foregroundProvider()
                .flatMap { enabled.contains($0) ? $0 : nil },
            usageDeltaProvider: usageDeltaTracker.dominantProvider()
                .flatMap { enabled.contains($0) ? $0 : nil }
        )

        guard let provider = smartSwitchEngine?.evaluate(signals: signals, now: Date()) else { return }
        activeProvider = provider
        updateImage()
        refreshActiveProvider(notify: false)
    }

    private func refreshAll() {
        let enabled = providerSelection.enabledProviders
        guard !enabled.isEmpty else {
            updateImage()
            return
        }
        enabled.forEach { refresh(provider: $0) }
    }

    /// Manual "Refresh All": pulse the pill so the user gets clear feedback that
    /// a refresh was triggered (the data itself may be unchanged), then refetch.
    @objc private func refreshAllManually() {
        pulseRefreshIndicator()
        refreshAll()
    }

    private func pulseRefreshIndicator() {
        guard let button = statusItem.button else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            button.animator().alphaValue = 0.3
        }, completionHandler: { [weak button] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                button?.animator().alphaValue = 1.0
            }
        })
    }

    private func refresh(provider: ProviderID, notify: Bool = true) {
        guard let usageProvider = providers[provider] else { return }
        guard !refreshesInFlight.contains(provider) else { return }
        refreshesInFlight.insert(provider)
        Task {
            let result = await usageProvider.fetchUsage()
            await MainActor.run {
                refreshesInFlight.remove(provider)
                switch result {
                case .success(let snapshot):
                    snapshots[provider] = snapshot
                    errors[provider] = nil
                    usageDeltaTracker.record(provider: provider, snapshot: snapshot)
                    logger.log(provider: provider, message: "usage ok")
                    handleAutoStart(provider: provider, snapshot: snapshot)
                case .failure(let error):
                    errors[provider] = error
                    logger.log(provider: provider, message: error.sanitizedDescription)
                }
                updateImage()
                if notify {
                    evaluateNotifications()
                }
            }
        }
    }

    private func refreshActiveProvider(notify: Bool = true) {
        guard let provider = activeEnabledProvider else {
            updateImage()
            return
        }
        refresh(provider: provider, notify: notify)
    }

    /// Opt-in: when enabled for this provider and its 5-hour/monthly window
    /// looks idle/unstarted (see SessionAutoStarter), sends one trivial
    /// message through the real CLI to anchor it early. Off by default;
    /// every decision and outcome is written to the log.
    private func handleAutoStart(provider: ProviderID, snapshot: UsageSnapshot) {
        guard settings.autoStartEnabled(for: provider) else { return }

        if let resetAt = snapshot.primary?.resetAt {
            scheduleResetCheckIfNeeded(provider: provider, resetAt: resetAt)
        }

        checkGoldenHourMissed(provider: provider, snapshot: snapshot)

        guard !autoStartInFlight.contains(provider) else { return }

        let highConfidence = pendingHighConfidenceCheck.remove(provider) != nil
        let wasBroken = autoStarter.currentState(provider: provider).circuitBroken
        let decision = autoStarter.evaluate(provider: provider, snapshot: snapshot, now: Date(), highConfidence: highConfidence)
        let isBroken = autoStarter.currentState(provider: provider).circuitBroken

        // Log/notify on breaker *transitions* only — not on every poll.
        if isBroken, !wasBroken {
            logger.log(provider: provider, message: "auto-start: paused after repeated anchors that didn't start the window — re-arms in 24h or toggle off/on")
            notifyAutoStartPaused(provider: provider)
        } else if wasBroken, !isBroken {
            logger.log(provider: provider, message: "auto-start: re-armed")
        }

        guard case .start = decision else { return }

        // AI Golden Hour: a window that wouldn't end before the golden-hour
        // anchor time is held until then, so the reset lands on the golden
        // time. Windows that fit earlier run as usual.
        var goldenTarget: Date?
        if let golden = activeGoldenHour, let duration = snapshot.primary?.windowDuration {
            let now = Date()
            let plan = GoldenHourPlanner.anchorTime(golden, windowDuration: duration, after: now)
            switch GoldenHourPlanner.decide(golden: golden, windowDuration: duration, now: now) {
            case .holdUntil(let anchorAt):
                scheduleGoldenAnchor(provider: provider, at: anchorAt)
                if goldenHoldLogged[provider] != anchorAt {
                    goldenHoldLogged[provider] = anchorAt
                    logger.log(provider: provider, message: "golden hour: holding the anchor until \(Self.clock(anchorAt)) so the window resets at \(Self.clock(plan.reset))")
                }
                return
            case .anchorNow:
                if now >= plan.anchor { goldenTarget = plan.reset }
            }
        }

        autoStartInFlight.insert(provider)
        autoStarter.recordAttempt(provider: provider, now: Date())
        if let goldenTarget {
            settings.setGoldenAnchoredFor(goldenTarget, for: provider)
            logger.log(provider: provider, message: "golden hour: anchoring now for a reset at \(Self.clock(goldenTarget))")
        } else {
            logger.log(provider: provider, message: "auto-start: window looks idle, sending anchor message")
        }

        Task { [weak self] in
            let result = await SessionAutoStartRunner.run(provider: provider)
            guard let self else { return }
            await MainActor.run {
                self.autoStartInFlight.remove(provider)
                switch result {
                case .success:
                    self.autoStarter.recordLaunchSucceeded(provider: provider)
                    self.logger.log(provider: provider, message: "auto-start: anchor message sent")
                case .failure(let error):
                    self.autoStarter.recordLaunchFailed(provider: provider, now: Date())
                    let retryIn = self.autoStarter.currentState(provider: provider).retryNotBefore
                        .map { max(1, Int(($0.timeIntervalSinceNow / 60).rounded())) }
                    let retryText = retryIn.map { ", retrying in ~\($0) min" } ?? ""
                    self.logger.log(provider: provider, message: "auto-start: anchor failed (\(error))\(retryText)")
                }
            }
        }
    }

    private func notifyAutoStartPaused(provider: ProviderID) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "ClaudexBar"
        content.body = "Auto-start for \(provider.displayName) is paused: anchor messages didn’t start the 5h window. It re-arms in 24 hours, or toggle it off and on."
        let request = UNNotificationRequest(identifier: "autostart-paused-\(provider.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Arms a one-shot timer for shortly after a *known* reset boundary, so
    /// the very first check after the window actually resets happens within
    /// about a minute instead of waiting for the periodic poll cadence plus
    /// the multi-sample idle debounce to notice after the fact. Re-arming is
    /// skipped if a timer for this same boundary is already scheduled.
    private var activeGoldenHour: GoldenHour? {
        settings.goldenHourEnabled ? settings.goldenHour : nil
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// Wakes the auto-start check exactly at the golden-hour anchor time (the
    /// regular poll could be minutes late). During sleep it fires on wake.
    private func scheduleGoldenAnchor(provider: ProviderID, at anchorAt: Date) {
        if let existing = goldenAnchorTimers[provider], existing.at == anchorAt { return }
        goldenAnchorTimers[provider]?.timer.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: max(1, anchorAt.timeIntervalSinceNow + 2), repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.goldenAnchorTimers[provider] = nil
                self.performScheduledResetCheck(provider: provider)
            }
        }
        goldenAnchorTimers[provider] = (anchorAt, timer)
    }

    private func resetGoldenHourSchedule() {
        goldenAnchorTimers.values.forEach { $0.timer.invalidate() }
        goldenAnchorTimers = [:]
        goldenHoldLogged = [:]
    }

    /// At the anchor time, a window that's already running (you were working,
    /// or it started earlier) won't reset at the golden time: say so once and
    /// carry on with the regular schedule until the next day.
    private func checkGoldenHourMissed(provider: ProviderID, snapshot: UsageSnapshot) {
        let now = Date()
        guard let golden = activeGoldenHour,
              let window = snapshot.primary,
              let duration = window.windowDuration,
              let reset = window.resetAt,
              UsageFormatter.hasStarted(window, now: now) else { return }
        let plan = GoldenHourPlanner.anchorTime(golden, windowDuration: duration, after: now)
        guard now >= plan.anchor,
              settings.goldenAnchoredFor(provider) != plan.reset,
              settings.goldenMissNotifiedFor(provider) != plan.reset,
              GoldenHourPlanner.isMissed(golden: golden, windowDuration: duration, runningWindowResetsAt: reset, now: now) else { return }
        settings.setGoldenMissNotifiedFor(plan.reset, for: provider)
        logger.log(provider: provider, message: "golden hour: \(Self.clock(plan.reset)) not reachable today — the running window resets at \(Self.clock(reset))")
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "AI Golden Hour"
        content.body = "\(provider.displayName) can’t reset at \(Self.clock(plan.reset)) today: a window is already running and resets at \(Self.clock(reset)). Back on schedule tomorrow."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "golden-miss-\(provider.rawValue)", content: content, trigger: nil))
    }

    private func scheduleResetCheckIfNeeded(provider: ProviderID, resetAt: Date) {
        if let already = scheduledResetCheckFor[provider], abs(already.timeIntervalSince(resetAt)) < 5 {
            return
        }
        scheduledResetCheckTimers[provider]?.invalidate()
        scheduledResetCheckFor[provider] = resetAt

        let fireAt = resetAt.addingTimeInterval(65)
        let delay = max(1, fireAt.timeIntervalSinceNow)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.performScheduledResetCheck(provider: provider) }
        }
        scheduledResetCheckTimers[provider] = timer
        logger.log(provider: provider, message: "auto-start: scheduled idle check ~1min after \(resetAt)")
    }

    /// Fired by the scheduled timer above: an immediate, out-of-cadence
    /// refresh whose auto-start evaluation is high-confidence (a single idle
    /// observation is trusted, since this check was deliberately timed to
    /// land right after a known boundary rather than an arbitrary poll).
    private func performScheduledResetCheck(provider: ProviderID) {
        scheduledResetCheckTimers[provider] = nil
        guard settings.autoStartEnabled(for: provider) else { return }
        pendingHighConfidenceCheck.insert(provider)
        refresh(provider: provider, notify: false)
    }

    private func updateImage() {
        guard let button = statusItem.button else { return }
        button.toolTip = nil
        guard !providerSelection.enabledProviders.isEmpty else {
            button.image = StatusPillRenderer.pausedImage()
            return
        }

        // A status override (e.g. "login" during re-auth) always wins.
        if let override = statusOverrides[activeProvider] {
            button.image = StatusPillRenderer.image(provider: activeProvider, status: override)
            return
        }

        // Keep showing the last good usage on transient errors (rate limit /
        // network blip); only fall back to a status word when there is no
        // snapshot yet, or the error needs the user's attention (auth, parse).
        let error = errors[activeProvider]
        if let snapshot = snapshots[activeProvider], error == nil || error!.isTransient {
            let now = Date()
            button.image = StatusPillRenderer.image(
                provider: activeProvider,
                snapshot: snapshot,
                now: now,
                mode: settings.percentMode,
                sessionPaceWarning: settings.paceWarningSession,
                longPaceWarning: settings.paceWarningLong
            )
            button.toolTip = tooltip(for: activeProvider, snapshot: snapshot, now: now)
            return
        }

        button.image = StatusPillRenderer.image(provider: activeProvider, status: error?.statusLabel ?? "wait")
        button.toolTip = error.map { "\(activeProvider.displayName): \($0.sanitizedDescription)" }
    }

    /// Hover text: what each figure means (so remaining vs used can't be
    /// misread) plus the pace projection behind any ▲ marker.
    private func tooltip(for provider: ProviderID, snapshot: UsageSnapshot, now: Date) -> String {
        let side = settings.percentMode == .used ? "used" : "left"
        var lines = [provider.displayName]
        let secondaryName = ["7d", "1w"].contains(snapshot.secondary?.windowLabel ?? "") ? "Weekly" : "Quota"
        let windows: [(String, UsageWindow?)] = [("Session", snapshot.primary), (secondaryName, snapshot.secondary)]
            + snapshot.extraWindows.map { ("", $0) }
        for (fallbackName, window) in windows {
            guard let window else { continue }
            let name = window.title ?? "\(fallbackName) (\(window.windowLabel))"
            let percent = settings.percentMode == .used ? window.usedPercent : window.remainingPercent
            let reset = window.resetAt.map { " · resets in \(UsageFormatter.resetLabel(resetAt: $0, now: now))" } ?? ""
            lines.append("\(name): \(percent)% \(side)\(reset)")
            if let pace = UsageFormatter.pace(for: window, now: now) {
                lines.append("   " + UsageFormatter.paceSummary(pace, windowName: name, now: now))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func showMenu() {
        let menu = NSMenu()
        if let update = availableUpdate, update.isNewer {
            let item = NSMenuItem(title: "", action: #selector(presentAvailableUpdate), keyEquivalent: "", target: self)
            item.attributedTitle = NSAttributedString(
                string: updateInstallInProgress ? "⬆  Installing \(update.latest)…" : "⬆  Update to \(update.latest)…",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .semibold)]
            )
            item.isEnabled = !updateInstallInProgress
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let rows = ProviderID.allCases.map { (label: $0.displayName, version: providerVersionBadge($0), hint: providerStatusHint($0)) }
        let layout = ProviderRowLayout.make(rows: rows)
        ProviderID.allCases.forEach { appendProviderRow(to: menu, provider: $0, layout: layout) }
        menu.addItem(.separator())

        // "Refresh All" by default; holding Option swaps it for "Open Logs…"
        // (native alternate item), keeping maintenance actions out of the way.
        menu.addItem(NSMenuItem(title: "Refresh All", action: #selector(refreshAllManually), keyEquivalent: "", target: self))
        let logs = NSMenuItem(title: "Open Logs…", action: #selector(openLogs), keyEquivalent: "", target: self)
        logs.isAlternate = true
        logs.keyEquivalentModifierMask = .option
        menu.addItem(logs)

        menu.addItem(toggleItem(title: "Smart Auto Switch", isOn: settings.smartSwitchEnabled, action: #selector(toggleSmartSwitch)))
        menu.addItem(autoStartMenu())
        menu.addItem(displayMenu())
        menu.addItem(toggleItem(title: "Launch at Login", isOn: LaunchAgentManager.isEnabled(), action: #selector(toggleLaunchAtLogin)))
        menu.addItem(refreshIntervalMenu())
        menu.addItem(notificationMenu())
        menu.addItem(.separator())
        menu.addItem(cliUpdateMenu())
        menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "", target: self))
        // Hold Option to reveal a notification self-test in its place.
        let testNotif = NSMenuItem(title: "Send Test Notification", action: #selector(sendTestNotification), keyEquivalent: "", target: self)
        testNotif.isAlternate = true
        testNotif.keyEquivalentModifierMask = .option
        menu.addItem(testNotif)
        menu.addItem(NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "", target: self))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q", target: self))

        // Attach the menu to the status item and click it: macOS positions it
        // correctly under the pill (it also draws its standard selection
        // highlight, which is the expected menu-bar behavior).
        statusItem.menu = menu
        presentedMenu = menu
        statusItem.button?.performClick(nil)
        presentedMenu = nil
        statusItem.menu = nil
    }

    /// Provider row: a custom view that toggles the provider's enabled state
    /// **without closing the menu** (settings-checklist feel). Holding Option
    /// swaps it (native alternate item) for that provider's "Re-auth" action.
    private func appendProviderRow(to menu: NSMenu, provider: ProviderID, layout: ProviderRowLayout) {
        let row = NSMenuItem()
        row.view = ProviderToggleView(
            label: provider.displayName,
            version: providerVersionBadge(provider),
            hint: providerStatusHint(provider),
            layout: layout,
            isEnabled: { [weak self] in self?.providerSelection.enabledProviders.contains(provider) ?? false },
            onToggle: { [weak self] in self?.toggleProviderEnabled(provider) }
        )
        menu.addItem(row)

        let reauth = NSMenuItem(title: "Re-auth \(provider.displayName)", action: #selector(reauthProvider(_:)), keyEquivalent: "")
        reauth.target = self
        reauth.representedObject = provider.rawValue
        reauth.isAlternate = true
        reauth.keyEquivalentModifierMask = .option
        menu.addItem(reauth)
    }

    /// Inline status shown after the provider name: remaining percentages when
    /// usage is available, otherwise a status word (`login`/`auth`/`net`/`err`).
    private func providerStatusHint(_ provider: ProviderID) -> ProviderRowHint {
        if let override = statusOverrides[provider] {
            return .status(override)
        }
        if let snapshot = snapshots[provider], errors[provider] == nil {
            let first = UsageFormatter.percentText(for: snapshot.primary, mode: settings.percentMode)
            if snapshot.secondary == nil, provider == .opencodeFree {
                return .figure(first) // a single window: no second column
            }
            return ProviderRowHint(primary: first, secondary: UsageFormatter.percentText(for: snapshot.secondary, mode: settings.percentMode))
        }
        if let error = errors[provider] { return .status(error.statusLabel) }
        return .status("wait")
    }

    private func providerVersionBadge(_ provider: ProviderID) -> ProviderVersionBadge? {
        guard let updateSnapshot = cliUpdateSnapshot,
              let installed = updateSnapshot.installed[provider] else {
            return nil
        }
        let state: ProviderVersionState
        if updateSnapshot.latest[provider] == nil {
            state = .unknown
        } else if updateSnapshot.hasUpdate(for: provider) {
            state = .outdated
        } else {
            state = .current
        }
        return ProviderVersionBadge(text: "v\(installed)", state: state)
    }

    private func refreshIntervalMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Refresh Interval", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        [60, 300, 600, 900].forEach { seconds in
            let title: String
            switch seconds {
            case 60: title = "1 minute"
            case 300: title = "5 minutes"
            case 600: title = "10 minutes"
            default: title = "15 minutes"
            }
            let item = NSMenuItem(title: title, action: #selector(selectRefreshInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = Int(settings.refreshInterval) == seconds ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func autoStartMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Auto-start 5h Session", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        [ProviderID.codex, ProviderID.claude].forEach { provider in
            let state = autoStarter.currentState(provider: provider)
            let enabled = settings.autoStartEnabled(for: provider)
            // The mechanism only ever targets the primary/short window (see
            // SessionAutoStarter): that's the genuinely time-sensitive one.
            // Some plans (e.g. Codex on ChatGPT Go) have no such window at
            // all — only a monthly quota — where "starting it a bit earlier"
            // saves nothing worth the automated message. Reflect that in the
            // menu instead of offering a toggle that would silently never fire.
            let hasPrimaryWindow = snapshots[provider]?.primary != nil
            let item = NSMenuItem(title: provider.displayName, action: #selector(toggleAutoStart(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = provider.rawValue

            if !hasPrimaryWindow, errors[provider] == nil {
                item.title = "\(provider.displayName) (no 5h window on this plan)"
                item.isEnabled = false
                item.state = .off
            } else {
                item.title = enabled && state.circuitBroken
                    ? "\(provider.displayName) (paused — re-arms within 24h)"
                    : provider.displayName
                item.state = enabled ? .on : .off
            }
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        submenu.addItem(toggleItem(title: "AI Golden Hour", isOn: settings.goldenHourEnabled, action: #selector(toggleGoldenHour)))
        submenu.addItem(NSMenuItem(
            title: settings.goldenHour.map { "Golden Hour: \($0.label)…" } ?? "Set Golden Hour…",
            action: #selector(chooseGoldenHour),
            keyEquivalent: "",
            target: self
        ))
        if let golden = activeGoldenHour {
            for provider in ProviderID.allCases where settings.autoStartEnabled(for: provider) {
                guard let duration = snapshots[provider]?.primary?.windowDuration else { continue }
                let plan = GoldenHourPlanner.anchorTime(golden, windowDuration: duration, after: Date())
                let line = NSMenuItem(title: "\(provider.displayName): anchor \(Self.clock(plan.anchor)) → 100% at \(Self.clock(plan.reset))", action: nil, keyEquivalent: "")
                line.isEnabled = false
                line.indentationLevel = 1
                submenu.addItem(line)
            }
        }

        submenu.addItem(.separator())
        let note = NSMenuItem(
            title: "Sends one CLI message when idle. Off by default.",
            action: nil,
            keyEquivalent: ""
        )
        note.isEnabled = false
        submenu.addItem(note)

        parent.submenu = submenu
        return parent
    }

    @objc private func toggleGoldenHour() {
        if !settings.goldenHourEnabled, settings.goldenHour == nil {
            chooseGoldenHour() // picking a time turns it on
            return
        }
        settings.goldenHourEnabled.toggle()
        if settings.goldenHourEnabled { enableAutoStartForGoldenHour() }
        resetGoldenHourSchedule()
        logger.log(provider: activeProvider, message: "golden hour: \(settings.goldenHourEnabled ? "on at \(settings.goldenHour?.label ?? "?")" : "off")")
        refreshAll()
    }

    @objc private func chooseGoldenHour() {
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        // Suggest the earliest time that can shift the next reset: 5 h + 1 min.
        picker.dateValue = Date().addingTimeInterval(5 * 60 * 60 + 60)

        let alert = NSAlert()
        alert.messageText = "AI Golden Hour"
        alert.informativeText = "Every day at this time, session limits come back to 100%.\n\n"
            + "A window resets a fixed time after it starts (5 h for Claude), so ClaudexBar anchors it that much earlier. "
            + "Windows that fit before then still run as usual; if this time is less than a window away, it starts working tomorrow.\n\n"
            + "Tip: a time on a 10-minute mark (14:00, 14:10) lands exactly; otherwise the reset comes a few minutes early."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let components = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
        settings.goldenHour = GoldenHour(hour: components.hour ?? 0, minute: components.minute ?? 0)
        settings.goldenHourEnabled = true
        enableAutoStartForGoldenHour()
        resetGoldenHourSchedule()
        logger.log(provider: activeProvider, message: "golden hour: on at \(settings.goldenHour?.label ?? "?")")
        refreshAll()
    }

    /// Golden Hour works through the auto-start anchor; if no provider has it
    /// on, turn it on for those with a session window.
    private func enableAutoStartForGoldenHour() {
        let eligible = ProviderID.allCases.filter { $0.isCodingCLI && snapshots[$0]?.primary?.windowDuration != nil }
        guard !eligible.contains(where: { settings.autoStartEnabled(for: $0) }) else { return }
        eligible.forEach { settings.setAutoStartEnabled(true, for: $0) }
    }

    @objc private func toggleAutoStart(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = ProviderID(rawValue: raw) else { return }
        let newValue = !settings.autoStartEnabled(for: provider)
        settings.setAutoStartEnabled(newValue, for: provider)
        // Toggling off-then-on is the documented way to clear a tripped
        // circuit breaker and start detection fresh.
        autoStarter.resetCircuitBreaker(provider: provider)
        if !newValue {
            scheduledResetCheckTimers[provider]?.invalidate()
            scheduledResetCheckTimers[provider] = nil
            scheduledResetCheckFor[provider] = nil
            pendingHighConfidenceCheck.remove(provider)
        }
        logger.log(provider: provider, message: "auto-start: \(newValue ? "enabled" : "disabled")")
    }

    private func notificationMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Notify When Remaining", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        [
            ("20%", NotificationThreshold.twentyPercent),
            ("10%", NotificationThreshold.tenPercent),
            ("Off", NotificationThreshold.off)
        ].forEach { title, threshold in
            let item = NSMenuItem(title: title, action: #selector(selectNotificationThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = threshold.rawValue
            item.state = settings.notificationThreshold == threshold ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func cliUpdateMenu() -> NSMenuItem {
        let title: String
        if cliUpdateInProgress {
            title = "CLI Updates · Updating…"
        } else if cliUpdateSnapshot?.hasAnyUpdate == true {
            title = "CLI Updates · Available"
        } else {
            title = "CLI Updates"
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let automatic = toggleItem(
            title: "Daily Auto-update",
            isOn: settings.automaticCLIUpdatesEnabled,
            action: #selector(toggleAutomaticCLIUpdates)
        )
        submenu.addItem(automatic)
        submenu.addItem(.separator())

        // Which CLIs "Update Selected" and the daily auto-update may touch.
        let header = NSMenuItem(title: "Update these CLIs:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        submenu.addItem(header)
        for provider in ProviderID.allCases where provider.hasCLI {
            let item = NSMenuItem(title: provider.cliName, action: #selector(toggleCLIUpdateAllowed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = provider.rawValue
            item.state = settings.cliUpdateAllowed(for: provider) ? .on : .off
            item.indentationLevel = 1
            submenu.addItem(item)
        }
        submenu.addItem(.separator())

        let selected = settings.cliUpdateProviders
        let updateTitle = cliUpdateInProgress ? "Updating Selected CLIs…" : "Update Selected CLIs Now"
        let update = NSMenuItem(title: updateTitle, action: #selector(updateCLIsManually), keyEquivalent: "")
        update.target = self
        update.isEnabled = !cliUpdateInProgress
            && !cliUpdateCheckInProgress
            && !selected.isEmpty
            && selected.contains { cliUpdateSnapshot?.installed[$0] != nil }
        submenu.addItem(update)

        parent.submenu = submenu
        return parent
    }

    private func cliVersionLabel(_ provider: ProviderID) -> String {
        guard let snapshot = cliUpdateSnapshot else {
            return "\(provider.cliName) · checking…"
        }
        guard let installed = snapshot.installed[provider] else {
            return "\(provider.cliName) · not found"
        }
        guard let latest = snapshot.latest[provider] else {
            return "\(provider.cliName) \(installed) · check unavailable"
        }
        if snapshot.hasUpdate(for: provider) {
            return "\(provider.cliName) \(installed) → \(latest)"
        }
        return "\(provider.cliName) \(installed) · current"
    }

    private func toggleItem(title: String, isOn: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        return item
    }

    private func toggleProviderEnabled(_ provider: ProviderID) {
        let wasPaused = activeEnabledProvider == nil
        var selection = providerSelection
        selection.toggleEnabled(provider)
        providerSelection = selection
        if wasPaused, providerSelection.enabledProviders.contains(provider) {
            activeProvider = provider
        }
        if activeEnabledProvider != nil {
            smartSwitchEngine?.recordExternalSelection(activeProvider)
        }
        updateImage()
        scheduleTimers()
        if providerSelection.enabledProviders.contains(provider) {
            refresh(provider: provider)
        }
    }

    @objc private func selectRefreshInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        settings.refreshInterval = TimeInterval(seconds)
        scheduleTimers()
    }

    @objc private func selectNotificationThreshold(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let threshold = NotificationThreshold(rawValue: raw)
        else { return }
        settings.notificationThreshold = threshold
    }

    @objc private func reauthProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = ProviderID(rawValue: raw) else { return }
        switch provider {
        case .codex: reauthCodex()
        case .claude: reauthClaude()
        case .openrouter, .opencodeGo, .opencodeFree:
            // The key lives in opencode's auth store; `opencode auth login`
            // (re)adds it. The next poll picks it up.
            runInTerminal(providers[provider]?.reauthCommand())
        }
    }

    private func reauthCodex() {
        runCodexReauth()
    }

    private func runCodexReauth() {
        guard codexReauthProcess == nil else { return }
        guard let executableURL = codexExecutableURL() else {
            errors[.codex] = .authExpired
            notifyReauthFailed(provider: .codex, reason: "codex_not_found")
            updateImage()
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["login"]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["CODEX_HOME": FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path]
        ) { _, new in new }
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let authURLOpener = CodexAuthURLOpener()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in authURLOpener.handle(handle.availableData) }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in authURLOpener.handle(handle.availableData) }

        codexReauthProcess = process
        statusOverrides[.codex] = "login"
        errors[.codex] = nil
        updateImage()

        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                self.codexReauthProcess = nil
                self.statusOverrides[.codex] = nil
                if process.terminationStatus == 0 {
                    self.refresh(provider: .codex)
                } else {
                    self.errors[.codex] = .authExpired
                    self.notifyReauthFailed(provider: .codex, reason: "login_exit_\(process.terminationStatus)")
                    self.updateImage()
                }
            }
        }

        do {
            try process.run()
        } catch {
            codexReauthProcess = nil
            statusOverrides[.codex] = nil
            errors[.codex] = .authExpired
            notifyReauthFailed(provider: .codex, reason: "login_start_failed")
            updateImage()
        }
    }

    private func codexExecutableURL() -> URL? {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Users/ipang/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func reauthClaude() {
        runClaudeReauth()
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAgentManager.setEnabled(!LaunchAgentManager.isEnabled())
    }

    @objc private func toggleSmartSwitch() {
        settings.smartSwitchEnabled.toggle()
        if settings.smartSwitchEnabled {
            smartSwitchEngine = SmartProviderSwitchEngine(activeProvider: activeProvider)
            evaluateSmartSwitch()
        }
        scheduleTimers()
    }

    private func configureCLIUpdates() {
        CLIUpdateScheduler.setEnabled(settings.automaticCLIUpdatesEnabled)
    }

    @objc private func toggleAutomaticCLIUpdates() {
        settings.automaticCLIUpdatesEnabled.toggle()
        CLIUpdateScheduler.setEnabled(settings.automaticCLIUpdatesEnabled)
    }

    private func checkCLIUpdatesQuietly() {
        guard !cliUpdateCheckInProgress, !cliUpdateInProgress else { return }
        cliUpdateCheckInProgress = true
        Task { [weak self] in
            let snapshot = await CLIUpdateManager.shared.snapshot()
            guard let self else { return }
            await MainActor.run {
                self.cliUpdateSnapshot = snapshot
                self.cliUpdateCheckInProgress = false
            }
        }
    }

    @objc private func toggleCLIUpdateAllowed(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = ProviderID(rawValue: raw) else { return }
        settings.setCLIUpdateAllowed(!settings.cliUpdateAllowed(for: provider), for: provider)
    }

    @objc private func updateCLIsManually() {
        guard !cliUpdateInProgress, !cliUpdateCheckInProgress else { return }
        cliUpdateInProgress = true
        let selected = settings.cliUpdateProviders
        Task { [weak self] in
            let results = await CLIUpdateManager.shared.updateAll(providers: selected)
            let snapshot = await CLIUpdateManager.shared.snapshot()
            guard let self else { return }
            await MainActor.run {
                self.cliUpdateInProgress = false
                self.cliUpdateSnapshot = snapshot
                self.showCLIUpdateResult(results)
            }
        }
    }

    private func showCLIUpdateResult(_ results: [CLICommandResult]) {
        NSApp.activate(ignoringOtherApps: true)
        let failures = results.filter { !$0.succeeded }
        let alert = NSAlert()
        alert.messageText = failures.isEmpty ? "CLI update complete" : "Some CLI updates failed"
        alert.informativeText = results.map { result in
            let outcome = result.succeeded ? "updated" : "failed"
            return "\(result.provider.cliName): \(outcome)\n\(cliVersionLabel(result.provider))"
        }.joined(separator: "\n\n")
        alert.alertStyle = failures.isEmpty ? .informational : .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func displayMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(toggleItem(title: "Show Used % (like Claude / ChatGPT)", isOn: settings.percentMode == .used, action: #selector(togglePercentMode)))
        submenu.addItem(toggleItem(title: "Pace Warning \(StatusPillRenderer.paceMarker): Session (5h)", isOn: settings.paceWarningSession, action: #selector(toggleSessionPaceWarning)))
        submenu.addItem(toggleItem(title: "Pace Warning \(StatusPillRenderer.paceMarker): Weekly / Monthly", isOn: settings.paceWarningLong, action: #selector(toggleLongPaceWarning)))
        submenu.addItem(.separator())
        let note = NSMenuItem(title: "\(StatusPillRenderer.paceMarker) = at this rate, runs out before reset", action: nil, keyEquivalent: "")
        note.isEnabled = false
        submenu.addItem(note)
        parent.submenu = submenu
        return parent
    }

    @objc private func togglePercentMode() {
        settings.percentMode = settings.percentMode == .used ? .remaining : .used
        updateImage()
    }

    @objc private func toggleSessionPaceWarning() {
        settings.paceWarningSession.toggle()
        updateImage()
    }

    @objc private func toggleLongPaceWarning() {
        settings.paceWarningLong.toggle()
        updateImage()
    }

    @objc private func copyDiagnostics() {
        let report = DiagnosticsReport.make(
            settings: settings,
            snapshots: snapshots,
            errors: errors,
            activeProvider: activeProvider,
            autoStarter: autoStarter
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        logger.log(provider: activeProvider, message: "diagnostics copied to clipboard")
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(AppPaths.logs)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func runInTerminal(_ command: ShellCommand?) {
        guard let command else { return }
        let script = """
        tell application "Terminal"
          activate
          do script "\(command.terminalCommand.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }

    /// Runs Claude's OAuth Authorization-Code + PKCE flow. ClaudexBar opens the
    /// browser to Claude's sign-in page; after the user approves, Claude's
    /// callback page shows a `code#state` string. The user pastes it into a
    /// ClaudexBar dialog, and ClaudexBar exchanges it for an independent
    /// access+refresh credential (full scopes) stored only in the Keychain.
    /// Claude's OAuth client does not accept a localhost redirect, so this
    /// one paste is required; the code and tokens are never logged.
    private func runClaudeReauth() {
        guard !claudeReauthInProgress else { return }

        let flow = ClaudeOAuthFlow()
        NSWorkspace.shared.open(flow.authorizeURL())
        logger.log(provider: .claude, message: "reauth started")

        guard let pasted = promptForClaudeCode() else {
            logger.log(provider: .claude, message: "reauth cancelled")
            return
        }

        claudeReauthInProgress = true
        statusOverrides[.claude] = "login"
        errors[.claude] = nil
        updateImage()

        Task { [weak self] in
            let result = await flow.submitCode(pasted)
            guard let self else { return }
            await MainActor.run {
                self.claudeReauthInProgress = false
                self.statusOverrides[.claude] = nil
                switch result {
                case .success:
                    self.logger.log(provider: .claude, message: "reauth ok")
                    self.refresh(provider: .claude)
                case .failure(let error):
                    self.errors[.claude] = .authExpired
                    let reason = Self.reasonLabel(error)
                    self.logger.log(provider: .claude, message: "reauth failed: \(reason)")
                    self.notifyReauthFailed(provider: .claude, reason: reason)
                    self.updateImage()
                }
            }
        }
    }

    /// Shows a modal dialog for the user to paste the `code#state` shown on
    /// Claude's callback page. Pre-fills from the clipboard when it looks like
    /// a code so the common case is one click.
    private func promptForClaudeCode() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Finish Claude Code sign-in"
        alert.informativeText = "Your browser opened the Claude sign-in page. Approve access, copy the code shown on the page, and paste it here."
        alert.addButton(withTitle: "Submit")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Paste the code"
        if let clip = NSPasteboard.general.string(forType: .string),
           clip.contains("#"), !clip.contains(" "), clip.count < 200 {
            field.stringValue = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let code = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }

    private static func reasonLabel(_ error: ClaudeOAuthFlow.FlowError) -> String {
        switch error {
        case .emptyCode: return "empty_code"
        case .stateMismatch: return "state_mismatch"
        case .network: return "network"
        case .exchange(let status): return "exchange_http_\(status)"
        case .parse: return "parse"
        case .keychain: return "keychain"
        }
    }

    private func evaluateNotifications() {
        guard notificationsAvailable else { return }
        guard activeEnabledProvider != nil else { return }
        let evaluator = NotificationEvaluator(threshold: settings.notificationThreshold)
        let decisions = evaluator.decisions(
            activeProvider: activeProvider,
            snapshots: snapshots,
            store: &notificationStore,
            now: Date()
        )
        decisions.forEach(sendNotification)
        let recoveryDecisions = evaluator.recoveryDecisions(
            sources: recoveryNotificationSources(),
            store: &notificationStore,
            now: Date()
        )
        recoveryDecisions.forEach(sendRecoveryNotification)

        if let error = errors[activeProvider], error.statusLabel == "auth" {
            sendAuthNotification(provider: activeProvider)
        }
    }

    private func sendNotification(_ decision: NotificationDecision) {
        let content = UNMutableNotificationContent()
        content.title = "ClaudexBar"
        let reset = UsageFormatter.resetLabel(resetAt: decision.window.resetAt, fallback: decision.window.windowLabel)
        let windowName = decision.windowKind == .primary ? "5h" : "weekly"
        var body = "\(decision.provider.displayName) \(windowName): \(decision.window.remainingPercent)% left, resets in \(reset)."
        if let hint = decision.inactiveProviderHint {
            body += " \(hint.provider.displayName): \(hint.remainingPercent)% left."
        }
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func sendRecoveryNotification(_ decision: RecoveryNotificationDecision) {
        let content = UNMutableNotificationContent()
        content.title = "ClaudexBar"
        let windowName = decision.windowKind == .primary ? "5h" : "weekly"
        content.body = "\(decision.provider.displayName) \(windowName) limit is back. You have \(decision.window.remainingPercent)% available."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        logger.log(provider: decision.provider, message: "recovery notification sent \(windowName) \(decision.window.remainingPercent)%")
    }

    private func recoveryNotificationSources() -> [NotificationSourceSnapshot] {
        providerSelection.enabledProviders.compactMap { provider in
            snapshots[provider].map { NotificationSourceSnapshot(provider: provider, snapshot: $0) }
        }
    }

    private func sendAuthNotification(provider: ProviderID) {
        let now = Date()
        if let last = lastAuthNotificationAt[provider],
           now.timeIntervalSince(last) < NotificationEvaluator.defaultUsageNotificationInterval {
            return
        }
        lastAuthNotificationAt[provider] = now

        let content = UNMutableNotificationContent()
        content.title = "ClaudexBar"
        content.body = "\(provider.displayName) auth expired. Run Re-auth \(provider.displayName)."
        let request = UNNotificationRequest(identifier: "auth-\(provider.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Notify the user that a re-auth attempt they just made did not complete,
    /// including the sanitized reason. `reason` is a short status token (e.g.
    /// `exchange_http_400`) and never contains secrets.
    private func notifyReauthFailed(provider: ProviderID, reason: String) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "ClaudexBar"
        content.body = "\(provider.displayName) re-auth didn’t complete (\(reason)). Try Re-auth \(provider.displayName) again."
        let request = UNNotificationRequest(identifier: "reauth-fail-\(provider.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Updates

    @objc private func checkForUpdates() {
        let version = appVersion
        Task { [weak self] in
            let update = await UpdateChecker().latestRelease(currentVersion: version)
            guard let self else { return }
            await MainActor.run {
                if let update {
                    self.settings.lastUpdateCheck = Date()
                    self.availableUpdate = update.isNewer ? update : nil
                }
                if let update, update.isNewer {
                    self.presentUpdate(update)
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "ClaudexBar"
                    alert.informativeText = (update == nil)
                        ? "Couldn’t check for updates right now. You have \(version)."
                        : "You’re up to date (\(version))."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    /// Daily background check: at launch, after wake, and on an hourly tick,
    /// but only when the last successful check is a day old.
    private func checkForUpdatesIfDue() {
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
        let version = appVersion
        Task { [weak self] in
            guard let update = await UpdateChecker().latestRelease(currentVersion: version) else { return }
            guard let self else { return }
            await MainActor.run {
                self.settings.lastUpdateCheck = Date()
                guard update.isNewer, update.latest != self.settings.skippedUpdateVersion else {
                    self.availableUpdate = nil
                    return
                }
                self.availableUpdate = update
                self.logger.log(provider: self.activeProvider, message: "update: \(update.latest) available (have \(update.current))")
                if self.settings.notifiedUpdateVersion != update.latest {
                    self.settings.notifiedUpdateVersion = update.latest
                    self.sendUpdateNotification(update)
                }
            }
        }
    }

    @objc private func presentAvailableUpdate() {
        guard let update = availableUpdate else { return }
        presentUpdate(update)
    }

    private func presentUpdate(_ update: UpdateChecker.Update) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ClaudexBar \(update.latest) is available"
        var text = "You have \(update.current)."
        let notes = update.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            text += "\n\n" + (notes.count > 1200 ? String(notes.prefix(1200)) + "…" : notes)
        }
        if update.canInstallInPlace {
            text += "\n\nAfter the update macOS asks once for Keychain access — choose “Always Allow”."
            alert.addButton(withTitle: "Install and Relaunch")
        }
        alert.informativeText = text
        alert.addButton(withTitle: "Release Page")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Later")

        var response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if !update.canInstallInPlace { response += 1 } // no install button: shift indices
        switch response {
        case 0:
            installUpdate(update)
        case 1:
            if let url = update.releaseURL { NSWorkspace.shared.open(url) }
        case 2:
            settings.skippedUpdateVersion = update.latest
            availableUpdate = nil
        default:
            break
        }
    }

    private func installUpdate(_ update: UpdateChecker.Update) {
        guard !updateInstallInProgress else { return }
        updateInstallInProgress = true
        logger.log(provider: activeProvider, message: "update: installing \(update.latest)")
        Task { [weak self] in
            guard let self else { return }
            let failure = await AppUpdater.install(update, logger: self.logger)
            // Only reached on failure — success relaunches and terminates.
            await MainActor.run {
                self.updateInstallInProgress = false
                guard let failure else { return }
                self.logger.log(provider: self.activeProvider, message: "update: failed — \(failure)")
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Couldn’t install ClaudexBar \(update.latest)"
                alert.informativeText = "The update stopped safely before changing anything: \(failure).\n\nYou can install it manually from the release page."
                alert.addButton(withTitle: "Release Page")
                alert.addButton(withTitle: "Close")
                if alert.runModal() == .alertFirstButtonReturn, let url = update.releaseURL {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func sendUpdateNotification(_ update: UpdateChecker.Update) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "ClaudexBar \(update.latest) is available"
        content.body = "You have \(update.current). Open the ClaudexBar menu and choose “Update to \(update.latest)…”."
        let request = UNNotificationRequest(identifier: "update-\(update.latest)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// One-click notification self-test: prompts for permission if undecided,
    /// directs to System Settings if denied, otherwise posts a test banner.
    @objc private func sendTestNotification() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch status {
                case .notDetermined:
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        if granted { DispatchQueue.main.async { self.postTestNotification() } }
                    }
                case .denied:
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "Notifications are turned off"
                    alert.informativeText = "Enable them in System Settings → Notifications → ClaudexBar, then try again."
                    alert.addButton(withTitle: "Open System Settings")
                    alert.addButton(withTitle: "Close")
                    if alert.runModal() == .alertFirstButtonReturn,
                       let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                default:
                    self.postTestNotification()
                }
            }
        }
    }

    private func postTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "ClaudexBar"
        content.body = "Test notification — notifications are working."
        let request = UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private var notificationsAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private func requestNotificationAuthorizationIfAvailable() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

private final class CodexAuthURLOpener: @unchecked Sendable {
    private let lock = NSLock()
    private var didOpen = false

    func handle(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8),
              let url = Self.authURL(in: text)
        else {
            return
        }

        lock.lock()
        if didOpen {
            lock.unlock()
            return
        }
        didOpen = true
        lock.unlock()

        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    private static func authURL(in text: String) -> URL? {
        let pattern = #"https://auth\.openai\.com/oauth/authorize\?[^\s]+"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }
}

private extension NSMenuItem {
    convenience init(title: String, action: Selector?, keyEquivalent: String, target: AnyObject?) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        self.target = target
    }
}
