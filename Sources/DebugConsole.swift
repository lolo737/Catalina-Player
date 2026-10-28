import Cocoa

/// A live console window: the diagnostics log as it happens, Spotify's own console output,
/// and a command line that runs JavaScript inside the Spotify page.
/// View → Debug Console (⌥⌘C). View → Open Console at Launch keeps it open from the start.
final class DebugConsole: NSWindowController, NSTextFieldDelegate {

    static let shared = DebugConsole()

    /// Set by the app: runs JavaScript in the player page and reports (text, succeeded).
    var runJavaScript: ((String, @escaping (String, Bool) -> Void) -> Void)?

    private var textView: NSTextView!
    private var input: NSTextField!
    private var history: [String] = []
    private var historyIndex = 0
    private let font = NSFont(name: "Menlo", size: 11) ?? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 460),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Catalina Player \u{2014} Console"
        win.appearance = NSAppearance(named: .darkAqua)
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 480, height: 220)
        win.center()
        win.setFrameAutosaveName("CatalinaPlayerConsole")
        self.init(window: win)
        build(in: win)
    }

    private func build(in win: NSWindow) {
        guard let content = win.contentView else { return }
        let bounds = content.bounds
        let barHeight: CGFloat = 42

        let scroll = NSScrollView(frame: NSRect(x: 0, y: barHeight, width: bounds.width, height: bounds.height - barHeight))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Palette.background

        let tv = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tv.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.backgroundColor = Palette.background
        tv.textContainerInset = NSSize(width: 10, height: 10)
        scroll.documentView = tv
        content.addSubview(scroll)
        textView = tv

        let bar = NSView(frame: NSRect(x: 0, y: 0, width: bounds.width, height: barHeight))
        bar.autoresizingMask = [.width]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Palette.bar.cgColor
        content.addSubview(bar)

        let prompt = NSTextField(labelWithString: "\u{203A}")
        prompt.font = NSFont(name: "Menlo-Bold", size: 14) ?? font
        prompt.textColor = Palette.orange
        prompt.frame = NSRect(x: 10, y: 10, width: 14, height: 22)
        bar.addSubview(prompt)

        let field = NSTextField(frame: NSRect(x: 26, y: 9, width: bounds.width - 26 - 186, height: 24))
        field.autoresizingMask = [.width]
        field.font = NSFont(name: "Menlo", size: 12) ?? font
        field.placeholderString = "JavaScript to run in the Spotify page, then Return  (↑ ↓ history)"
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(runInput(_:))
        bar.addSubview(field)
        input = field

        let copy = NSButton(title: "Copy All", target: self, action: #selector(copyAll(_:)))
        copy.bezelStyle = .rounded
        copy.frame = NSRect(x: bounds.width - 180, y: 7, width: 90, height: 28)
        copy.autoresizingMask = [.minXMargin]
        bar.addSubview(copy)

        let clear = NSButton(title: "Clear", target: self, action: #selector(clear(_:)))
        clear.bezelStyle = .rounded
        clear.frame = NSRect(x: bounds.width - 88, y: 7, width: 80, height: 28)
        clear.autoresizingMask = [.minXMargin]
        bar.addSubview(clear)

        append("Catalina Player console. Everything below is also saved to ~/Library/Logs/CatalinaPlayer.log", color: Palette.dim)
    }

    // MARK: - Output

    enum Palette {
        static let background = NSColor(calibratedRed: 0.043, green: 0.043, blue: 0.11, alpha: 1)
        static let bar = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.15, alpha: 1)
        static let text = NSColor(calibratedRed: 0.98, green: 0.94, blue: 0.87, alpha: 1)
        static let dim = NSColor(calibratedWhite: 1, alpha: 0.45)
        static let orange = NSColor(calibratedRed: 0.96, green: 0.6, blue: 0.32, alpha: 1)
        static let red = NSColor(calibratedRed: 1, green: 0.45, blue: 0.42, alpha: 1)
        static let green = NSColor(calibratedRed: 0.49, green: 1, blue: 0.69, alpha: 1)
        static let cyan = NSColor(calibratedRed: 0.5, green: 0.85, blue: 1, alpha: 1)
    }

    /// Colour a diagnostics line by what it is.
    func appendLogLine(_ line: String) {
        let body = line.count > 14 ? String(line.dropFirst(14)) : line     // after the timestamp
        let color: NSColor
        if body.hasPrefix("JS") || body.hasPrefix("LOAD ERROR") || body.hasPrefix("CONSOLE error") { color = Palette.red }
        else if body.hasPrefix("CONSOLE warn") || body.hasPrefix("FEATURES") || body.hasPrefix("SPOTIFY SAYS") { color = Palette.orange }
        else if body.hasPrefix("SIGN-IN") { color = Palette.green }
        else if body.hasPrefix("CONSOLE") { color = Palette.dim }
        else { color = Palette.text }
        append(line, color: color)
    }

    func append(_ line: String, color: NSColor) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.append(line, color: color) }
            return
        }
        guard let storage = textView?.textStorage else { return }
        storage.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .foregroundColor: color]))
        if storage.length > 600_000 {                                   // keep it light
            storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - 400_000))
        }
        textView.scrollToEndOfDocument(nil)
    }

    // MARK: - Actions

    static var openAtLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: "OpenConsoleAtLaunch") }
        set { UserDefaults.standard.set(newValue, forKey: "OpenConsoleAtLaunch") }
    }

    @objc func toggleOpenAtLaunch(_ sender: NSMenuItem) {
        DebugConsole.openAtLaunch.toggle()
        sender.state = DebugConsole.openAtLaunch ? .on : .off
        if DebugConsole.openAtLaunch { show(nil) }
    }

    @objc func toggle(_ sender: Any?) {
        if window?.isVisible == true { window?.orderOut(nil) } else { show(nil) }
    }

    @objc func show(_ sender: Any?) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(input)
    }

    @objc private func runInput(_ sender: Any?) {
        let code = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        history.append(code)
        historyIndex = history.count
        input.stringValue = ""
        append("\u{203A} " + code, color: Palette.cyan)
        guard let run = runJavaScript else { append("  (the player isn't ready)", color: Palette.red); return }
        run(code) { [weak self] text, ok in
            self?.append((ok ? "\u{2190} " : "\u{2715} ") + text, color: ok ? Palette.text : Palette.red)
        }
    }

    @objc private func copyAll(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    @objc private func clear(_ sender: Any?) {
        textView.string = ""
    }

    // ↑ / ↓ walk through earlier commands.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !history.isEmpty else { return false }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            historyIndex = max(0, historyIndex - 1)
        } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
            historyIndex = min(history.count, historyIndex + 1)
        } else {
            return false
        }
        input.stringValue = historyIndex < history.count ? history[historyIndex] : ""
        return true
    }
}
