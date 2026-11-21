import Cocoa
import WebKit

struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var playing: Bool
}

/// Sites that stay inside the app window (Spotify, and the logins it offers).
/// Links anywhere else open in your normal browser.
enum Hosts {
    static let inside = [
        "spotify.com", "scdn.co", "spotifycdn.com", "spotify.net",
        "google.com", "gstatic.com", "googleusercontent.com", "recaptcha.net",
        "facebook.com", "facebook.net", "apple.com", "hcaptcha.com"
    ]

    static func keepInside(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        return inside.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Forwards messages from the page without the web view keeping the controller alive.
final class ScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: PlayerWindowController?
    init(owner: PlayerWindowController) { self.owner = owner }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.handle(message)
    }
}

/// Messages from the loading screen's buttons.
final class SplashHandler: NSObject, WKScriptMessageHandler {
    weak var owner: PlayerWindowController?
    init(owner: PlayerWindowController) { self.owner = owner }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        owner?.handleSplash(action)
    }
}

final class PlayerWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {

    static let home = URL(string: "https://open.spotify.com/")!

    /// Which browser the window says it is.
    ///
    /// Default: the truth, i.e. this Mac's own Safari version (15.6.1 on Catalina). Spotify answers that
    /// with its "Unsupported browser" page, and the app then offers Firefox.
    ///
    /// The audit (AUDIT.md, Nov 2026) found why the earlier "current Safari" disguise didn't help:
    /// Spotify then sends its real player, whose code uses syntax Safari 15.6 can't parse (regex
    /// lookbehind, class static blocks), so the window goes blank. Pretending also sits badly with
    /// Spotify's rule against circumventing its technology. It's kept only as an opt-in experiment:
    ///   defaults write io.github.lolo737.catalinaplayer UserAgent modern
    ///   defaults delete io.github.lolo737.catalinaplayer UserAgent        (back to honest)
    static let modernUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"

    static let honestUserAgent: String = {
        let plist = "/Applications/Safari.app/Contents/Info.plist"
        let version = (NSDictionary(contentsOfFile: plist)?["CFBundleShortVersionString"] as? String)
            .flatMap { v in v.allSatisfy { $0.isNumber || $0 == "." } ? v : nil } ?? "15.6.1"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        // Safari has reported 10_15_7 on every macOS since Big Sur; report the real one only below that.
        let osToken = os.majorVersion == 10 ? "10_\(os.minorVersion)_\(os.patchVersion)" : "10_15_7"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X \(osToken)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }()

    static var userAgent: String {
        if SelfTest.identity == "honest" { return honestUserAgent }
        if SelfTest.identity == "modern" { return modernUserAgent }
        if let custom = UserDefaults.standard.string(forKey: "UserAgent"), !custom.isEmpty {
            return custom == "modern" ? modernUserAgent : custom
        }
        return honestUserAgent
    }

    static let signInHosts = ["accounts.spotify.com", "challenge.spotify.com", "login.spotify.com"]

    static func userAgent(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        // Off by default: switching identity mid-sign-in broke Spotify's redirects (white/black
        // screens) on a real Catalina Mac. Opt in with: defaults write ... HonestSignIn -bool true
        guard UserDefaults.standard.bool(forKey: "HonestSignIn") else { return userAgent }
        let isSignIn = signInHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        guard isSignIn else { return userAgent }
        if let custom = UserDefaults.standard.string(forKey: "LoginUserAgent"), !custom.isEmpty { return custom }
        return honestUserAgent
    }

    var onNowPlaying: ((NowPlaying) -> Void)?

    private var webView: WKWebView!
    var playerWebView: WKWebView { return webView }
    private var popups: [NSWindow] = []
    private var titleObservation: NSKeyValueObservation?
    private var pollTimer: Timer?
    private var warnedAboutPlayback = false
    private var lastInfo = NowPlaying(title: "", artist: "", playing: false)

    private var zoomLevel: Double {
        get {
            let z = UserDefaults.standard.double(forKey: "zoomLevel")
            return z == 0 ? 1.0 : z
        }
        set { UserDefaults.standard.set(newValue, forKey: "zoomLevel") }
    }

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Catalina Player"
        win.minSize = NSSize(width: 720, height: 480)
        win.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1)
        win.appearance = NSAppearance(named: .darkAqua)
        win.collectionBehavior = [.fullScreenPrimary]
        win.isReleasedWhenClosed = false
        win.center()
        win.setFrameAutosaveName("CatalinaPlayerMainWindow")
        self.init(window: win)
        win.delegate = self
        setUpWebView(in: win)
    }

    private func setUpWebView(in win: NSWindow) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let info = Bundle.main.infoDictionary
        Diagnostics.start(header: [
            "Catalina Player diagnostics (no cookie values, passwords or query values are recorded)",
            "app \((info?["CFBundleShortVersionString"] as? String) ?? "?")  macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)  WebKit \((Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] as? String) ?? "?")",
            "identity sent: \(PlayerWindowController.userAgent)",
            "compatibility shims: \(Compat.enabled ? "on" : "off")" + (SelfTest.isRunning ? "   SELF-TEST \(SelfTest.label)" : "")
        ])
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()      // stay logged in between launches
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Right-click → Inspect Element, so page errors can be read in the console.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.userContentController.add(ScriptHandler(owner: self), name: "catalina")
        // Order matters: errors first, then the feature probe (sees the engine unshimmed),
        // then the shim, then the end-of-document watchers.
        let ucc = config.userContentController
        ucc.addUserScript(WKUserScript(source: Diagnostics.errorScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: Diagnostics.featureScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if Compat.enabled {
            ucc.addUserScript(WKUserScript(source: Compat.shim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        ucc.addUserScript(WKUserScript(source: Scripts.watchForProblems, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: Diagnostics.renderScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let container = NSView(frame: win.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        let view = WKWebView(frame: container.bounds, configuration: config)
        view.autoresizingMask = [.width, .height]
        view.customUserAgent = PlayerWindowController.userAgent
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = self
        view.uiDelegate = self
        container.addSubview(view)
        win.contentView = container
        webView = view
        showSplash()

        titleObservation = view.observe(\.title, options: [.new]) { [weak self] _, _ in
            self?.refreshNowPlaying()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshNowPlaying()
        }
        view.load(URLRequest(url: PlayerWindowController.home))
    }

    // MARK: - Window

    @objc func showPlayer(_ sender: Any?) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window {
            sender.orderOut(nil)   // hide, keep playing
            return false
        }
        return true                // login pop-ups close normally
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing !== window else { return }
        popups.removeAll { $0 === closing }
    }

    // MARK: - Menu actions

    @objc func goHome(_ sender: Any?) { webView.load(URLRequest(url: PlayerWindowController.home)) }
    @objc func reloadPage(_ sender: Any?) { webView.reload() }
    @objc func goBackPage(_ sender: Any?) { if webView.canGoBack { webView.goBack() } }
    @objc func goForwardPage(_ sender: Any?) { if webView.canGoForward { webView.goForward() } }

    @objc func zoomInPage(_ sender: Any?) { setZoom(min(zoomLevel + 0.1, 2.0)) }
    @objc func zoomOutPage(_ sender: Any?) { setZoom(max(zoomLevel - 0.1, 0.6)) }
    @objc func actualSizePage(_ sender: Any?) { setZoom(1.0) }

    private func setZoom(_ value: Double) {
        zoomLevel = (value * 10).rounded() / 10
        applyZoom()
    }

    private func applyZoom() {
        webView.evaluateJavaScript(Scripts.setZoom(zoomLevel), completionHandler: nil)
    }

    @objc func playPause(_ sender: Any?) { control("toggle") }
    @objc func nextTrack(_ sender: Any?) { control("next") }
    @objc func previousTrack(_ sender: Any?) { control("prev") }

    func control(_ action: String) {
        webView.evaluateJavaScript(Scripts.control(action)) { [weak self] _, _ in
            self?.refreshNowPlaying()
        }
    }

    /// If this Mac's web engine can't play Spotify, Firefox can (and still supports 10.15).
    @objc func openInFirefox(_ sender: Any?) {
        let current = webView.url ?? PlayerWindowController.home
        let workspace = NSWorkspace.shared
        if let firefox = workspace.urlForApplication(withBundleIdentifier: "org.mozilla.firefox") {
            workspace.open([current], withApplicationAt: firefox,
                           configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            let alert = NSAlert()
            alert.messageText = "Firefox isn't installed"
            alert.informativeText = "Firefox still runs on macOS 10.15 and plays Spotify. Download it from mozilla.org, then try again."
            alert.addButton(withTitle: "Open mozilla.org")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: "https://www.mozilla.org/firefox/") {
                workspace.open(url)
            }
        }
    }

    // MARK: - Sign-in helpers

    // MARK: - Loading screen

    private var splash: WKWebView?
    private var splashReady = false
    private var splashQueue: [String] = []
    private var splashSession: Bool?
    private var splashLoaded = false
    private var splashDone = false
    private var loadStarted = Date()
    private var lastStatus = 0

    /// The retro loading screen. Every line it prints is a real check or a real event.
    @objc func showSplash(_ sender: Any? = nil) {
        guard splash == nil, let container = window?.contentView else { return }
        let config = WKWebViewConfiguration()
        config.userContentController.add(SplashHandler(owner: self), name: "catalinaSplash")
        let view = WKWebView(frame: container.bounds, configuration: config)
        view.autoresizingMask = [.width, .height]
        view.setValue(false, forKey: "drawsBackground")
        container.addSubview(view, positioned: .above, relativeTo: webView)
        view.loadHTMLString(Splash.html, baseURL: nil)
        splash = view
        splashReady = false; splashQueue = []; splashSession = nil; splashDone = false
        if sender != nil { splashLoaded = !webView.isLoading }

        let os = ProcessInfo.processInfo.operatingSystemVersion
        splashLog("$ open \"Catalina Player.app\"", cls: "mute")
        let osText = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        splashCall("window.cp.chip(\(PlayerWindowController.jsString(osText)))")
        splashLog(osText, "OK", pct: 6)
        let webkit = Bundle(for: WKWebView.self).infoDictionary
        let wkVersion = (webkit?["CFBundleVersion"] as? String) ?? "unknown"
        splashLog("WebKit \(wkVersion)", "OK", pct: 12)
        splashLog("identity: Safari \(PlayerWindowController.safariVersion(in: webView.customUserAgent ?? ""))", "SET", pct: 18)
        checkSession()
        if splashLoaded { splashLog("web player", "ALREADY LOADED", pct: 90); finishSplashIfReady() }
    }

    /// Called by the app delegate once MediaKeys has wired the remote commands.
    func reportMediaKeys(_ count: Int) {
        splashLog("media keys: \(count) of 5 commands wired", count == 5 ? "OK" : "PARTIAL",
                  cls: count == 5 ? "ok" : "warn", pct: 24)
    }

    static func jsString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: []),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())     // ["…"] → "…"
    }

    static func safariVersion(in agent: String) -> String {
        guard let r = agent.range(of: "Version/") else { return "?" }
        return String(agent[r.upperBound...].prefix { $0 != " " })
    }

    private func checkSession() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            let spotify = cookies.filter { $0.domain.hasSuffix("spotify.com") }
            self.splashLog("cookie store: \(cookies.count) cookies, \(spotify.count) from spotify.com", "READ", pct: 32)
            let now = Date()
            let session = spotify.first { $0.name == "sp_dc" && ($0.expiresDate.map { $0 > now } ?? true) }
            if let s = session {
                let f = DateFormatter(); f.dateFormat = "d MMM yyyy"
                let until = s.expiresDate.map { f.string(from: $0) } ?? "end of session"
                self.splashLog("sp_dc session, valid until \(until)", "FOUND", pct: 40)
            } else {
                self.splashLog("sp_dc session", "NONE", cls: "warn", pct: 40)
            }
            self.splashSession = session != nil
            self.splashCall("window.cp.session(\(session != nil))")
            self.finishSplashIfReady()
        }
    }

    private func splashLog(_ text: String, _ result: String = "", cls: String = "ok", pct: Int = 0) {
        let payload: [String: Any] = ["t": text, "r": result, "c": cls, "p": pct]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        splashCall("window.cp.log(\(json))")
    }

    private func splashCall(_ js: String) {
        guard splash != nil else { return }
        if splashReady { splash?.evaluateJavaScript(js, completionHandler: nil) } else { splashQueue.append(js) }
    }

    private func finishSplashIfReady() {
        guard splash != nil, !splashDone, splashLoaded, let session = splashSession else { return }
        splashDone = true
        splashCall("window.cp.done(\(session))")
    }

    /// Real navigation events for the log (main player window only, while the splash is up).
    private func splashNavigation(_ text: String, _ result: String, cls: String = "ok", pct: Int) {
        guard splash != nil, !splashDone else { return }
        splashLog(text, result, cls: cls, pct: pct)
    }

    private func hideSplash() {
        guard let view = splash else { return }
        splash = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "catalinaSplash")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            view.animator().alphaValue = 0
        }, completionHandler: { view.removeFromSuperview() })
        window?.makeFirstResponder(webView)
    }

    func handleSplash(_ action: String) {
        switch action {
        case "hello":
            splashReady = true
            let queued = splashQueue; splashQueue = []
            for js in queued { splash?.evaluateJavaScript(js, completionHandler: nil) }
        case "signIn": hideSplash(); signIn(nil)
        case "cookie": hideSplash(); signInWithCookie(nil)
        default: hideSplash()
        }
    }

    static let signInPage = URL(string: "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F")!

    /// The ordinary Spotify sign-in page: email, password or code, Google, Facebook, Apple.
    @objc func signIn(_ sender: Any?) {
        Diagnostics.log("SIGN-IN  front door opened")
        showPlayer(nil)
        webView.load(URLRequest(url: PlayerWindowController.signInPage))
    }

    /// Wipes cookies and cached pages, for when the sign-in gets stuck in a loop.
    /// Runs JavaScript typed into the console and describes the result.
    func evaluateForConsole(_ code: String, _ done: @escaping (String, Bool) -> Void) {
        webView.evaluateJavaScript(code) { result, error in
            if let error = error as NSError? {
                let message = (error.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? error.localizedDescription
                done(message + (message.contains("unsupported type") ? "  (tip: wrap it in JSON.stringify(...))" : ""), false)
                return
            }
            done(PlayerWindowController.describe(result), true)
        }
    }

    static func describe(_ value: Any?) -> String {
        guard let value = value else { return "undefined" }
        if let s = value as? String { return "\"" + s + "\"" }
        if let n = value as? NSNumber { return n.stringValue }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) { return text }
        return "\(value)"
    }

    @objc func showDiagnostics(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.fileURL])
    }

    @objc func clearSignInData(_ sender: Any?) {
        Diagnostics.log("SIGN-IN  cleared all website data")
        let store = webView.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            self?.webView.customUserAgent = PlayerWindowController.userAgent
            self?.webView.load(URLRequest(url: PlayerWindowController.home))
        }
    }

    /// Plan B: sign in once in Firefox, copy its Spotify "sp_dc" cookie, paste it here.
    @objc func signInWithCookie(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Sign in with a session cookie"
        alert.informativeText = "1. Sign in to open.spotify.com in Firefox.\n2. Press ⌥⌘I, open the Storage tab → Cookies → https://open.spotify.com.\n3. Copy the Value of the cookie named sp_dc and paste it below.\n\nIt's your own sign-in. Treat it like a password and don't share it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "sp_dc value"
        alert.accessoryView = field
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let cookie = HTTPCookie(properties: [
            .name: "sp_dc", .value: value, .domain: ".spotify.com", .path: "/",
            .secure: "TRUE", .expires: Date().addingTimeInterval(365 * 24 * 3600)
        ]) else { return }
        Diagnostics.log("SIGN-IN  side door: pasted sp_dc (\(value.count) characters)")
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.setCookie(cookie) { [weak self] in
            store.getAllCookies { cookies in
                let saved = cookies.filter { $0.name == "sp_dc" }
                Diagnostics.log("SIGN-IN  sp_dc stored: \(saved.isEmpty ? "NO" : "yes, domain " + saved.map { $0.domain }.joined(separator: ", "))")
            }
            self?.webView.customUserAgent = PlayerWindowController.userAgent
            self?.webView.load(URLRequest(url: PlayerWindowController.home))
        }
    }

    // MARK: - Messages from the page

    /// A string field from a page message, capped: any page in the window can post here.
    private static func field(_ body: [String: Any], _ key: String, _ fallback: String = "") -> String {
        guard let s = body[key] as? String else { return fallback }
        return s.count > 600 ? String(s.prefix(600)) + "…" : s
    }

    private static func list(_ body: [String: Any], _ key: String) -> [String] {
        return ((body[key] as? [Any]) ?? []).prefix(40).compactMap { ($0 as? String).map { String($0.prefix(120)) } }
    }

    func handle(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let f = { (key: String) in PlayerWindowController.field(body, key) }
        if type == "console" {
            Diagnostics.console(String(f("level").prefix(10)), f("text"))
            return
        }
        if type == "compat" {
            let added = PlayerWindowController.list(body, "added")
            Diagnostics.log("COMPAT  \(f("href")): shimmed \(added.count): " + added.joined(separator: ", "))
            return
        }
        if type == "drm" {
            let results = PlayerWindowController.list(body, "results")
            let legacy = (body["legacy"] as? Bool) == true ? "present" : "absent"
            let legacyFps = (body["legacyFps"] as? Bool) == true ? "yes" : "no"
            Diagnostics.log("DRM  " + results.joined(separator: "; ") + "  | WebKitMediaKeys \(legacy), legacy FairPlay \(legacyFps)")
            SelfTest.note("drm", results.joined(separator: "; "))
            return
        }
        if type == "render" {
            let line = "RENDER  \(f("href")): \(body["elements"] as? Int ?? -1) elements, \(body["textLength"] as? Int ?? -1) chars of text, root \(f("root"))"
                + ((body["unsupported"] as? Bool) == true ? ", says UNSUPPORTED BROWSER" : "")
                + ((body["loginForm"] as? Bool) == true ? ", login form present" : "")
                + ", title \"\(f("title"))\""
            Diagnostics.log(line)
            SelfTest.note("render", line)
            return
        }
        if type == "jsError" {
            var line = "JS  " + f("text").ifEmpty("error")
            let src = f("src")
            if !src.isEmpty {
                line += "  (" + (URL(string: src).map { Diagnostics.describe($0) } ?? src)
                if let n = body["line"] as? Int, n > 0 { line += ":\(n)" }
                line += ")"
            }
            Diagnostics.jsError(line)
            return
        }
        if type == "features" {
            let page = f("href")
            let syntax = PlayerWindowController.list(body, "syntax")
            let api = PlayerWindowController.list(body, "api")
            let css = PlayerWindowController.list(body, "css")
            Diagnostics.log("FEATURES  \(page): SYNTAX missing (no shim possible): " + (syntax.isEmpty ? "none" : syntax.joined(separator: "; ")))
            Diagnostics.log("FEATURES  \(page): API missing natively (shim \(Compat.enabled ? "on" : "off")): " + (api.isEmpty ? "none" : api.joined(separator: "; ")))
            Diagnostics.log("FEATURES  \(page): CSS missing: " + (css.isEmpty ? "none" : css.joined(separator: "; ")))
            return
        }
        if type == "problem" {
            Diagnostics.log("SPOTIFY SAYS  \(f("text"))")
            SelfTest.note("spotify says", f("text"))
        }
        if type == "problem" && !warnedAboutPlayback && !SelfTest.isRunning {
            warnedAboutPlayback = true
            let said = f("text").ifEmpty("it can't play here")
            let alert = NSAlert()
            alert.messageText = "Spotify won't play in this window"
            alert.informativeText = "Spotify says: \u{201C}\(said)\u{201D}.\n\nThis Mac's built-in web engine may not support Spotify's copy protection. Firefox does, and still runs on macOS 10.15."
            alert.addButton(withTitle: "Open in Firefox")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn { openInFirefox(nil) }
        }
    }

    // MARK: - Now playing

    func refreshNowPlaying() {
        webView.evaluateJavaScript(Scripts.nowPlaying) { [weak self] result, _ in
            guard let self = self,
                  let json = result as? String,
                  let data = json.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
            else { return }

            var title = (dict["title"] as? String) ?? ""
            var artist = (dict["artist"] as? String) ?? ""
            let pageTitle = (dict["docTitle"] as? String) ?? ""
            if title.isEmpty && pageTitle.contains(" \u{2022} ") {      // "Song • Artist"
                let parts = pageTitle.components(separatedBy: " \u{2022} ")
                title = parts[0]
                artist = parts.count > 1 ? parts[1] : ""
            }
            let info = NowPlaying(title: title, artist: artist, playing: (dict["playing"] as? Bool) ?? false)
            guard info != self.lastInfo else { return }
            self.lastInfo = info

            if info.title.isEmpty {
                self.window?.title = "Catalina Player"
            } else {
                self.window?.title = info.artist.isEmpty ? info.title : "\(info.title) \u{2014} \(info.artist)"
            }
            self.onNowPlaying?(info)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow); return
        }
        if navigationAction.targetFrame?.isMainFrame ?? true {
            let who = webView === self.webView ? "PAGE" : "POPUP"
            Diagnostics.log("\(who)  \(navigationAction.request.httpMethod ?? "GET") \(Diagnostics.describe(url))")
        }
        if scheme == "spotify" {                 // links meant for the desktop app: stay put
            decisionHandler(.cancel); return
        }
        if scheme == "mailto" || ((scheme == "http" || scheme == "https")
            && navigationAction.navigationType == .linkActivated && !Hosts.keepInside(url)) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel); return
        }
        // Switch identity between the player and the sign-in pages (see honestUserAgent).
        // Only for whole-page GET loads, so form submissions are never replayed.
        let wanted = PlayerWindowController.userAgent(for: url)
        if (scheme == "http" || scheme == "https"),
           navigationAction.targetFrame?.isMainFrame ?? true,
           (navigationAction.request.httpMethod ?? "GET").uppercased() == "GET",
           webView.customUserAgent != wanted {
            webView.customUserAgent = wanted
            decisionHandler(.cancel)
            webView.load(navigationAction.request)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView, let url = webView.url else { return }
        loadStarted = Date()
        splashNavigation("GET \(url.host ?? "")\(url.path)", "SENT", pct: 50)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if webView === self.webView, navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse {
            lastStatus = http.statusCode
        }
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            Diagnostics.log("  HTTP \(http.statusCode)  \(Diagnostics.describe(http.url))")
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        let ms = Int(Date().timeIntervalSince(loadStarted) * 1000)
        let status = lastStatus
        splashNavigation("first response in \(ms) ms", status > 0 ? "HTTP \(status)" : "OK",
                         cls: (status == 0 || status < 400) ? "ok" : "warn", pct: 70)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportLoadError(webView, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportLoadError(webView, error)
    }

    private func reportLoadError(_ webView: WKWebView, _ error: Error) {
        guard webView === self.webView else { return }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }   // our own redirects
        Diagnostics.log("LOAD ERROR  \(ns.domain) \(ns.code): \(ns.localizedDescription)")
        SelfTest.note("load error", "\(ns.code) \(ns.localizedDescription)")
        if ns.domain == NSURLErrorDomain && ns.code != NSURLErrorCancelled {
            showLoadError(ns)
        }
        splashNavigation("error \(ns.code): \(ns.localizedDescription)", "FAILED", cls: "warn", pct: 90)
        if !splashLoaded { splashLoaded = true; finishSplashIfReady() }
    }

    /// Without this, a failed first load leaves a silent black window.
    private func showLoadError(_ error: NSError) {
        let failing = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? PlayerWindowController.home
        let message = PlayerWindowController.jsString(error.localizedDescription)
        let retry = PlayerWindowController.jsString(failing.absoluteString)
        let html = """
        <!doctype html><meta charset="utf-8"><body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
        background:#0F1230;color:#FBEFDF;font:15px -apple-system,Helvetica,sans-serif;text-align:center">
        <div><div style="font-size:42px">&#9724;&#65038;</div><h2 style="font-weight:500">Can't reach Spotify</h2>
        <p id="m" style="opacity:.7;max-width:420px"></p>
        <button id="r" style="margin-top:12px;padding:9px 22px;border:0;background:#FBEFDF;color:#1A1230;font-weight:600">Try again</button>
        </div><script>document.getElementById('m').textContent=\(message);
        document.getElementById('r').onclick=function(){location.href=\(retry)}</script></body>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView {
            applyZoom()
            if !splashLoaded {
                let ms = Int(Date().timeIntervalSince(loadStarted) * 1000)
                splashNavigation("page loaded in \(ms) ms", "OK", pct: 90)
                splashLoaded = true
                finishSplashIfReady()
            }
        }
    }

    // MARK: - WKUIDelegate (login pop-ups, alerts)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
           !Hosts.keepInside(url) {
            NSWorkspace.shared.open(url)
            return nil
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .darkAqua)
        win.title = "Log in"
        let popup = WKWebView(frame: win.contentView?.bounds ?? .zero, configuration: configuration)
        popup.autoresizingMask = [.width, .height]
        popup.customUserAgent = navigationAction.request.url.map(PlayerWindowController.userAgent(for:))
            ?? PlayerWindowController.userAgent
        popup.navigationDelegate = self
        popup.uiDelegate = self
        win.contentView = popup
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        popups.append(win)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let win = webView.window, win !== window { win.close() }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        if SelfTest.isRunning { Diagnostics.log("PAGE ALERT  \(message.prefix(200))"); completionHandler(); return }
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}
