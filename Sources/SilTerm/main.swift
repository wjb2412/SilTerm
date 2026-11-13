import AppKit

// 应用入口：纯 AppKit 原生启动（无 WebView / Electron）。
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
