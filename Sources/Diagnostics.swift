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
      function clean(t) { return String(t).replace(/[A-Za-z0-9_\-\.]{40,}/g, '[redacted]').slice(0, 600); }
      window.addEventListener('error', function (e) {
        if (e.target && e.target !== window && (e.target.src || e.target.href)) {
          send({ type: 'jsError', text: clean('failed to load ' + (e.target.tagName || '') + ' ' + String(e.target.src || e.target.href).split('?')[0].split('#')[0]) });
          return;
        }
        send({ type: 'jsError', text: clean(e.message || 'error'), src: String(e.filename || '').split('?')[0].split('#')[0].slice(0, 300), line: e.lineno || 0 });
      }, true);
      // Mirror console.log/info/warn/error/debug to the app. Long token-like strings are
      // blanked out (clean, above) before they leave the page, so nothing secret reaches the log.
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
        send({ type: 'jsError', text: clean('unhandled promise: ' + String((r && (r.message || r)) || '?')) });
      });
    })();
    """#

    /// Injected at document start, before the compatibility shim, so it sees the engine as it
    /// really is. Splits what's missing into SYNTAX (code using it can't even be parsed: no shim
    /// can help) and API (missing functions: Compat.shim can fill most of these). Also asks the
    /// engine which copy-protection key systems it will grant, without playing anything.
    static let featureScript = #"""
    (function () {
      function send(o) { try { window.webkit.messageHandlers.catalina.postMessage(o); } catch (e) {} }
      var syntax = [], api = [], css = [];
      function parses(src) { try { new Function(src); return true; } catch (e) { return false; } }
      function check(list, name, ok) { try { if (!ok()) list.push(name); } catch (e) { list.push(name); } }

      check(syntax, 'RegExp lookbehind (Safari 16.4)', function () { return parses('return /(?<=a)b/'); });
      check(syntax, 'class static blocks (Safari 16.4)', function () { return parses('class A { static { } }'); });
      check(syntax, 'RegExp v flag (Safari 17)', function () { return parses('return /[a]/v'); });
      check(syntax, 'duplicate named groups (Safari 17)', function () { return parses('return /(?<y>a)|(?<y>b)/'); });
      check(syntax, 'private #x in obj (Safari 15)', function () { return parses('class A { #x; static t(o) { return #x in o; } }'); });
      check(syntax, 'import maps (Safari 16.4)', function () { return !!(window.HTMLScriptElement && HTMLScriptElement.supports && HTMLScriptElement.supports('importmap')); });

      check(api, 'Array.at (Safari 15.4)', function () { return !!Array.prototype.at; });
      check(api, 'structuredClone (Safari 15.4)', function () { return typeof structuredClone === 'function'; });
      check(api, 'Array.findLast (Safari 15.4)', function () { return !!Array.prototype.findLast; });
      check(api, 'Array.toSorted (Safari 16)', function () { return !!Array.prototype.toSorted; });
      check(api, 'AbortSignal.timeout (Safari 16)', function () { return !!(window.AbortSignal && AbortSignal.timeout); });
      check(api, 'Array.fromAsync (Safari 16.4)', function () { return !!Array.fromAsync; });
      check(api, 'String.isWellFormed (Safari 16.4)', function () { return !!String.prototype.isWellFormed; });
      check(api, 'Set.union (Safari 17)', function () { return !!Set.prototype.union; });
      check(api, 'Object.groupBy (Safari 17.4)', function () { return !!Object.groupBy; });
      check(api, 'Promise.withResolvers (Safari 17.4)', function () { return !!Promise.withResolvers; });
      check(api, 'AbortSignal.any (Safari 17.4)', function () { return !!(window.AbortSignal && AbortSignal.any); });
      check(api, 'Element.checkVisibility (Safari 17.4)', function () { return !!(window.Element && Element.prototype.checkVisibility); });

      check(css, ':has() (Safari 15.4)', function () { return CSS.supports('selector(:has(a))'); });
      check(css, '@layer (Safari 15.4)', function () { return typeof CSSLayerBlockRule !== 'undefined'; });
      check(css, 'container queries (Safari 16)', function () { return CSS.supports('container-type: inline-size'); });
      check(css, 'nesting (Safari 16.5)', function () { return CSS.supports('selector(&)'); });
      check(css, 'subgrid (Safari 16)', function () { return CSS.supports('grid-template-columns: subgrid'); });
      check(css, 'dvh units (Safari 15.4)', function () { return CSS.supports('height: 100dvh'); });

      send({ type: 'features', syntax: syntax, api: api, css: css, href: location.host + location.pathname });

      // Copy protection: which key systems will this engine grant to this page? (Nothing is played.)
      if (window.top === window && location.protocol === 'https:' && !window.__catalinaDRMProbed) {
        window.__catalinaDRMProbed = true;
        var results = [];
        var legacy = !!window.WebKitMediaKeys;
        var legacyFps = false;
        try { legacyFps = !!(window.WebKitMediaKeys && WebKitMediaKeys.isTypeSupported('com.apple.fps.1_0', 'video/mp4')); } catch (e) {}
        var systems = [
          ['com.apple.fps', [{ initDataTypes: ['sinf'], audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"' }] },
                             { initDataTypes: ['skd'], audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"' }] }]],
          ['com.widevine.alpha', [{ initDataTypes: ['cenc'], audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"' }] }]],
          ['org.w3.clearkey', [{ initDataTypes: ['cenc', 'keyids'], audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"' }] }]]
        ];
        if (!navigator.requestMediaKeySystemAccess) {
          send({ type: 'drm', results: ['requestMediaKeySystemAccess: not present'], legacy: legacy, legacyFps: legacyFps });
        } else {
          var pending = systems.length;
          systems.forEach(function (sys) {
            navigator.requestMediaKeySystemAccess(sys[0], sys[1]).then(function () {
              results.push(sys[0] + ': granted');
            }, function (e) {
              results.push(sys[0] + ': refused (' + (e && (e.name || e.message) || 'error') + ')');
            }).then(function () {
              if (--pending === 0) send({ type: 'drm', results: results, legacy: legacy, legacyFps: legacyFps });
            });
          });
        }
      }
    })();
    """#

    /// Injected at document end: 12 seconds later, reports whether the page actually drew
    /// anything. A page whose scripts failed to parse usually leaves an empty root: a blank window.
    static let renderScript = #"""
    (function () {
      if (window.top !== window) return;
      setTimeout(function () {
        try {
          var body = document.body, text = body ? (body.innerText || body.textContent || '') : '';
          var shown = document.querySelectorAll('body *').length;
          var root = document.querySelector('#main, #root, [data-testid="root"], [data-testid="login-container"], main');
          window.webkit.messageHandlers.catalina.postMessage({
            type: 'render',
            href: location.host + location.pathname,
            title: String(document.title || '').slice(0, 80),
            elements: shown,
            textLength: text.trim().length,
            root: root ? (root.id ? '#' + root.id : root.tagName.toLowerCase()) + ' with ' + root.querySelectorAll('*').length + ' elements' : 'none found',
            unsupported: /Unsupported browser|unavailable on this browser/i.test(text),
            loginForm: !!document.querySelector('input[type=password], input#login-username, input[name=username], input[type=email]'),
            compat: (window.__catalinaCompat || []).length
          });
        } catch (e) {}
      }, 12000);
    })();
    """#
}
