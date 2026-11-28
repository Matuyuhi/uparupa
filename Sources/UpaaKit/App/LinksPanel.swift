import AppKit

/// The right panel's Links view (design A3, 5): the web addresses the selected tab's panes printed, by service
/// (GitHub, Notion, then the rest), the newest first in each. A click opens one in the browser; its menu also copies it.
final class LinksPanel: NSView {
    private var shown: [Link]?
    private let rows = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let scroll = Chrome.scroller(rows)
        addSubview(scroll)
        scroll.pin(to: self)
        show([])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Lists links, which are newest first.
    func show(_ links: [Link]) {
        guard links != shown else { return }
        shown = links
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        add(Chrome.label(String(localized: "Links in This Session"), size: 11, weight: .semibold, color: .secondaryLabelColor), inset: 6)
        if links.isEmpty { add(Chrome.label(String(localized: "No links yet"), size: 12, color: .secondaryLabelColor), inset: 6, top: 6) }
        let described = links.compactMap { link in URL(string: link.address).map { (link, Self.describe($0)) } }
        for group in ["GitHub", "Notion", String(localized: "Other")] {
            let members = described.filter { $0.1.group == group }
            guard !members.isEmpty else { continue }
            add(Chrome.label(group, size: 11, color: .secondaryLabelColor), inset: 6, top: 10)
            for (link, about) in members { add(row(link, title: about.title, place: about.place), top: 2) }
        }
    }

    private func row(_ link: Link, title: String, place: String) -> NSView {
        let time = link.seen.formatted(date: .omitted, time: .shortened)
        let row = Clickable(cornerRadius: 9, selected: false, [
            Chrome.label(title, size: 13),
            Chrome.label("\(place) · \(time)", size: 11, mono: true, color: .secondaryLabelColor),
        ], spacing: 1, vertical: true, padding: NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8))
        row.toolTip = link.address
        let open = { if let url = URL(string: link.address) { _ = NSWorkspace.shared.open(url) } }
        row.onClick = open
        row.menu = Menu([
            (String(localized: "Open Link"), open),
            (String(localized: "Copy Link"), {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.address, forType: .string)
            }),
        ])
        return row
    }

    private func add(_ view: NSView, inset: CGFloat = 0, top: CGFloat = 0) {
        rows.addFullWidth(view, inset: inset)
        if let previous = rows.arrangedSubviews.dropLast().last { rows.setCustomSpacing(top, after: previous) }
    }

    /// The service an address belongs to, a short name for it, and where it is (a GitHub repository, or the host).
    private static func describe(_ url: URL) -> (group: String, title: String, place: String) {
        let host = url.host?.lowercased() ?? ""
        let parts = url.path.split(separator: "/").map(String.init)
        if host == "github.com" || host == "www.github.com" {
            let repository = parts.prefix(2).joined(separator: "/")
            var title = parts.dropFirst(2).joined(separator: "/")
            if parts.count >= 4, let number = Int(parts[3]) {
                switch parts[2] {
                case "pull": title = String(localized: "PR #\(number)")
                case "issues": title = String(localized: "Issue #\(number)")
                case "discussions": title = String(localized: "Discussion #\(number)")
                default: break
                }
            }
            return ("GitHub", title.isEmpty ? repository.isEmpty ? host : repository : title, repository.isEmpty ? host : repository)
        }
        if host == "notion.so" || host.hasSuffix(".notion.so") || host.hasSuffix(".notion.site") {
            // A page's address ends with its name, words joined by hyphens, and a 32-digit id.
            let name = (parts.last ?? "").replacingOccurrences(of: "-?[0-9a-f]{32}$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "-", with: " ")
            return ("Notion", name.isEmpty ? String(localized: "Notion page") : name, host)
        }
        return (String(localized: "Other"), parts.isEmpty ? host : "/" + parts.joined(separator: "/"), host)
    }
}

/// A context menu whose items run closures.
private final class Menu: NSMenu {
    private var actions: [() -> Void] = []

    init(_ items: [(title: String, action: () -> Void)]) {
        super.init(title: "")
        for (index, item) in items.enumerated() {
            let menuItem = addItem(withTitle: item.title, action: #selector(run(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            actions.append(item.action)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func run(_ sender: NSMenuItem) {
        actions[sender.tag]()
    }
}
