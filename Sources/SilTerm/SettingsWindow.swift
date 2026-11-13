import AppKit
import SilTermCore
import SwiftUI

// MARK: - 设置窗口

/// 原生 SwiftUI 设置面板（7 个分类）。
final class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "SilTerm 设置"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(rootView: SettingsView())
        self.init(window: window)
    }
}

struct SettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        TabView {
            GeneralSettingsView(store: store)
                .tabItem { Label("通用", systemImage: "gearshape") }
            AppearanceSettingsView(store: store)
                .tabItem { Label("外观", systemImage: "paintpalette") }
            PaneSettingsView(store: store)
                .tabItem { Label("Pane", systemImage: "rectangle.split.2x1") }
            ShortcutSettingsView(store: store)
                .tabItem { Label("快捷键", systemImage: "keyboard") }
            ClipboardSettingsView(store: store)
                .tabItem { Label("剪贴板", systemImage: "doc.on.clipboard") }
            IntegrationSettingsView(store: store)
                .tabItem { Label("集成", systemImage: "folder.badge.gearshape") }
            AdvancedSettingsView(store: store)
                .tabItem { Label("高级", systemImage: "slider.horizontal.3") }
        }
        .padding(14)
        .frame(width: 640, height: 520)
    }
}

// MARK: - 通用

private struct GeneralSettingsView: View {
    @ObservedObject var store: SettingsStore

    private static let shells = [
        "/bin/zsh", "/bin/bash",
        "/opt/homebrew/bin/fish", "/usr/local/bin/fish",
        "/opt/homebrew/bin/nu", "/usr/local/bin/nu"
    ]

    var body: some View {
        Form {
            Section("启动") {
                Picker("默认 Shell", selection: binding(\.defaultShell)) {
                    ForEach(availableShells, id: \.self) { shell in
                        Text(shell).tag(shell)
                    }
                }
                Toggle("退出后自动恢复会话布局与目录", isOn: binding(\.autoRestoreSession))
                Text("说明：受 macOS 限制无法恢复正在运行的进程，只恢复 Tab/Pane 布局与各 Pane 的工作目录，重启后重建 shell。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("性能") {
                Stepper(value: binding(\.scrollbackLines), in: 1_000...200_000, step: 1_000) {
                    Text("最大回滚行数：\(store.settings.scrollbackLines)")
                }
                Text("回滚缓冲超出上限会自动丢弃最旧的行，用于控制内存占用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var availableShells: [String] {
        var list = GeneralSettingsView.shells
        if !list.contains(store.settings.defaultShell) {
            list.insert(store.settings.defaultShell, at: 0)
        }
        return list
    }
}

// MARK: - 外观

private struct AppearanceSettingsView: View {
    @ObservedObject var store: SettingsStore

    private static let fonts = [
        "SFMono-Regular", "SF Mono", "Menlo-Regular", "Monaco",
        "JetBrainsMono-Regular", "JetBrains Mono", "FiraCode-Regular", "Hack-Regular"
    ]

    var body: some View {
        Form {
            Section("主题") {
                Picker("配色", selection: binding(\.themeName)) {
                    Text("暗黑").tag(AppSettings.ThemeName.dark)
                    Text("浅色").tag(AppSettings.ThemeName.light)
                    Text("高对比").tag(AppSettings.ThemeName.highContrast)
                    Text("自定义").tag(AppSettings.ThemeName.custom)
                }
                HStack {
                    Button("导入 .toml 主题…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.init(filenameExtension: "toml") ?? .plainText]
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            try? store.importTheme(from: url)
                        }
                    }
                    Button("导出当前主题…") {
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [.init(filenameExtension: "toml") ?? .plainText]
                        panel.nameFieldStringValue = "silterm-theme.toml"
                        if panel.runModal() == .OK, let url = panel.url {
                            try? store.exportTheme(to: url)
                        }
                    }
                }
            }

            Section("字体") {
                Picker("等宽字体", selection: binding(\.fontName)) {
                    ForEach(availableFonts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                HStack {
                    Text("字号")
                    Slider(value: binding(\.fontSize), in: 9...28, step: 1)
                    Text("\(Int(store.settings.fontSize)) pt").monospacedDigit().frame(width: 46)
                }
                HStack {
                    Text("行高")
                    Slider(value: binding(\.lineHeightMultiplier), in: 1.0...2.0, step: 0.05)
                    Text(String(format: "%.2f", store.settings.lineHeightMultiplier))
                        .monospacedDigit().frame(width: 46)
                }
                HStack {
                    Text("不透明度")
                    Slider(value: binding(\.backgroundOpacity), in: 0.5...1.0, step: 0.02)
                    Text(String(format: "%.0f%%", store.settings.backgroundOpacity * 100))
                        .monospacedDigit().frame(width: 46)
                }
            }

            Section("光标与预览") {
                Picker("光标样式", selection: binding(\.cursorStyle)) {
                    ForEach(CursorStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Toggle("光标闪烁", isOn: binding(\.cursorBlink))
                Toggle("Hover 显示文件路径预览", isOn: binding(\.hoverPreviewEnabled))
                Text("关闭预览可进一步降低内存占用；预览仅在鼠标停留时临时生成，移开后立即释放。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var availableFonts: [String] {
        var list = AppearanceSettingsView.fonts
        if !list.contains(store.settings.fontName) {
            list.insert(store.settings.fontName, at: 0)
        }
        return list
    }
}

// MARK: - Pane 分片

private struct PaneSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("拖拽") {
                Toggle("把 Pane 拖到窗口外时创建新窗口", isOn: binding(\.paneDragToNewWindow))
                Text("Pane 可拖到同一窗口的其他 Tab、其他窗口，或拖出窗口生成独立窗口；PTY 会话与当前目录保持不变。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("右键菜单") {
                Text("垂直分割 / 水平分割 / 关闭 Pane / 复制选中文本 / 复制当前路径 / 在访达中打开当前目录 / 在新窗口打开此 Pane / 清空回滚缓冲。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("布局快照") {
                Text("在 Tab 标签上右键可保存布局快照；布局与目录保存在 ~/.config/SilTerm/ 下，纯 JSON 文本。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 快捷键

private struct ShortcutSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快捷键格式：cmd+shift+d、cmd+[、cmd+=；留空表示使用默认。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(ShortcutAction.allCases) { action in
                        HStack {
                            Text(action.displayName)
                                .frame(width: 190, alignment: .leading)
                            TextField("默认", text: binding(for: action))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                            if let combo = store.settings.combo(for: action) {
                                Text(combo.displayText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.trailing, 6)
            }

            HStack {
                Button("恢复 Warp 预设") { store.restoreWarpShortcuts() }
                Button("恢复默认设置") { store.resetToDefaults() }
                Spacer()
            }
        }
    }

    private func binding(for action: ShortcutAction) -> Binding<String> {
        Binding(
            get: { store.settings.keybindings[action.rawValue] ?? action.defaultCombo },
            set: { store.settings.keybindings[action.rawValue] = $0 }
        )
    }
}

// MARK: - 剪贴板

private struct ClipboardSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("选中即复制") {
                Toggle("选中文字后自动复制到剪贴板（iTerm 风格）", isOn: binding(\.autoCopySelection))
                Text("开启后，鼠标拖选或双击选中文本会立即写入系统剪贴板。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 集成

private struct IntegrationSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("访达（Finder）互通") {
                Toggle("启用访达服务菜单", isOn: binding(\.finderIntegrationEnabled))
                Text("启用后，访达中右键文件夹 → 服务 → 在此文件夹打开 SilTerm（新 Pane / 新 Tab）；右键文件 → 服务 → 在 SilTerm 中打开所在目录。也可以把服务拖到访达工具栏。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("如何启用系统服务") {
                Text("首次安装后，请到「系统设置 → 键盘 → 键盘快捷键 → 服务 → 文件与文件夹」中勾选 SilTerm 的服务项（文件夹 2 项、文件 2 项）。")
                    .font(.caption)
                HStack {
                    Button("打开系统设置") { FinderBridge.openServicesSettings() }
                    Button("重新注册服务") {
                        FinderBridge.refreshSystemServices()
                        NSWorkspace.shared.open(Bundle.main.bundleURL)
                    }
                }
            }

            Section("说明") {
                Text("SilTerm 不常驻后台进程，服务由 macOS 按需唤起；支持把文件夹拖到 Dock 图标直接打开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 高级

private struct AdvancedSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("配置目录") {
                HStack {
                    Text(store.configDirectory.path)
                        .font(.caption)
                        .textSelection(.enabled)
                    Spacer()
                    Button("打开") { NSWorkspace.shared.open(store.configDirectory) }
                }
                Text("设置（settings.json）与会话快照（session.json）均保存在此目录，纯文本、无数据库。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("内存保护") {
                Text("每个 Pane 独立 PTY，关闭 Pane 时立即销毁进程并释放回滚缓冲；Hover 预览的资源在鼠标移开后立即释放。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("恢复默认设置") { store.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 绑定辅助

private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(
        get: { SettingsStore.shared.settings[keyPath: keyPath] },
        set: { SettingsStore.shared.settings[keyPath: keyPath] = $0 }
    )
}
