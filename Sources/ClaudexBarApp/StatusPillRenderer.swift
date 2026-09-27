import AppKit
import ClaudexBarCore

/// Renders the menu-bar image as a **template image**: fully transparent
/// background, glyphs/text drawn in opaque black (alpha only matters — RGB is
/// discarded by AppKit for template images). Setting `isTemplate = true` lets
/// macOS tint it to match every other menu-bar icon automatically (light/dark
/// menu bar, "Reduce Transparency", any future appearance) instead of us
/// hand-picking a background pill color per theme.
///
/// The canvas width is measured from the actual text on every redraw rather
/// than a fixed constant, so there's never dead transparent space reserved
/// "just in case" — the status item is always exactly as wide as its content.
enum StatusPillRenderer {
    private static let itemHeight: CGFloat = 26

    private static let labelFont = NSFont.systemFont(ofSize: 8.5, weight: .medium)
    private static let valueFont = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    private static let statusFont = NSFont.systemFont(ofSize: 14, weight: .semibold)

    // Alpha-only "colors": for a template image, opacity is all that's drawn;
    // hue is ignored by the system tint.
    private static let foreground = NSColor.black
    private static let secondaryForeground = NSColor.black.withAlphaComponent(0.55)

    private static let leftPadding: CGFloat = 6
    private static let columnGap: CGFloat = 7
    private static let rightPadding: CGFloat = 4

    /// Appended to a window's countdown when, at the current rate, the limit
    /// runs out before that window resets. Template images are single-colour,
    /// so this has to be a glyph rather than a red/amber tint.
    static let paceMarker = "▲"

    static func image(
        provider: ProviderID,
        snapshot: UsageSnapshot,
        now: Date = Date(),
        mode: PercentMode = .remaining,
        sessionPaceWarning: Bool = false,
        longPaceWarning: Bool = false
    ) -> NSImage {
        let primary = UsageFormatter.metricDisplay(
            for: snapshot.primary,
            unavailableLabel: "5h",
            now: now,
            mode: mode
        )
        let secondary = UsageFormatter.metricDisplay(
            for: snapshot.secondary,
            unavailableLabel: provider == .codex ? "1w" : "7d",
            now: now,
            mode: mode
        )
        func label(_ base: String, _ window: UsageWindow?, enabled: Bool) -> String {
            guard enabled, UsageFormatter.pace(for: window, now: now)?.runsOutBeforeReset == true else { return base }
            return "\(base) \(paceMarker)"
        }
        return image(
            provider: provider,
            primaryLabel: label(primary.label, snapshot.primary, enabled: sessionPaceWarning),
            primaryValue: primary.value,
            secondaryLabel: label(secondary.label, snapshot.secondary, enabled: longPaceWarning),
            secondaryValue: secondary.value
        )
    }

    static func image(provider: ProviderID, status: String) -> NSImage {
        let width = leftPadding + textWidth(status, font: statusFont) + rightPadding
        let image = baseImage(width: width)
        image.lockFocus()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: statusFont,
            .foregroundColor: foreground
        ]
        NSString(string: status).draw(
            in: NSRect(x: leftPadding, y: 5.5, width: width - leftPadding - rightPadding, height: 18),
            withAttributes: attributes
        )

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    static func pausedImage() -> NSImage {
        let text = "off"
        let width = leftPadding + textWidth(text, font: statusFont) + rightPadding
        let image = baseImage(width: width)
        image.lockFocus()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: statusFont,
            .foregroundColor: foreground
        ]
        NSString(string: text).draw(
            in: NSRect(x: leftPadding, y: 5.5, width: width - leftPadding - rightPadding, height: 18),
            withAttributes: attributes
        )

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func image(
        provider: ProviderID,
        primaryLabel: String,
        primaryValue: String,
        secondaryLabel: String,
        secondaryValue: String
    ) -> NSImage {
        let col1Width = max(
            textWidth(primaryLabel, font: labelFont),
            textWidth(primaryValue, font: valueFont)
        )
        let col2Width = max(
            textWidth(secondaryLabel, font: labelFont),
            textWidth(secondaryValue, font: valueFont)
        )
        let col1X = leftPadding
        let col2X = col1X + col1Width + columnGap
        let totalWidth = col2X + col2Width + rightPadding

        let image = baseImage(width: totalWidth)
        image.lockFocus()
        drawMetric(
            label: primaryLabel,
            value: primaryValue,
            x: col1X,
            width: col1Width,
            foregroundColor: foreground,
            secondaryForegroundColor: secondaryForeground
        )
        drawMetric(
            label: secondaryLabel,
            value: secondaryValue,
            x: col2X,
            width: col2Width,
            foregroundColor: foreground,
            secondaryForegroundColor: secondaryForeground
        )
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// Fully transparent canvas, sized exactly to the caller's measured
    /// content width — no background pill, matching every other menu-bar
    /// icon, and no reserved-but-unused space.
    private static func baseImage(width: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: max(width, 1), height: itemHeight))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        return image
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        let size = (text as NSString).size(withAttributes: [.font: font])
        // A small safety margin: measurement and drawing don't always agree
        // to the sub-pixel, and a rect sized to the exact measured width can
        // clip the trailing glyph (seen in practice with labels like
        // "3h1m"). A couple of points of headroom costs nothing visually.
        return ceil(size.width) + 2
    }

    private static func drawMetric(
        label: String,
        value: String,
        x: CGFloat,
        width: CGFloat,
        foregroundColor: NSColor,
        secondaryForegroundColor: NSColor
    ) {
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: secondaryForegroundColor,
            .kern: 0
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: foregroundColor,
            .kern: 0
        ]

        NSString(string: label).draw(
            in: NSRect(x: x, y: 14.6, width: width, height: 10),
            withAttributes: labelAttributes
        )
        NSString(string: value).draw(
            in: NSRect(x: x, y: 1.8, width: width, height: 16),
            withAttributes: valueAttributes
        )
    }
}
