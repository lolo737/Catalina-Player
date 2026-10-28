// Catalina Player: a native window for the Spotify web player on macOS 10.15.
// Entry point. Built with build.sh (swiftc, no Xcode project needed).

import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = app.setActivationPolicy(.regular)
app.run()
