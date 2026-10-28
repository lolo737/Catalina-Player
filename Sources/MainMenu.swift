import Cocoa

/// The menu bar: Catalina Player, Edit, View, Playback, Window.
enum MainMenu {

    static func build(player: PlayerWindowController) -> NSMenu {
        let main = NSMenu()

        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
            menuItem.keyEquivalentModifierMask = modifiers
            menuItem.target = target
            return menuItem
        }

        @discardableResult
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let top = NSMenuItem()
            let menu = NSMenu(title: title)
            for i in items { menu.addItem(i) }
            top.submenu = menu
            main.addItem(top)
            return menu
        }

        let arrowRight = String(Character(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!))
        let arrowLeft = String(Character(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!))

        submenu("Catalina Player", [
            item("About Catalina Player", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Sign In…", #selector(PlayerWindowController.signIn(_:)), "l", [.command, .shift], target: player),
            item("Sign In with a Session Cookie…", #selector(PlayerWindowController.signInWithCookie(_:)), target: player),
            item("Sign Out and Clear Data", #selector(PlayerWindowController.clearSignInData(_:)), target: player),
            item("Show Loading Screen", #selector(PlayerWindowController.showSplash(_:)), target: player),
            item("Show Diagnostics Log", #selector(PlayerWindowController.showDiagnostics(_:)), target: player),
            .separator(),
            item("Hide Catalina Player", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Catalina Player", #selector(NSApplication.terminate(_:)), "q")
        ])

        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a")
        ])

        submenu("View", [
            item("Home", #selector(PlayerWindowController.goHome(_:)), "h", [.command, .shift], target: player),
            item("Back", #selector(PlayerWindowController.goBackPage(_:)), "[", target: player),
            item("Forward", #selector(PlayerWindowController.goForwardPage(_:)), "]", target: player),
            item("Reload", #selector(PlayerWindowController.reloadPage(_:)), "r", target: player),
            .separator(),
            item("Actual Size", #selector(PlayerWindowController.actualSizePage(_:)), "0", target: player),
            item("Zoom In", #selector(PlayerWindowController.zoomInPage(_:)), "=", target: player),
            item("Zoom Out", #selector(PlayerWindowController.zoomOutPage(_:)), "-", target: player),
            .separator(),
            item("Debug Console", #selector(DebugConsole.toggle(_:)), "c", [.command, .option], target: DebugConsole.shared),
            {
                let i = item("Open Console at Launch", #selector(DebugConsole.toggleOpenAtLaunch(_:)), target: DebugConsole.shared)
                i.state = DebugConsole.openAtLaunch ? .on : .off
                return i
            }(),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        ])

        submenu("Playback", [
            item("Play / Pause", #selector(PlayerWindowController.playPause(_:)), "p", target: player),
            item("Next Track", #selector(PlayerWindowController.nextTrack(_:)), arrowRight, [.command, .control], target: player),
            item("Previous Track", #selector(PlayerWindowController.previousTrack(_:)), arrowLeft, [.command, .control], target: player),
            .separator(),
            item("Open in Firefox", #selector(PlayerWindowController.openInFirefox(_:)), target: player)
        ])

        let windowMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Show Player", #selector(PlayerWindowController.showPlayer(_:)), "1", target: player),
            item("Close", #selector(NSWindow.performClose(_:)), "w")
        ])
        NSApp.windowsMenu = windowMenu

        return main
    }
}
