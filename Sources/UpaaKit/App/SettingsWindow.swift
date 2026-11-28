import AppKit

/// The Settings window (Cmd-,). As in other Mac apps' settings, a change takes effect as soon as it is made.
final class SettingsWindow: NSWindowController {
    private let fontButton = NSPopUpButton()
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    /// One row per fallback, each a menu of every family and a button that removes the row.
    private let fallbacks = NSStackView()
    private let mascotBox = NSButton(
        checkboxWithTitle: String(localized: "Show the axolotl behind the text"), target: nil, action: nil)
    /// What in the config could not be used, under the note. Its row is hidden when there is none.
    private let problems = NSTextField(wrappingLabelWithString: "")
    private var grid: NSGridView!
    private let families = NSFontManager.shared.availableFontFamilies
    private let onFont: (_ families: [String], _ size: Double) -> Void
    private let onMascot: (Bool) -> Void

    /// families is the font, then its fallbacks. onFont gets them back, with the size in points, after each change of
    /// them, and onMascot whether the mascot is shown, after each change of that.
    init(families: [String], size: Double, mascot: Bool, problems: [String],
         onFont: @escaping (_ families: [String], _ size: Double) -> Void, onMascot: @escaping (Bool) -> Void) {
        self.onFont = onFont
        self.onMascot = onMascot
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = String(localized: "Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)

        // Monospaced families for the font, each shown in its own face. Any family can be a fallback, such as a
        // Nerd Font with only icons.
        let manager = NSFontManager.shared
        let monospaced = Set((manager.availableFontNames(with: .fixedPitchFontMask) ?? []).compactMap {
            NSFont(name: $0, size: NSFont.systemFontSize)?.familyName
        })
        for family in monospaced.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            fontButton.addItem(withTitle: family)
            if let font = manager.font(withFamily: family, traits: [], weight: 5, size: NSFont.systemFontSize) {
                fontButton.lastItem?.attributedTitle = NSAttributedString(string: family, attributes: [.font: font])
            }
        }

        let formatter = NumberFormatter()
        formatter.minimum = 4
        formatter.maximum = 200
        formatter.maximumFractionDigits = 1
        sizeField.formatter = formatter
        sizeField.alignment = .right
        sizeField.cell?.sendsActionOnEndEditing = true
        sizeStepper.minValue = 4
        sizeStepper.maxValue = 200
        sizeStepper.valueWraps = false
        for control in [fontButton, sizeField, sizeStepper] as [NSControl] {
            control.target = self
            control.action = #selector(changed(_:))
        }
        mascotBox.target = self
        mascotBox.action = #selector(mascotChanged(_:))

        fallbacks.orientation = .vertical
        fallbacks.alignment = .leading
        fallbacks.spacing = 6
        let add = NSButton(title: String(localized: "Add"), image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)!,
                           target: self, action: #selector(addFallback(_:)))
        add.imagePosition = .imageLeading
        add.controlSize = .small
        let fallbackColumn = NSStackView(views: [fallbacks, add])
        fallbackColumn.orientation = .vertical
        fallbackColumn.alignment = .leading
        fallbackColumn.spacing = 6

        let saved = (Config.fileURL.path as NSString).abbreviatingWithTildeInPath
        let note = NSTextField(wrappingLabelWithString: String(localized: """
            Characters the font lacks (such as Nerd Font icons) are drawn with the first fallback that has them, \
            from the top. Saved in: \(saved)
            """))
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 290
        self.problems.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        self.problems.textColor = Chrome.warning
        self.problems.preferredMaxLayoutWidth = 290
        let sizeRow = NSStackView(views: [sizeField, sizeStepper, NSTextField(labelWithString: "pt")])
        sizeRow.spacing = 4
        grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Font:")), fontButton],
            [NSTextField(labelWithString: String(localized: "Size:")), sizeRow],
            [NSTextField(labelWithString: String(localized: "Fallbacks:")), fallbackColumn],
            [NSGridCell.emptyContentView, note],
            [NSTextField(labelWithString: String(localized: "Mascot:")), mascotBox],
            [NSGridCell.emptyContentView, self.problems],
        ])
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.row(at: 3).topPadding = 4
        grid.row(at: 4).topPadding = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            fontButton.widthAnchor.constraint(equalToConstant: 260),
            note.widthAnchor.constraint(equalToConstant: 290),
            self.problems.widthAnchor.constraint(equalToConstant: 290),
            sizeField.widthAnchor.constraint(equalToConstant: 48),
        ])
        window.contentView = content
        // Not the size field, which would open with its text selected.
        window.initialFirstResponder = fontButton
        show(families: families, size: size, mascot: mascot, problems: problems)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows the settings and what could not be used, as when the config file was changed by hand.
    func show(families: [String], size: Double, mascot: Bool, problems: [String]) {
        self.problems.stringValue = problems.joined(separator: "\n")
        grid.row(at: 5).isHidden = problems.isEmpty
        mascotBox.state = mascot ? .on : .off
        Self.select(families.first, in: fontButton)
        sizeField.doubleValue = size
        sizeStepper.doubleValue = size
        fallbacks.arrangedSubviews.forEach { $0.removeFromSuperview() }
        families.dropFirst().forEach(addRow)
        fit()
    }

    private func addRow(_ family: String) {
        let button = NSPopUpButton()
        button.addItems(withTitles: families)
        Self.select(family, in: button)
        button.target = self
        button.action = #selector(changed(_:))
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: String(localized: "Remove"))!,
                              target: self, action: #selector(removeFallback(_:)))
        remove.isBordered = false
        let row = NSStackView(views: [button, remove])
        row.spacing = 6
        fallbacks.addArrangedSubview(row)
        button.widthAnchor.constraint(equalToConstant: 236).isActive = true
    }

    /// Fits the window to its rows, keeping its top edge where it is.
    private func fit() {
        guard let window, let content = window.contentView else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    /// Selects family, adding it if the list lacks it (a name the file gives that is not a family name, or a font
    /// that is not installed), so that what the file says is kept.
    private static func select(_ family: String?, in button: NSPopUpButton) {
        guard let family else { return }
        if button.item(withTitle: family) == nil { button.addItem(withTitle: family) }
        button.selectItem(withTitle: family)
    }

    /// A new fallback starts as the first Nerd Font installed, the usual reason to add one.
    @objc private func addFallback(_ sender: Any?) {
        addRow(families.first { $0.localizedCaseInsensitiveContains("Nerd Font") } ?? families.first ?? "")
        fit()
        changed(nil)
    }

    @objc private func removeFallback(_ sender: NSButton) {
        sender.superview?.removeFromSuperview()
        fit()
        changed(nil)
    }

    @objc private func changed(_ sender: NSControl?) {
        if sender === sizeStepper { sizeField.doubleValue = sizeStepper.doubleValue } else { sizeStepper.doubleValue = sizeField.doubleValue }
        guard let font = fontButton.titleOfSelectedItem else { return }
        let chosen = fallbacks.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.first as? NSPopUpButton }
        onFont([font] + chosen.compactMap(\.titleOfSelectedItem), sizeField.doubleValue)
    }

    @objc private func mascotChanged(_ sender: NSButton) {
        onMascot(sender.state == .on)
    }
}
