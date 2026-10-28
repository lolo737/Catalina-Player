import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var player: PlayerWindowController!
    private var mediaKeys: MediaKeys!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let console = DebugConsole.shared
        Diagnostics.onLine = { console.appendLogLine($0) }
        player = PlayerWindowController()
        console.runJavaScript = { [weak player] code, done in player?.evaluateForConsole(code, done) }
        mediaKeys = MediaKeys(player: player)
        player.reportMediaKeys(mediaKeys.registered)
        player.onNowPlaying = { [weak self] info in
            self?.mediaKeys.update(info)
        }
        NSApp.mainMenu = MainMenu.build(player: player)
        player.showWindow(nil)
        if DebugConsole.openAtLaunch {
        console.show(nil)
        if let main = player.window, let side = console.window {
            side.setFrameTopLeftPoint(NSPoint(x: main.frame.minX + 40, y: main.frame.minY + 200))
        }
        player.window?.makeKeyAndOrderFront(nil)
        console.window?.orderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // Closing the window hides it; the music keeps playing until you quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // Clicking the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { player.showPlayer(nil) }
        return true
    }
}
