import CUpaaCore
import Foundation

/// Settings from $XDG_CONFIG_HOME/upaa/config (~/.config/upaa/config when the variable is unset). Zig parses the text.
final class Config {
    let handle: OpaquePointer
    /// The file's text, to tell whether it changed.
    let text: String
    /// The font, then its fallbacks, one per line.
    let fontFamily: String
    /// Points.
    let fontSize: Double
    /// How much of the default background color covers what is behind the window (0 to 1).
    let backgroundOpacity: Double
    /// Cells.
    let cols: Int
    let rows: Int
    /// The lines that could not be read, in the user's language.
    let problems: [String]

    /// With no text, every setting is the default. Snapshots use this, so the baseline images do not depend on the user's file.
    init(text: String = "") {
        self.text = text
        let bytes = Array(text.utf8)
        handle = upaa_config_new(bytes, bytes.count)!
        let values = upaa_config_values(handle)
        fontFamily = String(cString: values.font_family)
        fontSize = values.font_size
        backgroundOpacity = values.background_opacity
        cols = Int(values.window_width)
        rows = Int(values.window_height)
        problems = UnsafeBufferPointer(start: values.problems, count: values.problem_count).map { problem in
            let line = Int(problem.line)
            let start = Int(problem.key_start), end = start + Int(problem.key_len)
            let key = end <= bytes.count ? String(decoding: bytes[start..<end], as: UTF8.self) : ""
            switch Int(problem.kind) {
            case UPAA_CONFIG_UNKNOWN_KEY: return String(localized: "config line \(line): unknown key \"\(key)\"")
            case UPAA_CONFIG_INVALID_VALUE: return String(localized: "config line \(line): invalid value for \"\(key)\"")
            default: return String(localized: "config line \(line): expected key = value")
            }
        }
    }

    deinit {
        upaa_config_free(handle)
    }

    var fontFamilies: [String] { fontFamily.components(separatedBy: "\n") }

    /// The terminal's default background in light or dark mode, as 0xRRGGBB.
    func background(dark: Bool) -> UInt32 {
        upaa_config_background(handle, dark)
    }

    /// Whether the background the file names is dark, or nil if it names none (the two modes' backgrounds differ).
    var backgroundIsDark: Bool? {
        let rgb = background(dark: false)
        guard rgb == background(dark: true) else { return nil }
        let luminance = 0.2126 * Double(rgb >> 16 & 0xff) + 0.7152 * Double(rgb >> 8 & 0xff) + 0.0722 * Double(rgb & 0xff)
        return luminance < 128
    }

    /// The user's file.
    static var fileURL: URL {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("upaa/config")
    }

    /// Reads the user's file. Without one, every setting is the default.
    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL) else { return Config() }
        return Config(text: String(decoding: data, as: UTF8.self))
    }

    /// Puts font-family lines (the font, then its fallbacks) and a font-size line in the user's file, where its first
    /// such line was, in place of all of them. Every other line stays as it is. A link to the file is followed.
    static func saveFont(families: [String], size: Double) throws {
        let url = fileURL.resolvingSymlinksInPath()
        var lines = (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: "\n") ?? []
        if lines.last == "" { lines.removeLast() }
        func isFont(_ line: String) -> Bool {
            let key = line.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
            return key == "font-family" || key == "font-size"
        }
        let at = lines.firstIndex(where: isFont) ?? lines.count
        lines.removeAll(where: isFont)
        lines.insert(contentsOf: families.map { "font-family = \"\($0)\"" } + ["font-size = \(String(format: "%g", size))"], at: at)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
