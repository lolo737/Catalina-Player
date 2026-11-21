import Cocoa
import WebKit

/// Unattended run for CI and for the owner's own test script:
///
///   "Catalina Player.app/Contents/MacOS/CatalinaPlayer" --selftest 45 --ua honest
///
/// Loads the player, waits, then writes a summary (JSON) and a snapshot (PNG) of the web view
/// next to the diagnostics log, and quits. No sign-in, nothing played, no alerts shown.
///   --selftest [seconds]   how long to wait before summarising (default 45)
///   --ua honest|modern     which browser identity to send (this Mac's real Safari vs the disguise)
///   --home <url>           load this instead of open.spotify.com (e.g. an unreachable host)
///   --hostile              halfway through, flood the app's message handler with malformed,
///                          oversized and repeated messages, as a misbehaving page could
enum SelfTest {
    private static let args = CommandLine.arguments

    static var isRunning: Bool { args.contains("--selftest") }

    static var identity: String? {
        guard let i = args.firstIndex(of: "--ua"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var seconds: Double {
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count, let n = Double(args[i + 1]) else { return 45 }
        return max(5, min(n, 600))
    }

    static var homeOverride: URL? {
        guard let i = args.firstIndex(of: "--home"), i + 1 < args.count else { return nil }
        return URL(string: args[i + 1])
    }

    static var hostile: Bool { args.contains("--hostile") }

    /// What a hostile or buggy page could send to window.webkit.messageHandlers.catalina.
    static let hostileJS = #"""
    (function () {
      var h = window.webkit.messageHandlers.catalina, big = 'x'.repeat(1000000), sent = 0;
      var junk = [null, 42, 'text', [1, 2, 3], {}, { type: 123 }, { type: null }, { type: 'nope' },
        { type: 'console', level: big, text: big }, { type: 'jsError', text: { nested: true }, src: 99, line: 'NaN' },
        { type: 'jsError', text: big, src: big, line: 1e308 },
        { type: 'features', syntax: 'not-a-list', api: [1, null, {}], css: new Array(5000).fill(big.slice(0, 200)) },
        { type: 'drm', results: new Array(10000).fill('z'.repeat(1000)), legacy: 'yes' },
        { type: 'render', elements: 'many', textLength: -1, root: big, unsupported: 'true', title: big },
        { type: 'compat', added: big }, { type: 'problem', text: big }, { type: 'problem', text: 'again' }];
      junk.forEach(function (m) { try { h.postMessage(m); sent++; } catch (e) {} });
      for (var i = 0; i < 5000; i++) { try { h.postMessage({ type: 'console', level: 'log', text: 'flood ' + i }); sent++; } catch (e) {} }
      for (var j = 0; j < 500; j++) { try { h.postMessage({ type: 'jsError', text: 'error flood ' + j }); sent++; } catch (e) {} }
      return sent;
    })()
    """#

    static var label: String { "identity=\(identity ?? "default") wait=\(Int(seconds))s" }

    private static var notes: [String: [String]] = [:]

    static func note(_ key: String, _ value: String) {
        guard isRunning else { return }
        notes[key, default: []].append(value)
    }

    static func start(_ player: PlayerWindowController) {
        guard isRunning else { return }
        Diagnostics.log("SELF-TEST  started, \(label)" + (hostile ? " hostile" : "") + (homeOverride.map { " home=\($0.host ?? "?")" } ?? ""))
        if hostile {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds / 2) {
                player.playerWebView.evaluateJavaScript(hostileJS) { sent, error in
                    Diagnostics.log("SELF-TEST  hostile messages posted: \(sent ?? error?.localizedDescription ?? "?")")
                    note("hostile", "posted \(sent ?? "?")")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            player.selfTestSummary { page, image in
                let logs = Diagnostics.fileURL.deletingLastPathComponent()
                var summary: [String: Any] = [
                    "label": label,
                    "identity": PlayerWindowController.userAgent,
                    "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                    "page": page,
                    "notes": notes,
                    "log": logStats()
                ]
                if let image = image, let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    let url = logs.appendingPathComponent("CatalinaPlayer-selftest.png")
                    try? png.write(to: url)
                    summary["snapshot"] = url.lastPathComponent
                }
                if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted]) {
                    try? data.write(to: logs.appendingPathComponent("CatalinaPlayer-selftest.json"))
                }
                Diagnostics.log("SELF-TEST  finished, summary written")
                NSApp.terminate(nil)
            }
        }
    }
}

/// Size of the diagnostics log, to check its caps held.
private func logStats() -> [String: Any] {
    guard let text = try? String(contentsOf: Diagnostics.fileURL, encoding: .utf8) else { return ["error": "unreadable"] }
    let lines = text.components(separatedBy: "\n")
    return [
        "bytes": text.utf8.count,
        "lines": lines.count,
        "longestLine": lines.map { $0.count }.max() ?? 0,
        "consoleLines": lines.filter { $0.contains("  CONSOLE ") }.count,
        "jsErrorLines": lines.filter { $0.contains("  JS  ") }.count
    ]
}

extension PlayerWindowController {
    /// What the page looks like right now, plus a picture of it.
    func selfTestSummary(_ done: @escaping ([String: Any], NSImage?) -> Void) {
        let js = """
        JSON.stringify({
          href: location.host + location.pathname,
          title: document.title,
          elements: document.querySelectorAll('body *').length,
          text: (document.body ? (document.body.innerText || document.body.textContent || '') : '').replace(/\\s+/g, ' ').trim().slice(0, 400),
          unsupported: /Unsupported browser|unavailable on this browser/i.test(document.body ? document.body.textContent : ''),
          loginButton: !!document.querySelector('[data-testid="login-button"], a[href*="accounts.spotify.com"]'),
          playerBar: !!document.querySelector('[data-testid="now-playing-widget"], [data-testid="control-button-playpause"]'),
          compat: window.__catalinaCompat || []
        })
        """
        playerWebView.evaluateJavaScript(js) { [weak self] result, error in
            var page: [String: Any] = [:]
            if let s = result as? String, let d = s.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: d, options: [])) as? [String: Any] {
                page = obj
            } else if let error = error {
                page = ["error": error.localizedDescription]
            }
            guard let view = self?.playerWebView else { done(page, nil); return }
            view.takeSnapshot(with: nil) { image, _ in done(page, image) }
        }
    }
}
