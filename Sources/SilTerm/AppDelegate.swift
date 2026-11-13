import AppKit
import SilTermCore
import UniformTypeIdentifiers

/// 应用委托：窗口/会话生命周期、系统服务（访达互通）、菜单动作。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var windowControllers: [MainWindowController] = []
    private var settingsWindowController: SettingsWindowController?
    private var historyPanelController: CommandHistoryController?

    private var sessionSaveWork: DispatchWorkItem?
    private var pendingDirectories: [String] = []
    private var didFinishLaunching = false
    private var keybindingsSignature = ""

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 注册系统服务（访达右键 → 服务）
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        NSApp.mainMenu = MainMenu.build()
        keybindingsSignature = currentKeybindingsSignature()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(settingsDidChange),
                                               name: SettingsStore.didChangeNotification,
                                               object: nil)
        NSApp.setActivationPolicy(.regular)
        didFinishLaunching = true

        restoreOrCreateWindow()

        if !pendingDirectories.isEmpty {
            let directories = pendingDirectories
            pendingDirectories.removeAll()
            for path in directories {
                openDirectory(path, asTab: false)
            }
        }
        applyMeasurementHook()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 快捷键被修改后重建菜单，使新快捷键立即生效。
    @objc private func settingsDidChange() {
        let signature = currentKeybindingsSignature()
        guard signature != keybindingsSignature else { return }
        keybindingsSignature = signature
        NSApp.mainMenu = MainMenu.build()
    }

    private func currentKeybindingsSignature() -> String {
        let bindings = SettingsStore.shared.settings.keybindings
        return bindings.keys.sorted().map { "\($0)=\(bindings[$0] ?? "")" }.joined(separator: "|")
    }

    /// 仅用于性能测量：`SILTERM_INITIAL_PANES=4` 时预先把活动 Pane 分割为指定数量。
    private func applyMeasurementHook() {
        let environment = ProcessInfo.processInfo.environment
        if environment["SILTERM_OPEN_SETTINGS"] == "1" {
            showSettingsAction(nil)
        }
        guard let raw = environment["SILTERM_INITIAL_PANES"],
              let count = Int(raw), count > 1,
              let controller = keyWindowController else { return }
        for _ in 1..<count {
            controller.splitActivePane(orientation: .vertical)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveSessionNow()
        SettingsStore.shared.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        saveSessionNow()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if windowControllers.isEmpty {
                createWindow()
            } else {
                windowControllers.first?.showWindow(nil)
            }
        }
        return true
    }

    /// Dock 图标拖入文件夹 / 访达「打开方式」。
    func application(_ application: NSApplication, open urls: [URL]) {
        let directories = urls.filter { isDirectory($0) }.map(\.path)
        guard !directories.isEmpty else { return }
        guard didFinishLaunching else {
            pendingDirectories.append(contentsOf: directories)
            return
        }
        for path in directories {
            openDirectory(path, asTab: false)
        }
    }

    // MARK: - 窗口管理

    @discardableResult
    func createWindow() -> MainWindowController {
        let controller = MainWindowController(appDelegate: self, snapshot: nil)
        registerWindow(controller)
        return controller
    }

    func registerWindow(_ controller: MainWindowController) {
        windowControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func windowControllerDidClose(_ controller: MainWindowController) {
        windowControllers.removeAll { $0 === controller }
        scheduleSessionSave()
    }

    private func restoreOrCreateWindow() {
        let settings = SettingsStore.shared.settings
        guard settings.autoRestoreSession,
              let snapshot = SessionStore.shared.loadSession(),
              !snapshot.windows.isEmpty else {
            createWindow()
            return
        }
        for windowSnapshot in snapshot.windows {
            let controller = MainWindowController(appDelegate: self, snapshot: windowSnapshot)
            registerWindow(controller)
        }
    }

    /// 当前活跃的 SilTerm 窗口（用于菜单动作路由）。
    var keyWindowController: MainWindowController? {
        if let key = NSApp.keyWindow ?? NSApp.mainWindow,
           let controller = windowControllers.first(where: { $0.window === key }) {
            return controller
        }
        return windowControllers.first { $0.window?.isVisible == true } ?? windowControllers.last
    }

    // MARK: - 会话持久化

    /// 延迟保存（合并高频变更）。
    func scheduleSessionSave() {
        guard SettingsStore.shared.settings.autoRestoreSession else { return }
        sessionSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveSessionNow()
        }
        sessionSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func saveSessionNow() {
        sessionSaveWork?.cancel()
        sessionSaveWork = nil
        guard SettingsStore.shared.settings.autoRestoreSession else { return }
        let windows = windowControllers.compactMap { $0.windowSnapshot() }
        guard !windows.isEmpty else { return }
        SessionStore.shared.saveSession(WorkspaceSnapshot(windows: windows))
    }

    // MARK: - 目录打开入口（服务 / Dock 拖入共用）

    /// 在已有窗口的新 Pane / 新 Tab 中打开目录。
    func openDirectory(_ path: String, asTab: Bool) {
        let controller: MainWindowController
        if let key = keyWindowController {
            controller = key
        } else {
            controller = createWindow()
        }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if asTab {
            controller.newTab(cwd: path, shell: nil)
        } else {
            controller.openPane(cwd: path)
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return url.isFileURL
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    // MARK: - Finder Services

    /// 服务：在访达中对文件/文件夹右键，在 SilTerm 新 Pane 中打开。
    /// 选中文件夹时进入该目录；选中文件时进入该文件所在目录。
    @objc func openInSilTermPane(_ pboard: NSPasteboard,
                                 userData: String?,
                                 error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        handleService(pboard: pboard, asTab: false, error: error)
    }

    /// 服务：在访达中对文件/文件夹右键，在 SilTerm 新 Tab 中打开。
    @objc func openInSilTermTab(_ pboard: NSPasteboard,
                                userData: String?,
                                error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        handleService(pboard: pboard, asTab: true, error: error)
    }

    private func handleService(pboard: NSPasteboard,
                               asTab: Bool,
                               error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        guard let url = urls.first else {
            error?.pointee = "请选择一个文件或文件夹后再使用 SilTerm 服务" as NSString
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            error?.pointee = "所选路径不存在" as NSString
            return
        }
        // 文件取其所在目录；文件夹直接使用
        let directory = isDir.boolValue ? url : url.deletingLastPathComponent()
        let path = directory.path
        DispatchQueue.main.async { [weak self] in
            self?.openDirectory(path, asTab: asTab)
        }
    }

    // MARK: - 菜单动作：窗口 / Tab

    @objc func newWindowAction(_ sender: Any?) {
        createWindow()
        scheduleSessionSave()
    }

    @objc func newTabAction(_ sender: Any?) {
        (keyWindowController ?? createWindow()).newTab(cwd: nil, shell: nil)
    }

    @objc func closeTabAction(_ sender: Any?) {
        guard let controller = keyWindowController else { return }
        controller.closeTab(index: controller.selectedIndex)
    }

    @objc func reopenClosedTabAction(_ sender: Any?) {
        keyWindowController?.reopenClosedTab()
    }

    @objc func nextTabAction(_ sender: Any?) {
        guard let controller = keyWindowController, controller.tabCount() > 1 else { return }
        let index = (controller.selectedIndex + 1) % controller.tabCount()
        controller.selectTabAtIndex(index)
    }

    @objc func previousTabAction(_ sender: Any?) {
        guard let controller = keyWindowController, controller.tabCount() > 1 else { return }
        let count = controller.tabCount()
        let index = (controller.selectedIndex - 1 + count) % count
        controller.selectTabAtIndex(index)
    }

    @objc func closeWindowAction(_ sender: Any?) {
        NSApp.keyWindow?.performClose(nil)
    }

    // MARK: - 菜单动作：Pane

    @objc func splitVerticalAction(_ sender: Any?) {
        keyWindowController?.splitActivePane(orientation: .vertical)
    }

    @objc func splitHorizontalAction(_ sender: Any?) {
        keyWindowController?.splitActivePane(orientation: .horizontal)
    }

    /// Cmd+W：在主窗口内关闭当前 Pane（最后一个 Pane 关闭后窗口随之关闭）；
    /// 设置等其他窗口获得焦点时，则关闭该窗口。
    @objc func closePaneAction(_ sender: Any?) {
        if let key = NSApp.keyWindow,
           let controller = windowControllers.first(where: { $0.window === key }) {
            controller.closeActivePane()
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    @objc func focusNextPaneAction(_ sender: Any?) {
        keyWindowController?.focusNextPane(backwards: false)
    }

    @objc func focusPreviousPaneAction(_ sender: Any?) {
        keyWindowController?.focusNextPane(backwards: true)
    }

    // MARK: - 菜单动作：视图 / 设置

    @objc func increaseFontAction(_ sender: Any?) {
        adjustFontSize(+1)
    }

    @objc func decreaseFontAction(_ sender: Any?) {
        adjustFontSize(-1)
    }

    private func adjustFontSize(_ delta: Double) {
        var settings = SettingsStore.shared.settings
        settings.fontSize = max(8, min(32, settings.fontSize + delta))
        SettingsStore.shared.settings = settings
    }

    @objc func toggleHoverPreviewAction(_ sender: Any?) {
        var settings = SettingsStore.shared.settings
        settings.hoverPreviewEnabled.toggle()
        SettingsStore.shared.settings = settings
    }

    @objc func toggleAutoCopyAction(_ sender: Any?) {
        var settings = SettingsStore.shared.settings
        settings.autoCopySelection.toggle()
        SettingsStore.shared.settings = settings
    }

    @objc func showSettingsAction(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showCommandHistoryAction(_ sender: Any?) {
        guard let controller = keyWindowController else { return }
        if historyPanelController == nil {
            historyPanelController = CommandHistoryController(targetWindow: controller.window)
        }
        historyPanelController?.show(for: controller) { [weak controller] command in
            controller?.insertCommand(command)
        }
    }

    // MARK: - 菜单动作：会话 / 主题

    @objc func saveSessionSnapshotAction(_ sender: Any?) {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "SilTerm-session.json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let windows = self.windowControllers.compactMap { $0.windowSnapshot() }
            guard !windows.isEmpty else { return }
            SessionStore.shared.save(WorkspaceSnapshot(windows: windows), to: url)
        }
    }

    @objc func loadSessionSnapshotAction(_ sender: Any?) {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url,
                  let snapshot = SessionStore.shared.load(from: url),
                  let self else { return }
            for existing in self.windowControllers {
                existing.close()
            }
            self.windowControllers.removeAll()
            for windowSnapshot in snapshot.windows {
                let controller = MainWindowController(appDelegate: self, snapshot: windowSnapshot)
                self.registerWindow(controller)
            }
            self.scheduleSessionSave()
        }
    }

    @objc func importThemeAction(_ sender: Any?) {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "toml") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? SettingsStore.shared.importTheme(from: url)
        }
    }

    @objc func exportThemeAction(_ sender: Any?) {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "toml") ?? .plainText]
        panel.nameFieldStringValue = "silterm-theme.toml"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? SettingsStore.shared.exportTheme(to: url)
        }
    }

    // MARK: - 菜单校验

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let controller = keyWindowController
        let settings = SettingsStore.shared.settings
        if menuItem.action == #selector(toggleHoverPreviewAction(_:)) {
            menuItem.state = settings.hoverPreviewEnabled ? .on : .off
            return true
        }
        if menuItem.action == #selector(toggleAutoCopyAction(_:)) {
            menuItem.state = settings.autoCopySelection ? .on : .off
            return true
        }
        switch menuItem.action {
        case #selector(closePaneAction(_:)), #selector(splitVerticalAction(_:)),
             #selector(splitHorizontalAction(_:)), #selector(focusNextPaneAction(_:)),
             #selector(focusPreviousPaneAction(_:)), #selector(showCommandHistoryAction(_:)),
             #selector(closeTabAction(_:)), #selector(reopenClosedTabAction(_:)),
             #selector(nextTabAction(_:)), #selector(previousTabAction(_:)):
            return controller != nil
        default:
            return true
        }
    }
}
