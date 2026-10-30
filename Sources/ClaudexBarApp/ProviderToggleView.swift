import AppKit

enum ProviderVersionState {
    case current
    case outdated
    case unknown
}

struct ProviderVersionBadge {
    let text: String
    let state: ProviderVersionState
}

/// What a row shows after the name: either two usage figures (session ·
/// longer window), or a single item (a status word like "login", or a
/// provider with one window).
struct ProviderRowHint {
    let primary: String
    let secondary: String?
    /// A lone figure (a one-window provider) aligns with the first column of
    /// figures; a status word ("login", "wait") just starts the column.
    var isFigure = false

    static func status(_ word: String) -> ProviderRowHint { ProviderRowHint(primary: word, secondary: nil) }
    static func figure(_ value: String) -> ProviderRowHint { ProviderRowHint(primary: value, secondary: nil, isFigure: true) }
}

/// Column widths shared by every provider row, so the figures line up in
/// columns whatever each provider's name length: the name column is as wide
/// as the longest name (plus its version badge), the first figure is
/// right-aligned in its column, and the second follows a common separator.
struct ProviderRowLayout {
    var nameColumn: CGFloat = 0
    var primaryColumn: CGFloat = 0
    var secondaryColumn: CGFloat = 0

    static func make(rows: [(label: String, version: ProviderVersionBadge?, hint: ProviderRowHint)]) -> ProviderRowLayout {
        var layout = ProviderRowLayout()
        for row in rows {
            layout.nameColumn = max(layout.nameColumn, ProviderToggleView.nameWidth(label: row.label, version: row.version))
            if let secondary = row.hint.secondary ?? (row.hint.isFigure ? "" : nil) {
                layout.primaryColumn = max(layout.primaryColumn, ProviderToggleView.textWidth(row.hint.primary))
                layout.secondaryColumn = max(layout.secondaryColumn, ProviderToggleView.textWidth(secondary))
            } else {
                // A single item starts where the columns start; make sure the
                // row is still wide enough to hold it.
                layout.secondaryColumn = max(
                    layout.secondaryColumn,
                    ProviderToggleView.textWidth(row.hint.primary) - layout.primaryColumn - ProviderToggleView.separatorWidth
                )
            }
        }
        return layout
    }
}

/// A custom menu-row view for a provider's enable checkbox. Unlike a plain
/// `NSMenuItem`, clicking it toggles the provider **without closing the menu**,
/// so you can flip providers like a settings checklist. It draws a native-style
/// checkmark + name + usage hint and highlights on hover.
final class ProviderToggleView: NSView {
    private let label: String
    private let version: ProviderVersionBadge?
    private let hint: ProviderRowHint
    private let layout: ProviderRowLayout
    private let isEnabled: () -> Bool
    private let onToggle: () -> Void
    private var highlighted = false

    // Layout (approximates a standard checkmark menu item).
    private let rowHeight: CGFloat = 22
    private let checkX: CGFloat = 7
    private let nameX: CGFloat = 22
    private static let versionGap: CGFloat = 6
    private static let hintGap: CGFloat = 14
    private static let rightPad: CGFloat = 24
    private static let separator = " · "

    private static var font: NSFont { NSFont.menuFont(ofSize: 0) }
    private static var versionFont: NSFont {
        NSFont.systemFont(ofSize: max(7, font.pointSize * 0.58), weight: .semibold)
    }
    static var separatorWidth: CGFloat { textWidth(separator) }

    init(
        label: String,
        version: ProviderVersionBadge?,
        hint: ProviderRowHint,
        layout: ProviderRowLayout,
        isEnabled: @escaping () -> Bool,
        onToggle: @escaping () -> Void
    ) {
        self.label = label
        self.version = version
        self.hint = hint
        self.layout = layout
        self.isEnabled = isEnabled
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: rowHeight))
        frame.size.width = intrinsicWidth()
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    static func textWidth(_ s: String, font: NSFont? = nil) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font ?? Self.font]).width)
    }

    static func nameWidth(label: String, version: ProviderVersionBadge?) -> CGFloat {
        textWidth(label) + (version.map { versionGap + textWidth($0.text, font: versionFont) } ?? 0)
    }

    private var hintX: CGFloat { nameX + layout.nameColumn + Self.hintGap }

    private func intrinsicWidth() -> CGFloat {
        hintX + layout.primaryColumn + Self.separatorWidth + layout.secondaryColumn + Self.rightPad
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        highlighted = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        highlighted = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // Only act if released inside the row; keep the menu open afterwards.
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onToggle()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        let font = Self.font
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
        }

        let primary: NSColor = highlighted ? .white : .labelColor
        let secondary: NSColor = highlighted ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
        let normalTextHeight = ("Ag" as NSString).size(withAttributes: [.font: font]).height
        let normalTextBottom = (h - normalTextHeight) / 2

        func draw(_ string: String, at x: CGFloat, font: NSFont, color: NSColor, bottom: CGFloat? = nil) {
            let attr = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
            let size = attr.size()
            attr.draw(at: NSPoint(x: x, y: bottom ?? (h - size.height) / 2))
        }

        if isEnabled() {
            draw("✓", at: checkX, font: font, color: primary)
        }
        draw(label, at: nameX, font: font, color: primary)

        if let version {
            let versionColor: NSColor
            if highlighted {
                versionColor = NSColor.white.withAlphaComponent(0.9)
            } else {
                switch version.state {
                case .current: versionColor = .systemGreen
                case .outdated: versionColor = .systemOrange
                case .unknown: versionColor = .secondaryLabelColor
                }
            }
            draw(
                version.text,
                at: nameX + Self.textWidth(label) + Self.versionGap,
                font: Self.versionFont,
                color: versionColor,
                bottom: normalTextBottom
            )
        }

        if let secondaryText = hint.secondary {
            // First figure right-aligned in its column, so "9%" sits under
            // "100%"; the second starts at the same x in every row.
            let primaryWidth = Self.textWidth(hint.primary)
            draw(hint.primary, at: hintX + layout.primaryColumn - primaryWidth, font: font, color: secondary)
            draw(Self.separator, at: hintX + layout.primaryColumn, font: font, color: secondary)
            draw(secondaryText, at: hintX + layout.primaryColumn + Self.separatorWidth, font: font, color: secondary)
        } else if hint.isFigure {
            draw(hint.primary, at: hintX + layout.primaryColumn - Self.textWidth(hint.primary), font: font, color: secondary)
        } else if !hint.primary.isEmpty {
            draw(hint.primary, at: hintX, font: font, color: secondary)
        }
    }
}
