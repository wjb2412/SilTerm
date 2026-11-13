import AppKit

/// SilTerm ↔ 访达（Finder）互通的最小封装。
/// 只使用系统 API，不常驻后台、不额外占用内存。
enum FinderBridge {
    /// 在访达中打开指定目录；路径不存在时退回到父目录或用户主目录。
    static func openDirectory(_ path: String) {
        var url = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            url = url.deletingLastPathComponent()
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            url = FileManager.default.homeDirectoryForCurrentUser
        }
        NSWorkspace.shared.open(url)
    }

    /// 复制路径到剪贴板。
    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 触发系统重新扫描服务菜单（安装或移动 App 后可手动调用）。
    static func refreshSystemServices() {
        NSUpdateDynamicServices()
    }

    /// 打开系统设置中的「键盘 → 键盘快捷键 → 服务」面板，指导用户启用。
    static func openServicesSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
