import Foundation

/// A web address a pane printed, as text or as the target of a hyperlink (OSC 8). The links panel lists them (#16).
struct Link: Equatable {
    let address: String
    /// When upaa first read it.
    let seen: Date
}

enum Links {
    /// The target of a hyperlink: ESC ] 8 ; params ; URI, ended by BEL or ESC \.
    private static let hyperlink = try! NSRegularExpression(pattern: "\u{1b}\\]8;[^;\u{7}\u{1b}]*;(https?://[^\u{7}\u{1b}]+)")
    /// Any escape sequence: CSI, a string such as OSC (ended by BEL or ESC \, or cut off), or ESC and one character.
    private static let sequence = try! NSRegularExpression(pattern: "\u{1b}(\\[[0-?]*[ -/]*[@-~]|[\\]P_^][^\u{7}\u{1b}]*(\u{7}|\u{1b}\\\\)?|.)")
    /// The characters an address may have (RFC 3986), so it ends at a space, a quote mark, < > or anything not ASCII.
    private static let address = try! NSRegularExpression(pattern: "https?://[A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=%-]+")

    /// The addresses in text that a session gave as VT sequences (TerminalSession.newText), in the order they come,
    /// each once: those in the text, then the hyperlinks' targets.
    static func find(in text: String) -> [String] {
        let all = NSRange(text.startIndex..., in: text)
        let plain = sequence.stringByReplacingMatches(in: text, range: all, withTemplate: "")
        let written = address.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).map {
            trimmed(plain[Range($0.range, in: plain)!])
        }
        let targets = hyperlink.matches(in: text, range: all).map { text[Range($0.range(at: 1), in: text)!] }
        var found: [String] = []
        for candidate in written + targets {
            let address = String(candidate)
            guard URL(string: address)?.host?.isEmpty == false, !found.contains(address) else { continue }
            found.append(address)
        }
        return found
    }

    /// Adds the addresses found, seen at now, to links (oldest first, each once).
    static func add(_ found: [String], to links: inout [Link], now: Date) {
        for address in found where !links.contains(where: { $0.address == address }) {
            // An address read while it was still being printed comes again longer. The cut one goes, unless it was
            // printed whole on its own too.
            links.removeAll { address.hasPrefix($0.address) && !found.contains($0.address) && now.timeIntervalSince($0.seen) < 10 }
            links.append(Link(address: address, seen: now))
        }
    }

    /// Leaves off what usually follows an address in a sentence or in Markdown: punctuation, and a closing bracket
    /// that opened before it.
    private static func trimmed(_ text: Substring) -> Substring {
        var text = text
        while let last = text.last {
            let unopened = last == ")" && text.filter { $0 == "(" }.count < text.filter { $0 == ")" }.count
                || last == "]" && text.filter { $0 == "[" }.count < text.filter { $0 == "]" }.count
            guard ".,;:!?'*".contains(last) || unopened else { break }
            text.removeLast()
        }
        return text
    }
}
