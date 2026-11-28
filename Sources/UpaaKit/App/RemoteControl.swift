import AppKit

/// Whether the upaa command may read, type into and close a tab's panes (#65). Kept in memory only.
enum RemoteAccess: Int {
    case allow, ask, deny
}

/// The upaa command's way into the app from a pane (#65). With remote-control = true in the config, the app listens on
/// a Unix socket of its own (UPAA_SOCKET, which every pane's shell gets); `upaa list`, `focus`, `new-tab`, `split`,
/// `read`, `close` and `send` send their arguments there and print what comes back. The arguments are read here, on
/// the app's side, only. A pane is named by its shell's process ID. Reading, typing into and closing a pane follow what
/// its tab is set to in the tab's menu, which asks in a sheet until it is set otherwise.
final class RemoteControl {
    /// One per app, from its process ID, in the user's own temporary folder.
    static let path = FileManager.default.temporaryDirectory.appendingPathComponent("upaa-\(getpid()).sock").path
    /// The app's windows, in the order they opened.
    var windows: () -> [TabbedWindow] = { [] }
    private var listener: DispatchSourceRead?
    private var connections: [ObjectIdentifier: Connection] = [:]

    /// The socket is open while this is true.
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled { start() } else { stop() }
        }
    }

    init() {
        // The panes' shells take it from this process's environment. It is set while the socket is closed too, so that
        // turning remote control on later reaches the panes already open.
        setenv("UPAA_SOCKET", Self.path, 1)
        unlink(Self.path)
    }

    private func start() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        unlink(Self.path)
        // Only this user may connect (0600).
        let mask = umask(0o077)
        let bound = Self.withAddress(Self.path, { bind(fd, $0, $1) })
        umask(mask)
        guard bound == 0, listen(fd, 8) == 0 else {
            NSLog("upaa: cannot open %@: %s", Self.path, strerror(errno))
            Darwin.close(fd)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            self?.serve(client)
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        listener = source
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        unlink(Self.path)
    }

    private func serve(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // A command that is stopped and never goes on gives up its answer after this, instead of holding a thread.
        var limit = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var panes: [Int32: TerminalView] = [:]
        for window in windows() {
            for entry in window.panes { panes[entry.pane.session.pid] = entry.pane }
        }
        let caller = Self.caller(of: fd, among: panes)
        let connection = Connection(fd: fd, onRequest: { [weak self] connection, arguments in
            self?.handle(arguments, from: connection, caller: caller)
        }, onEnd: { [weak self] connection in
            self?.connections[ObjectIdentifier(connection)] = nil
        })
        connections[ObjectIdentifier(connection)] = connection
    }

    /// The pane whose shell the command runs under: the socket's other end, or the nearest of its parents that is a
    /// pane's shell. Only the default for --pane and the sheet's words come from it, never whether a step is allowed.
    private static func caller(of fd: Int32, among panes: [Int32: TerminalView]) -> TerminalView? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        var next: pid_t? = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 ? pid : nil
        for _ in 0..<64 {
            guard let current = next, current > 1 else { return nil }
            if let pane = panes[current] { return pane }
            var info = kinfo_proc()
            var length = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &length, nil, 0) == 0, length > 0 else { return nil }
            next = info.kp_eproc.e_ppid
        }
        return nil
    }

    private static let usage = """
        usage: upaa list
               upaa focus [--pane ID]
               upaa new-tab [--pane ID]
               upaa split [--down] [--pane ID]
               upaa read [--pane ID]
               upaa close [--pane ID]
               upaa send [--pane ID] TEXT

        """

    private func handle(_ arguments: [String], from connection: Connection, caller: TerminalView?) {
        var rest = arguments[...]
        let command = rest.popFirst() ?? ""
        var id: String?
        var down = false
        var words: [String] = []
        let usage = {
            connection.answer(2, Self.usage + String(localized: "A pane's ID is its shell's process ID, as upaa list shows. Without --pane, the command acts on the pane it runs in.") + "\n")
        }
        while let word = rest.popFirst() {
            if word == "--pane" {
                guard let value = rest.popFirst() else { return usage() }
                id = value
            } else if word == "--down" {
                down = true
            } else {
                words.append(word)
            }
        }
        let commands = ["list", "focus", "new-tab", "split", "read", "close", "send"]
        guard commands.contains(command), words.count == (command == "send" ? 1 : 0), !down || command == "split" else {
            return usage()
        }
        let windows = self.windows()
        if command == "list" { return connection.answer(0, list(windows)) }

        let pane: TerminalView
        if let id {
            guard let found = windows.flatMap(\.panes).first(where: { String($0.pane.session.pid) == id })?.pane else {
                return connection.answer(1, "upaa: " + String(localized: "No pane \(id).") + "\n")
            }
            pane = found
        } else if let caller {
            pane = caller
        } else {
            return connection.answer(1, "upaa: " + String(localized: "Name the pane with --pane: this process is not in an upaa pane.") + "\n")
        }
        guard let window = windows.first(where: { $0.contains(pane) }) else {
            return connection.answer(1, "upaa: " + String(localized: "No pane \(String(pane.session.pid)).") + "\n")
        }

        switch command {
        case "focus":
            window.focus(pane)
            connection.answer(0, "")
        case "new-tab", "split":
            let new = command == "new-tab" ? window.openTab(after: pane) : window.split(pane, vertical: !down)
            guard let new else { return connection.answer(1, "upaa: " + String(localized: "Could not start a shell.") + "\n") }
            connection.answer(0, "\(new.session.pid)\n")
        default:
            let question = command == "read" ? String(localized: "Allow reading this pane’s screen?")
                : command == "close" ? String(localized: "Allow closing this pane?")
                : String(localized: "Allow typing into this pane?")
            var detail = String(localized: "Pane \(String(pane.session.pid)) in “\(pane.session.title ?? "upaa")”.") + "\n"
            detail += caller.map {
                String(localized: "Asked by pane \(String($0.session.pid)) in “\($0.session.title ?? "upaa")”.")
            } ?? String(localized: "Asked by an unknown process.")
            if command == "send" { detail += "\n\n" + Self.visible(words[0]) }
            let withdraw = window.allow(pane, question, detail: detail) { allowed in
                connection.withdraw = nil
                guard connection.isOpen else { return }
                guard let allowed else {
                    return connection.answer(1, "upaa: " + String(localized: "The window is already asking something. Answer it, then try again.") + "\n")
                }
                guard allowed else {
                    return connection.answer(1, "upaa: " + String(localized: "The tab did not allow this.") + "\n")
                }
                guard window.contains(pane) else {
                    return connection.answer(1, "upaa: " + String(localized: "No pane \(String(pane.session.pid)).") + "\n")
                }
                switch command {
                case "read":
                    let text = pane.session.plainText()
                    connection.answer(0, text.hasSuffix("\n") ? text : text + "\n")
                case "send":
                    pane.session.write(words[0])
                    connection.answer(0, "")
                default:
                    // The answer goes first, since the command may run in the pane that closes.
                    connection.answer(0, "")
                    window.close(pane)
                }
            }
            if connection.isOpen { connection.withdraw = withdraw }
        }
    }

    /// One line per pane, tab-separated: its ID, its window and tab (from 1), * if it has the keyboard, its directory,
    /// the program it runs, its title and its size. - stands for what is not known or not running.
    private func list(_ windows: [TabbedWindow]) -> String {
        var lines = ""
        for (number, window) in windows.enumerated() {
            for entry in window.panes {
                let session = entry.pane.session
                let size = entry.pane.gridSize
                let fields = [String(session.pid), String(number + 1), String(entry.tab + 1), entry.focused ? "*" : "-",
                              session.cwd ?? "", session.running ?? "", session.title ?? "", "\(size.cols)x\(size.rows)"]
                lines += fields.map { field in
                    field.isEmpty ? "-" : field.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                }.joined(separator: "\t") + "\n"
            }
        }
        return lines
    }

    /// The start of the text to send, for the sheet, with control characters shown as ^J and the like.
    private static func visible(_ text: String) -> String {
        var shown = ""
        for scalar in text.unicodeScalars.prefix(200) {
            switch scalar.value {
            case 0..<0x20: shown += "^" + String(Character(UnicodeScalar(UInt8(scalar.value + 0x40))))
            case 0x7f: shown += "^?"
            default: shown.unicodeScalars.append(scalar)
            }
        }
        return text.unicodeScalars.count > 200 ? shown + "…" : shown
    }

    // MARK: The command's side

    /// Runs the upaa command with arguments (the first not an option): sends them to the app whose pane it runs in,
    /// prints the answer, and returns the exit code.
    static func run(_ arguments: [String]) -> Int32 {
        func fail(_ message: String) -> Int32 {
            FileHandle.standardError.write(Data("upaa: \(message)\n".utf8))
            return 1
        }
        guard let path = ProcessInfo.processInfo.environment["UPAA_SOCKET"], !path.isEmpty else {
            return fail(String(localized: "Run this in an upaa pane."))
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return fail(String(cString: strerror(errno))) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard withAddress(path, { connect(fd, $0, $1) }) == 0 else {
            guard errno == ENOENT || errno == ECONNREFUSED else { return fail(String(cString: strerror(errno))) }
            return fail(String(localized: "Remote control is off. Add “remote-control = true” to \(Config.fileURL.path)."))
        }
        // The request: its length (4 bytes, little-endian), then each argument followed by a NUL.
        let payload: [UInt8] = arguments.flatMap { Array($0.utf8) + [0] }
        let length: [UInt8] = withUnsafeBytes(of: UInt32(payload.count).littleEndian) { Array($0) }
        guard writeAll(fd, length + payload) else {
            return fail(String(cString: strerror(errno)))
        }
        // The answer, until the app closes the socket: the exit code (1 byte), then the text to print.
        var answer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            answer += chunk[..<n]
        }
        guard let code = answer.first else { return fail(String(localized: "upaa did not answer.")) }
        (code == 0 ? FileHandle.standardOutput : FileHandle.standardError).write(Data(answer.dropFirst()))
        return Int32(code)
    }

    /// Calls body with the socket address for path, or returns nil if the path is too long for one.
    fileprivate static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(size)
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, size) } }
    }

    fileprivate static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            offset += n
        }
        return true
    }
}

/// One run of the upaa command, from its request to its one answer. The command going away (Ctrl-C) ends it, and
/// takes down a sheet still asking.
private final class Connection {
    private let fd: Int32
    private let source: DispatchSourceRead
    private var bytes: [UInt8] = []
    private var asked = false
    private let onEnd: (Connection) -> Void
    /// Takes down the sheet asking about this request.
    var withdraw: (() -> Void)?
    private(set) var isOpen = true

    init(fd: Int32, onRequest: @escaping (Connection, [String]) -> Void, onEnd: @escaping (Connection) -> Void) {
        self.fd = fd
        self.onEnd = onEnd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return self.end() }
            guard !self.asked else { return }
            self.bytes += chunk[..<n]
            guard self.bytes.count >= 4 else { return }
            let length = self.bytes[..<4].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            guard length <= 1 << 20 else { return self.answer(2, "upaa: request too long\n") }
            guard self.bytes.count >= 4 + length else { return }
            self.asked = true
            let arguments = self.bytes[4..<(4 + length)].split(separator: 0, omittingEmptySubsequences: false)
                .dropLast().map { String(decoding: $0, as: UTF8.self) }
            onRequest(self, Array(arguments))
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    /// Sends the exit code and the text, and closes the socket.
    func answer(_ code: UInt8, _ text: String) {
        end(sending: [code] + Array(text.utf8))
    }

    /// The bytes are written off the main thread, since a command that is stopped (Ctrl-Z) or does not read would
    /// otherwise hold the app once the answer is more than the socket holds.
    private func end(sending bytes: [UInt8] = []) {
        guard isOpen else { return }
        isOpen = false
        withdraw?()
        withdraw = nil
        onEnd(self)
        DispatchQueue.global().async { [fd, source] in
            _ = RemoteControl.writeAll(fd, bytes)
            source.cancel()
        }
    }
}
