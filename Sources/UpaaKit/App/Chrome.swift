import AppKit

/// Sizes and colors of upaa's own views, from the design's mockup (M5: tabs, splits and search).
enum Chrome {
    static let footerHeight: CGFloat = 26
    /// The tab list's width when the window opens.
    static let tabPanelWidth: CGFloat = 224
    /// The right panel's narrowest width.
    static let sidePanelWidth: CGFloat = 340
    static let inactivePaneAlpha: CGFloat = 0.6

    /// The selected file. In light mode the panel's glass comes out nearly white, so the design's white pill is lost on
    /// it; a faint gray stands in.
    static let pill = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.07) }
    /// A row under the pointer, and one held down, as AppKit's own buttons show them.
    static let hover = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.04) }
    static let pressed = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.2) : NSColor(white: 0, alpha: 0.11) }
    /// How long a row's change of color takes.
    static let animation: TimeInterval = 0.2
    /// Something in the config that could not be used (the design's orange).
    static let warning = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 1, green: 0x9f / 255, blue: 0x0a / 255, alpha: 1)
            : NSColor(srgbRed: 0xc4 / 255, green: 0x55 / 255, blue: 0, alpha: 1)
    }
    /// Added and removed: the + and - in front of a diff line, a file's counts, and the lines' backgrounds.
    static let added = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 0x7c / 255, green: 0xcf / 255, blue: 0x7c / 255, alpha: 1)
            : NSColor(srgbRed: 0x1a / 255, green: 0x7f / 255, blue: 0x1a / 255, alpha: 1)
    }
    static let removed = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 1, green: 0x7b / 255, blue: 0x72 / 255, alpha: 1)
            : NSColor(srgbRed: 0xb3 / 255, green: 0x1d / 255, blue: 0x28 / 255, alpha: 1)
    }
    static let addedLine = NSColor(name: nil) {
        NSColor(srgbRed: 46 / 255, green: 160 / 255, blue: 67 / 255, alpha: $0.isDark ? 0.22 : 0.14)
    }
    static let removedLine = NSColor(name: nil) {
        NSColor(srgbRed: 248 / 255, green: 81 / 255, blue: 73 / 255, alpha: $0.isDark ? 0.2 : 0.13)
    }

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false,
                      color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSStackView {
    /// Adds the view as wide as the stack inside its insets, less inset on each side.
    func addFullWidth(_ view: NSView, inset: CGFloat = 0) {
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor, constant: -edgeInsets.left - edgeInsets.right - 2 * inset).isActive = true
    }
}

extension NSView {
    /// Pins the view to the edges of other (usually its superview), inset by the given amount.
    func pin(to other: NSView, inset: CGFloat = 0) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: inset),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -inset),
            topAnchor.constraint(equalTo: other.topAnchor, constant: inset),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -inset),
        ])
    }
}

/// A rounded rectangle of one color that follows light and dark mode.
final class Fill: NSView {
    var color: NSColor {
        didSet { needsDisplay = true }
    }

    init(_ color: NSColor, cornerRadius: CGFloat = 0) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Called with this view's appearance current, so the color resolves for light or dark mode.
        // A change of color fades in; the layer of a view does not animate its own changes.
        guard let layer else { return }
        let new = color.cgColor
        if let old = layer.presentation()?.backgroundColor ?? layer.backgroundColor, old != new {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = old
            fade.duration = Chrome.animation
            layer.add(fade, forKey: "color")
        }
        layer.backgroundColor = new
    }
}

/// A Fill that runs an action when clicked (the right panel's file rows). On, it has the pill color and a
/// faint shadow. Under the pointer and held down it lightens and darkens, and lets go of the click as a button does:
/// on release over it.
final class Clickable: NSView {
    private let fill: Fill
    var onClick: (() -> Void)?
    var isOn: Bool {
        didSet { show() }
    }
    private var hovered = false {
        didSet { show() }
    }
    private var pressed = false {
        didSet { show() }
    }

    init(cornerRadius: CGFloat, selected: Bool, _ views: [NSView], spacing: CGFloat = 0, vertical: Bool = false,
         padding: NSEdgeInsets) {
        fill = Fill(selected ? Chrome.pill : .clear, cornerRadius: cornerRadius)
        isOn = selected
        super.init(frame: .zero)
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        stack.edgeInsets = padding
        fill.layer?.shadowOffset = CGSize(width: 0, height: -1)
        fill.layer?.shadowRadius = 1.5
        fill.layer?.shadowOpacity = selected ? 0.12 : 0
        addSubview(fill)
        fill.pin(to: self)
        addSubview(stack)
        stack.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The click goes to this view, not to the labels in it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        onClick?()
    }

    private func show() {
        fill.color = pressed ? Chrome.pressed : isOn ? Chrome.pill : hovered ? Chrome.hover : .clear
        fill.layer?.shadowOpacity = isOn && !pressed ? 0.12 : 0
    }
}

/// The window's ground (design A3, after Arc): a base color with three soft spots of color, for light and dark mode.
final class Backdrop: NSView {
    /// Where each spot is (from the top left, as fractions of the window), how far it reaches, and its colors.
    private static let spots: [(x: CGFloat, y: CGFloat, reach: CGFloat, light: UInt32, dark: UInt32)] = [
        (0.18, 0.22, 0.52, 0xa5c8ff, 0x3b5bdb),
        (0.82, 0.30, 0.46, 0xd0bfff, 0x7048e8),
        (0.60, 0.90, 0.58, 0x99e9f2, 0x0b7285),
    ]
    private static let base = (light: UInt32(0xeef1f6), dark: UInt32(0x111827))

    private let layers = Backdrop.spots.map { _ in CAGradientLayer() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for spot in layers {
            spot.type = .radial
            layer?.addSublayer(spot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layers.forEach { $0.frame = bounds }
        CATransaction.commit()
    }

    override func updateLayer() {
        let dark = effectiveAppearance.isDark
        layer?.backgroundColor = Self.color(dark ? Self.base.dark : Self.base.light).cgColor
        for (layer, spot) in zip(layers, Self.spots) {
            let color = Self.color(dark ? spot.dark : spot.light)
            layer.colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
            // A layer's y runs up from the bottom. The radius is a fraction of the width and of the height.
            layer.startPoint = CGPoint(x: spot.x, y: 1 - spot.y)
            layer.endPoint = CGPoint(x: spot.x + spot.reach, y: 1 - spot.y + spot.reach)
        }
    }

    private static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}
