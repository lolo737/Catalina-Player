import Foundation

/// A plain-text log of what happens during a session: page loads and redirects, HTTP status,
/// JavaScript errors, missing browser features, and sign-in steps. It never records cookie
/// values, passwords or query-string values, so it's safe to send to someone helping you.
/// File: ~/Library/Logs/CatalinaPlayer.log (started fresh at each launch).
enum Diagnostics {
    static let fileURL: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let logs = library.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: nil)
        return logs.appendingPathComponent("CatalinaPlayer.log")
    }()

    /// Every line, as written (the console window listens here).
    static var onLine: ((String) -> Void)?

    private static var started = false
    private static var jsErrors = 0
    private static var consoleLines = 0
    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func start(header: [String]) {
        started = true
        let text = header.joined(separator: "\n") + "\n" + String(repeating: "-", count: 60) + "\n"
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        header.forEach { onLine?($0) }
    }

    static func log(_ line: String) {
        guard started else { return }
        let stamped = "\(clock.string(from: Date()))  \(line)"
        onLine?(stamped)
        let entry = stamped + "\n"
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    }

    /// JavaScript errors can repeat endlessly; keep the first 80.
    static func jsError(_ line: String) {
        jsErrors += 1
        if jsErrors <= 80 { log(line) } else if jsErrors == 81 { log("(further JavaScript errors not logged)") }
    }

    /// Spotify's own console output; it can be chatty, so keep the first 1,500 lines.
    static func console(_ level: String, _ text: String) {
        consoleLines += 1
        if consoleLines <= 1500 { log("CONSOLE \(level)  \(text)") }
        else if consoleLines == 1501 { log("(further console output not logged)") }
    }

    /// host + path, plus the names (never the values) of any query parameters.
    static func describe(_ url: URL?) -> String {
        guard let url = url else { return "(none)" }
        var text = (url.host ?? url.scheme ?? "") + url.path
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty {
            text += " ?" + items.map { $0.name }.joined(separator: ",")
        }
        return text
    }

    /// Injected at document start: reports JavaScript errors and failed resources to the app.
    static let errorScript = #"""
    (function () {
      function send(o) { try { window.webkit.messageHandlers.catalina.postMessage(o); } catch (e) {} }
      window.addEventListener('error', function (e) {
        if (e.target && e.target !== window && (e.target.src || e.target.href)) {
          send({ type: 'jsError', text: 'failed to load ' + (e.target.tagName || '') + ' ' + String(e.target.src || e.target.href).split('?')[0] });
          return;
        }
        send({ type: 'jsError', text: String(e.message || 'error'), src: String(e.filename || '').split('?')[0], line: e.lineno || 0 });
      }, true);
      // Mirror console.log/info/warn/error/debug to the app. Long token-like strings are
      // blanked out before they leave the page, so nothing secret reaches the log.
      function clean(t) { return String(t).replace(/[A-Za-z0-9_\-\.]{40,}/g, '[redacted]').slice(0, 600); }
      ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
        var original = console[level];
        if (typeof original !== 'function') return;
        console[level] = function () {
          try {
            var parts = [];
            for (var i = 0; i < arguments.length; i++) {
              var a = arguments[i], t;
              if (typeof a === 'string') t = a;
              else if (a instanceof Error) t = a.name + ': ' + a.message;
              else { try { t = JSON.stringify(a); } catch (e) { t = undefined; } if (t === undefined) t = String(a); }
              parts.push(t);
            }
            send({ type: 'console', level: level, text: clean(parts.join(' ')) });
          } catch (e) {}
          return original.apply(console, arguments);
        };
      });
      window.addEventListener('unhandledrejection', function (e) {
        var r = e.reason;
        send({ type: 'jsError', text: 'unhandled promise: ' + String((r && (r.message || r)) || '?') });
      });
    })();
    """#

    /// Injected at document end: lists modern browser features this engine lacks.
    static let featureScript = #"""
    (function () {
      var missing = [];
      function need(name, ok) { try { if (!ok()) missing.push(name); } catch (e) { missing.push(name); } }
      need('Array.prototype.at (Safari 15.4)', function () { return !!Array.prototype.at; });
      need('structuredClone (Safari 15.4)', function () { return typeof structuredClone === 'function'; });
      need('Array.prototype.findLast (Safari 15.4)', function () { return !!Array.prototype.findLast; });
      need('Array.prototype.toSorted (Safari 16)', function () { return !!Array.prototype.toSorted; });
      need('RegExp lookbehind (Safari 16.4)', function () { return new RegExp('(?<=a)b').test('ab'); });
      need('Array.fromAsync (Safari 16.4)', function () { return !!Array.fromAsync; });
      need('Set.prototype.union (Safari 17)', function () { return !!Set.prototype.union; });
      need('RegExp v flag (Safari 17)', function () { return new RegExp('[a]', 'v').test('a'); });
      need('Object.groupBy (Safari 17.4)', function () { return !!Object.groupBy; });
      need('Promise.withResolvers (Safari 17.4)', function () { return !!Promise.withResolvers; });
      need('CSS :has() (Safari 15.4)', function () { return CSS.supports('selector(:has(a))'); });
      need('CSS nesting (Safari 16.5)', function () { return CSS.supports('selector(&)'); });
      need('CSS container queries (Safari 16)', function () { return CSS.supports('container-type: inline-size'); });
      need('EME / copy protection', function () { return !!(navigator.requestMediaKeySystemAccess || window.WebKitMediaKeys); });
      try { window.webkit.messageHandlers.catalina.postMessage({ type: 'features', missing: missing, href: location.host + location.pathname }); } catch (e) {}
    })();
    """#
}
