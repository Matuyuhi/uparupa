import AppKit

/// The right panel's Changes view: the files changed in the git repository of the focused pane's directory, and the
/// diff of one of them. A change is anything in the working tree that differs from HEAD (new files included), so it is
/// every change in the repository, not only what Claude Code made.
final class ChangesPanel: NSView {
    private struct File: Equatable {
        var path: String
        /// nil for a new file, or a binary one.
        var added: Int?
        var removed: Int?
        var isNew: Bool
    }

    private struct State: Equatable {
        var root: String
        var branch: String?
        var files: [File]
        var selected: String?
        var diff: [Substring]
    }

    /// After each read: the branch, nil outside a git repository, and how many files have changed.
    var onUpdate: ((_ branch: String?, _ changes: Int) -> Void)?

    private var state: State?
    private var selectedPath: String?
    private var reading = false
    private let rows = NSStackView()
    private let openButton = NSButton(title: String(localized: "Open in Editor"), target: nil, action: nil)

    /// Shows at most this many lines of a diff, so a huge file does not stall the window.
    private static let maxDiffLines = 400

    override init(frame: NSRect) {
        super.init(frame: frame)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 8, right: 8)

        // A flipped document view keeps the rows at the top of the scroll view.
        let document = FlippedView()
        document.addSubview(rows)
        rows.pin(to: document)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
        document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true

        openButton.target = self
        openButton.action = #selector(openInEditor)
        let stack = NSStackView(views: [scroll, openButton])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        addSubview(stack)
        stack.pin(to: self)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        show(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Reads git in the background and redraws when something changed. directory nil (unknown) shows nothing.
    func refresh(directory: String?) {
        guard let directory else { return apply(nil) }
        guard !reading else { return }
        reading = true
        let selected = selectedPath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let state = Self.read(directory: directory, selected: selected)
            DispatchQueue.main.async {
                self?.reading = false
                self?.apply(state)
            }
        }
    }

    private func apply(_ new: State?) {
        onUpdate?(new?.branch, new?.files.count ?? 0)
        guard new != state else { return }
        state = new
        show(new)
    }

    private func select(_ path: String) {
        selectedPath = path
        if let root = state?.root { refresh(directory: root) }
    }

    @objc private func openInEditor() {
        guard let state, let path = state.selected else { return NSSound.beep() }
        NSWorkspace.shared.open(URL(fileURLWithPath: state.root).appendingPathComponent(path))
    }

    // MARK: Drawing the rows

    private func show(_ state: State?) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        openButton.isHidden = state?.selected == nil
        guard let state else {
            add(Chrome.label(String(localized: "Not a git repository"), size: 11, color: .secondaryLabelColor), inset: 6)
            return
        }
        add(Chrome.label(([String(localized: "Changes")] + [state.branch].compactMap { $0 }).joined(separator: " · "), size: 11,
                         weight: .semibold, color: .secondaryLabelColor), inset: 6)
        if state.files.isEmpty { add(Chrome.label(String(localized: "No changes"), size: 12, color: .secondaryLabelColor), inset: 6, top: 6) }
        for file in state.files {
            let selected = file.path == state.selected
            var views: [NSView] = [Chrome.label(file.path, size: 12, weight: selected ? .medium : .regular, mono: true)]
            views.append(NSView())
            if file.isNew {
                views.append(Chrome.label(String(localized: "New"), size: 11, color: .systemGreen))
            }
            if let added = file.added { views.append(Chrome.label("+\(added)", size: 11, mono: true, color: .systemGreen)) }
            if let removed = file.removed { views.append(Chrome.label("−\(removed)", size: 11, mono: true, color: .systemRed)) }
            let row = Clickable(cornerRadius: 9, selected: selected, views, spacing: 6,
                                padding: NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8))
            row.onClick = { [weak self] in self?.select(file.path) }
            add(row)
        }
        guard !state.diff.isEmpty else { return }
        let diff = NSStackView()
        diff.orientation = .vertical
        diff.alignment = .leading
        diff.spacing = 0
        diff.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        for line in state.diff {
            diff.addFullWidth(Self.diffLine(line))
        }
        let box = Fill(.textBackgroundColor.withAlphaComponent(0.8), cornerRadius: 10)
        box.addSubview(diff)
        diff.pin(to: box)
        add(box, top: 8)
    }

    private func add(_ view: NSView, inset: CGFloat = 0, top: CGFloat = 0) {
        rows.addFullWidth(view, inset: inset)
        if let previous = rows.arrangedSubviews.dropLast().last { rows.setCustomSpacing(top, after: previous) }
    }

    /// One line of the diff, 17 high as in the design. A line wider than the panel wraps, as the panel is too narrow to
    /// scroll sideways through, and goes on under its text: past the +, - or space in front and its own indentation, up
    /// to a third of the narrowest panel, so a deep one still leaves room for the text.
    private static func diffLine(_ line: Substring) -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let lead = line.hasPrefix("@@") ? "" : line.prefix(1) + line.dropFirst().prefix { $0 == " " || $0 == "\t" }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 17
        style.maximumLineHeight = 17
        style.headIndent = min(NSAttributedString(string: String(lead), attributes: [.font: font]).size().width,
                               Chrome.sidePanelWidth / 3)
        let label = WrappingLabel(wrappingLabelWithString: "")
        // The extra height of a line goes above its text, so the text moves up by half of it to sit in the middle.
        label.attributedStringValue = NSAttributedString(string: String(line), attributes: [
            .font: font, .paragraphStyle: style, .baselineOffset: (17 - font.ascender + font.descender) / 2,
            .foregroundColor: line.hasPrefix("@@") ? NSColor.secondaryLabelColor : .labelColor,
        ])
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let fill = Fill(line.hasPrefix("+") ? Chrome.addedLine : line.hasPrefix("-") ? Chrome.removedLine : .clear)
        fill.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: fill.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: fill.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: fill.topAnchor),
            label.bottomAnchor.constraint(equalTo: fill.bottomAnchor),
        ])
        return fill
    }

    // MARK: Reading git

    private static func read(directory: String, selected: String?) -> State? {
        guard let root = git(["rev-parse", "--show-toplevel"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty
        else { return nil }
        let branch = git(["rev-parse", "--abbrev-ref", "HEAD"], in: root)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A repository with no commit yet has no HEAD, so only its new files show.
        var files = (git(["diff", "HEAD", "--numstat"], in: root) ?? "").split(separator: "\n").compactMap { line -> File? in
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { return nil }
            return File(path: String(parts[2]), added: Int(parts[0]), removed: Int(parts[1]), isNew: false)
        }
        files += (git(["ls-files", "--others", "--exclude-standard"], in: root) ?? "").split(separator: "\n").map {
            File(path: String($0), isNew: true)
        }
        let pick = files.first { $0.path == selected } ?? files.first
        let diff = pick.map { file -> [Substring] in
            let text = file.isNew
                ? git(["diff", "--no-index", "--", "/dev/null", file.path], in: root)
                : git(["diff", "HEAD", "--", file.path], in: root)
            // Leave out the header lines before the first hunk.
            let lines = (text ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            return Array(lines.drop { !$0.hasPrefix("@@") }.prefix(maxDiffLines))
        } ?? []
        return State(root: root, branch: branch, files: files, selected: pick?.path, diff: diff)
    }

    /// Output of git, or nil if it failed. diff --no-index exits with 1 when the files differ, which is not a failure.
    private static func git(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus <= 1 ? String(decoding: data, as: UTF8.self) : nil
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A label that wraps at the width the layout gives it. A wrapping NSTextField sizes its height for
/// preferredMaxLayoutWidth, so that follows its width, which changes with the panel's. The value is the width of the
/// alignment rectangle, which is narrower than the frame, so the frame's width would leave a line that only just
/// wraps measured as one line and its end cut off.
private final class WrappingLabel: NSTextField {
    override func layout() {
        super.layout()
        let width = alignmentRect(forFrame: frame).width
        if preferredMaxLayoutWidth != width { preferredMaxLayoutWidth = width }
    }
}
