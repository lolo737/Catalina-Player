import Cocoa
import WebKit

/// Unattended run for CI and for the owner's own test script:
///
///   "Catalina Player.app/Contents/MacOS/CatalinaPlayer" --selftest 45 --ua honest
///
/// Loads the player, waits, then writes a summary (JSON) and a snapshot (PNG) of the web view
/// next to the diagnostics log, and quits. No sign-in, nothing played, no alerts shown.
///   --selftest [seconds]   how long to wait before summarising (default 45)
///   --ua honest|modern     which browser identity to send (Safari 15.6 vs the default disguise)
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

    static var label: String { "identity=\(identity ?? "default") wait=\(Int(seconds))s" }

    private static var notes: [String: [String]] = [:]

    static func note(_ key: String, _ value: String) {
        guard isRunning else { return }
        notes[key, default: []].append(value)
    }

    static func start(_ player: PlayerWindowController) {
        guard isRunning else { return }
        Diagnostics.log("SELF-TEST  started, \(label)")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            player.selfTestSummary { page, image in
                let logs = Diagnostics.fileURL.deletingLastPathComponent()
                var summary: [String: Any] = [
                    "label": label,
                    "identity": PlayerWindowController.userAgent,
                    "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                    "page": page,
                    "notes": notes
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
