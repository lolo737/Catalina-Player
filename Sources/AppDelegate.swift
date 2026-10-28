import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var player: PlayerWindowController!
    private var mediaKeys: MediaKeys!

    func applicationDidFinishLaunching(_ notification: Notification) {
        player = PlayerWindowController()
        mediaKeys = MediaKeys(player: player)
        player.reportMediaKeys(mediaKeys.registered)
        player.onNowPlaying = { [weak self] info in
            self?.mediaKeys.update(info)
        }
        NSApp.mainMenu = MainMenu.build(player: player)
        player.showWindow(nil)
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
