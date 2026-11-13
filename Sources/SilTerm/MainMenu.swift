import AppKit
import SilTermCore

/// 主菜单构建：全部使用系统原生 NSMenu，快捷键从设置中读取（可自定义）。
enum MainMenu {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(windowMenuItem())
        return mainMenu
    }

    // MARK: - 工具

    private static var appDelegate: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    private static func item(_ title: String,
                             action: Selector,
                             target: AnyObject?,
                             combo: ShortcutAction? = nil,
                             rawKey: String? = nil,
                             modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = target
        if let combo {
            apply(combo, to: menuItem)
        } else if let rawKey {
            menuItem.keyEquivalent = rawKey
            menuItem.keyEquivalentModifierMask = modifiers
        }
        return menuItem
    }

    private static func apply(_ action: ShortcutAction, to item: NSMenuItem) {
        guard let combo = SettingsStore.shared.settings.combo(for: action) else { return }
        var key = combo.key
        // 带 Shift 的方括号在 AppKit 中按移位后的字符匹配
        if combo.shift {
            if key == "[" { key = "{" }
            if key == "]" { key = "}" }
        }
        item.keyEquivalent = key
        var mask: NSEvent.ModifierFlags = []
        if combo.command { mask.insert(.command) }
        if combo.shift { mask.insert(.shift) }
        if combo.option { mask.insert(.option) }
        if combo.control { mask.insert(.control) }
        item.keyEquivalentModifierMask = mask
    }

    // MARK: - 应用菜单

    private static func appMenuItem() -> NSMenuItem {
        let name = "SilTerm"
        let root = NSMenuItem()
        let menu = NSMenu(title: name)

        menu.addItem(item("关于 SilTerm",
                          action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                          target: NSApp))

        menu.addItem(.separator())

        menu.addItem(item("设置…",
                          action: #selector(AppDelegate.showSettingsAction(_:)),
                          target: appDelegate,
                          combo: .openSettings))

        menu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "服务")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(servicesItem)

        menu.addItem(.separator())

        menu.addItem(item("隐藏 SilTerm",
                          action: #selector(NSApplication.hide(_:)),
                          target: NSApp,
                          rawKey: "h",
                          modifiers: [.command]))
        let hideOthers = item("隐藏其他",
                              action: #selector(NSApplication.hideOtherApplications(_:)),
                              target: NSApp,
                              rawKey: "h",
                              modifiers: [.command, .option])
        menu.addItem(hideOthers)
        menu.addItem(item("显示全部",
                          action: #selector(NSApplication.unhideAllApplications(_:)),
                          target: NSApp))

        menu.addItem(.separator())

        menu.addItem(item("退出 SilTerm",
                          action: #selector(NSApplication.terminate(_:)),
                          target: NSApp,
                          rawKey: "q",
                          modifiers: [.command]))

        root.submenu = menu
        return root
    }

    // MARK: - 文件菜单

    private static func fileMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "文件")

        menu.addItem(item("新建窗口",
                          action: #selector(AppDelegate.newWindowAction(_:)),
                          target: appDelegate,
                          rawKey: "n",
                          modifiers: [.command]))
        menu.addItem(item("新建 Tab",
                          action: #selector(AppDelegate.newTabAction(_:)),
                          target: appDelegate,
                          combo: .newTab))
        menu.addItem(item("恢复关闭的 Tab",
                          action: #selector(AppDelegate.reopenClosedTabAction(_:)),
                          target: appDelegate,
                          combo: .reopenTab))
        menu.addItem(item("关闭 Tab",
                          action: #selector(AppDelegate.closeTabAction(_:)),
                          target: appDelegate,
                          combo: .closeTab))

        menu.addItem(.separator())

        menu.addItem(item("保存会话快照…",
                          action: #selector(AppDelegate.saveSessionSnapshotAction(_:)),
                          target: appDelegate))
        menu.addItem(item("加载会话快照…",
                          action: #selector(AppDelegate.loadSessionSnapshotAction(_:)),
                          target: appDelegate))

        menu.addItem(.separator())

        menu.addItem(item("导入主题…",
                          action: #selector(AppDelegate.importThemeAction(_:)),
                          target: appDelegate))
        menu.addItem(item("导出当前主题…",
                          action: #selector(AppDelegate.exportThemeAction(_:)),
                          target: appDelegate))

        menu.addItem(.separator())

        menu.addItem(item("关闭窗口",
                          action: #selector(AppDelegate.closeWindowAction(_:)),
                          target: appDelegate,
                          rawKey: "w",
                          modifiers: [.command, .option]))

        root.submenu = menu
        return root
    }

    // MARK: - 编辑菜单

    private static func editMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "编辑")

        menu.addItem(item("撤销", action: Selector(("undo:")), target: nil, rawKey: "z", modifiers: [.command]))
        menu.addItem(item("重做", action: Selector(("redo:")), target: nil, rawKey: "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("剪切", action: Selector(("cut:")), target: nil, rawKey: "x", modifiers: [.command]))
        menu.addItem(item("复制", action: Selector(("copy:")), target: nil, rawKey: "c", modifiers: [.command]))
        menu.addItem(item("粘贴", action: Selector(("paste:")), target: nil, rawKey: "v", modifiers: [.command]))
        menu.addItem(item("全选", action: Selector(("selectAll:")), target: nil, rawKey: "a", modifiers: [.command]))

        root.submenu = menu
        return root
    }

    // MARK: - 显示菜单

    private static func viewMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "显示")

        menu.addItem(item("垂直分割 Pane",
                          action: #selector(AppDelegate.splitVerticalAction(_:)),
                          target: appDelegate,
                          combo: .splitVertical))
        menu.addItem(item("水平分割 Pane",
                          action: #selector(AppDelegate.splitHorizontalAction(_:)),
                          target: appDelegate,
                          combo: .splitHorizontal))
        menu.addItem(item("关闭当前 Pane",
                          action: #selector(AppDelegate.closePaneAction(_:)),
                          target: appDelegate,
                          combo: .closePane))

        menu.addItem(.separator())

        menu.addItem(item("焦点上一个 Pane",
                          action: #selector(AppDelegate.focusPreviousPaneAction(_:)),
                          target: appDelegate,
                          combo: .focusPreviousPane))
        menu.addItem(item("焦点下一个 Pane",
                          action: #selector(AppDelegate.focusNextPaneAction(_:)),
                          target: appDelegate,
                          combo: .focusNextPane))

        menu.addItem(.separator())

        menu.addItem(item("上一个 Tab",
                          action: #selector(AppDelegate.previousTabAction(_:)),
                          target: appDelegate,
                          combo: .previousTab))
        menu.addItem(item("下一个 Tab",
                          action: #selector(AppDelegate.nextTabAction(_:)),
                          target: appDelegate,
                          combo: .nextTab))
        menu.addItem(item("搜索命令历史…",
                          action: #selector(AppDelegate.showCommandHistoryAction(_:)),
                          target: appDelegate,
                          combo: .commandHistory))

        menu.addItem(.separator())

        menu.addItem(item("放大字体",
                          action: #selector(AppDelegate.increaseFontAction(_:)),
                          target: appDelegate,
                          combo: .fontIncrease))
        menu.addItem(item("缩小字体",
                          action: #selector(AppDelegate.decreaseFontAction(_:)),
                          target: appDelegate,
                          combo: .fontDecrease))

        menu.addItem(.separator())

        menu.addItem(item("Hover 文件预览",
                          action: #selector(AppDelegate.toggleHoverPreviewAction(_:)),
                          target: appDelegate))
        menu.addItem(item("选中即复制",
                          action: #selector(AppDelegate.toggleAutoCopyAction(_:)),
                          target: appDelegate))

        root.submenu = menu
        return root
    }

    // MARK: - 窗口菜单

    private static func windowMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "窗口")

        menu.addItem(item("最小化",
                          action: #selector(NSWindow.performMiniaturize(_:)),
                          target: nil,
                          rawKey: "m",
                          modifiers: [.command]))
        menu.addItem(item("缩放",
                          action: #selector(NSWindow.performZoom(_:)),
                          target: nil))
        menu.addItem(.separator())
        menu.addItem(item("前置全部窗口",
                          action: #selector(NSApplication.arrangeInFront(_:)),
                          target: NSApp))

        NSApp.windowsMenu = menu
        root.submenu = menu
        return root
    }
}
