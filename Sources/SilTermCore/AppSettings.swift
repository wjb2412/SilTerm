import Combine
import Foundation

// MARK: - 光标样式

public enum CursorStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case block
    case bar
    case underline

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .block: return "方块"
        case .bar: return "竖线"
        case .underline: return "下划线"
        }
    }
}

// MARK: - 快捷键

/// 快捷键动作标识。
public enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case splitVertical
    case splitHorizontal
    case closePane
    case focusPreviousPane
    case focusNextPane
    case newTab
    case reopenTab
    case closeTab
    case nextTab
    case previousTab
    case commandHistory
    case fontIncrease
    case fontDecrease
    case openSettings

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .splitVertical: return "垂直分割 Pane"
        case .splitHorizontal: return "水平分割 Pane"
        case .closePane: return "关闭当前 Pane"
        case .focusPreviousPane: return "焦点切到上一个 Pane"
        case .focusNextPane: return "焦点切到下一个 Pane"
        case .newTab: return "新建 Tab"
        case .reopenTab: return "恢复关闭的 Tab"
        case .closeTab: return "关闭 Tab"
        case .nextTab: return "下一个 Tab"
        case .previousTab: return "上一个 Tab"
        case .commandHistory: return "搜索命令历史"
        case .fontIncrease: return "放大字体"
        case .fontDecrease: return "缩小字体"
        case .openSettings: return "打开设置"
        }
    }

    /// Warp 风格默认键位。
    public var defaultCombo: String {
        switch self {
        case .splitVertical: return "cmd+d"
        case .splitHorizontal: return "cmd+shift+d"
        case .closePane: return "cmd+w"
        case .focusPreviousPane: return "cmd+["
        case .focusNextPane: return "cmd+]"
        case .newTab: return "cmd+t"
        case .reopenTab: return "cmd+shift+t"
        case .closeTab: return "cmd+shift+w"
        case .nextTab: return "cmd+shift+]"
        case .previousTab: return "cmd+shift+["
        case .commandHistory: return "cmd+r"
        case .fontIncrease: return "cmd+="
        case .fontDecrease: return "cmd+-"
        case .openSettings: return "cmd+,"
        }
    }

    public static var warpPreset: [String: String] {
        var map: [String: String] = [:]
        for action in ShortcutAction.allCases {
            map[action.rawValue] = action.defaultCombo
        }
        return map
    }
}

/// 解析后的快捷键组合（例如 "cmd+shift+d"）。
public struct KeyCombo: Equatable, Sendable {
    public var key: String
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key.lowercased()
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    public static func parse(_ raw: String) -> KeyCombo? {
        let parts = raw
            .lowercased()
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }
        var command = false, shift = false, option = false, control = false
        var key: String?
        for p in parts {
            switch p {
            case "cmd", "command", "⌘": command = true
            case "shift", "⇧": shift = true
            case "alt", "option", "opt", "⌥": option = true
            case "ctrl", "control", "⌃": control = true
            case "": return nil
            default: key = p
            }
        }
        guard let k = key, !k.isEmpty else { return nil }
        return KeyCombo(key: k, command: command, shift: shift, option: option, control: control)
    }

    /// 面板展示，如 ⌘⇧D。
    public var displayText: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        s += key.uppercased()
        return s
    }
}

// MARK: - 应用设置

public struct AppSettings: Codable, Equatable {
    public var defaultShell: String
    public var autoRestoreSession: Bool
    public var scrollbackLines: Int

    public var themeName: String
    public var customTheme: TerminalTheme?
    public var fontName: String
    public var fontSize: Double
    public var lineHeightMultiplier: Double
    public var backgroundOpacity: Double

    public var cursorStyle: CursorStyle
    public var cursorBlink: Bool

    public var hoverPreviewEnabled: Bool
    public var autoCopySelection: Bool
    /// 把 Pane 拖到窗口外时是否自动创建新窗口。
    public var paneDragToNewWindow: Bool

    public var finderIntegrationEnabled: Bool
    public var keybindings: [String: String]

    public enum ThemeName {
        public static let dark = "dark"
        public static let light = "light"
        public static let highContrast = "highContrast"
        public static let custom = "custom"
    }

    public init() {
        let envShell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        self.defaultShell = FileManager.default.isExecutableFile(atPath: envShell) ? envShell : "/bin/zsh"
        self.autoRestoreSession = true
        self.scrollbackLines = 10_000
        self.themeName = ThemeName.dark
        self.customTheme = nil
        self.fontName = "SFMono-Regular"
        self.fontSize = 13.0
        self.lineHeightMultiplier = 1.15
        self.backgroundOpacity = 0.96
        self.cursorStyle = .block
        self.cursorBlink = true
        self.hoverPreviewEnabled = true
        self.autoCopySelection = false
        self.paneDragToNewWindow = true
        self.finderIntegrationEnabled = true
        self.keybindings = ShortcutAction.warpPreset
    }

    private enum CodingKeys: String, CodingKey {
        case defaultShell, autoRestoreSession, scrollbackLines
        case themeName, customTheme, fontName, fontSize, lineHeightMultiplier, backgroundOpacity
        case cursorStyle, cursorBlink
        case hoverPreviewEnabled, autoCopySelection, paneDragToNewWindow
        case finderIntegrationEnabled, keybindings
    }

    /// 逐项解码，兼容旧版本配置文件缺失字段。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let def = AppSettings()
        defaultShell = try c.decodeIfPresent(String.self, forKey: .defaultShell) ?? def.defaultShell
        autoRestoreSession = try c.decodeIfPresent(Bool.self, forKey: .autoRestoreSession) ?? def.autoRestoreSession
        scrollbackLines = try c.decodeIfPresent(Int.self, forKey: .scrollbackLines) ?? def.scrollbackLines
        themeName = try c.decodeIfPresent(String.self, forKey: .themeName) ?? def.themeName
        customTheme = try c.decodeIfPresent(TerminalTheme.self, forKey: .customTheme)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? def.fontName
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? def.fontSize
        lineHeightMultiplier = try c.decodeIfPresent(Double.self, forKey: .lineHeightMultiplier) ?? def.lineHeightMultiplier
        backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? def.backgroundOpacity
        cursorStyle = try c.decodeIfPresent(CursorStyle.self, forKey: .cursorStyle) ?? def.cursorStyle
        cursorBlink = try c.decodeIfPresent(Bool.self, forKey: .cursorBlink) ?? def.cursorBlink
        hoverPreviewEnabled = try c.decodeIfPresent(Bool.self, forKey: .hoverPreviewEnabled) ?? def.hoverPreviewEnabled
        autoCopySelection = try c.decodeIfPresent(Bool.self, forKey: .autoCopySelection) ?? def.autoCopySelection
        paneDragToNewWindow = try c.decodeIfPresent(Bool.self, forKey: .paneDragToNewWindow) ?? def.paneDragToNewWindow
        finderIntegrationEnabled = try c.decodeIfPresent(Bool.self, forKey: .finderIntegrationEnabled) ?? def.finderIntegrationEnabled
        keybindings = try c.decodeIfPresent([String: String].self, forKey: .keybindings) ?? def.keybindings
    }

    /// 当前生效的主题。
    public var resolvedTheme: TerminalTheme {
        switch themeName {
        case ThemeName.light: return .light
        case ThemeName.highContrast: return .highContrast
        case ThemeName.custom: return customTheme ?? .dark
        default: return .dark
        }
    }

    public func combo(for action: ShortcutAction) -> KeyCombo? {
        guard let raw = keybindings[action.rawValue] else { return KeyCombo.parse(action.defaultCombo) }
        return KeyCombo.parse(raw) ?? KeyCombo.parse(action.defaultCombo)
    }
}

// MARK: - 设置存储

public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()
    public static let didChangeNotification = Notification.Name("SilTermSettingsDidChange")

    @Published public var settings: AppSettings {
        didSet {
            scheduleSave()
            NotificationCenter.default.post(name: SettingsStore.didChangeNotification, object: self)
        }
    }

    public let configDirectory: URL
    public let settingsFileURL: URL

    private var pendingSave: DispatchWorkItem?

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".config/SilTerm", isDirectory: true)
        self.configDirectory = dir
        self.settingsFileURL = dir.appendingPathComponent("settings.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: settingsFileURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = AppSettings()
        }
    }

    public var theme: TerminalTheme { settings.resolvedTheme }

    public func resolveTheme(named name: String) -> TerminalTheme {
        switch name {
        case AppSettings.ThemeName.light: return .light
        case AppSettings.ThemeName.highContrast: return .highContrast
        case AppSettings.ThemeName.custom: return settings.customTheme ?? .dark
        default: return .dark
        }
    }

    // MARK: 保存

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    public func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: settingsFileURL, options: .atomic)
    }

    public func resetToDefaults() {
        settings = AppSettings()
    }

    public func restoreWarpShortcuts() {
        settings.keybindings = ShortcutAction.warpPreset
    }

    // MARK: 主题导入导出

    public func importTheme(from url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var theme = TerminalTheme.parse(toml: text)
        if theme.name.isEmpty {
            theme.name = url.deletingPathExtension().lastPathComponent
        }
        settings.customTheme = theme
        settings.themeName = AppSettings.ThemeName.custom
    }

    public func exportTheme(to url: URL) throws {
        let theme = settings.resolvedTheme
        try theme.tomlString().write(to: url, atomically: true, encoding: .utf8)
    }
}
