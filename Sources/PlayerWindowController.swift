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

final class PlayerWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {

    static let home = URL(string: "https://open.spotify.com/")!

    /// Spotify turns away browsers it considers too old ("Unsupported browser"), judging by the
    /// version number in this string. Every current Safari still reports "Mac OS X 10_15_7",
    /// so this reads as a recent Safari. The engine underneath is still Catalina's WebKit.
    /// If Spotify ever moves the goalposts, override it without rebuilding:
    ///   defaults write io.github.lolo737.catalinaplayer UserAgent "Mozilla/5.0 (...)"
    static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"

    static var userAgent: String {
        if let custom = UserDefaults.standard.string(forKey: "UserAgent"), !custom.isEmpty { return custom }
        return defaultUserAgent
    }

    /// The sign-in pages run bot checks that compare what the browser claims to be with how it
    /// actually behaves. Claiming Safari 18 on a Safari 15 engine looks like a bot, and the login
    /// quietly loops. So the sign-in pages get the honest answer: Safari 15.6 on Catalina.
    /// Override with: defaults write io.github.lolo737.catalinaplayer LoginUserAgent "..."
    static let honestUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.6.1 Safari/605.1.15"

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
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()      // stay logged in between launches
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Right-click → Inspect Element, so page errors can be read in the console.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.userContentController.add(ScriptHandler(owner: self), name: "catalina")
        config.userContentController.addUserScript(
            WKUserScript(source: Scripts.watchForProblems, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let view = WKWebView(frame: win.contentView?.bounds ?? .zero, configuration: config)
        view.autoresizingMask = [.width, .height]
        view.customUserAgent = PlayerWindowController.userAgent
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = self
        view.uiDelegate = self
        win.contentView = view
        webView = view

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

    /// Wipes cookies and cached pages, for when the sign-in gets stuck in a loop.
    @objc func clearSignInData(_ sender: Any?) {
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
        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak self] in
            self?.webView.customUserAgent = PlayerWindowController.userAgent
            self?.webView.load(URLRequest(url: PlayerWindowController.home))
        }
    }

    // MARK: - Messages from the page

    func handle(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "problem" && !warnedAboutPlayback {
            warnedAboutPlayback = true
            let said = (body["text"] as? String) ?? "it can't play here"
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView { applyZoom() }
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
